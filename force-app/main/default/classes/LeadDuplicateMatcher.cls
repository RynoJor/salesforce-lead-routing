/**
 * Duplicate check for inbound leads. Same rules as the Python router (route.py, LeadIndex):
 *
 *   1. Standard duplicate rules first. Datacloud.FindDuplicates runs the org's active Lead
 *      duplicate rules (including Routing: same email). A match to an existing lead wins.
 *   2. Apex fallback, always available even if the duplicate rules are switched off:
 *      a. exact email, case-insensitive               -> 'email'   (flag duplicate_contact)
 *      b. exact normalised company name               -> 'company' (flag known_account)
 *      c. similar company name (Levenshtein ratio >= 0.85) AND a second signal: the same
 *         contact surname or the same business email domain -> 'company'
 *
 * Name similarity alone is never enough: "Riverlight Clinic" and "Silverlight Clinic" are
 * close but are different businesses. Public mail domains (gmail.com etc.) never count.
 *
 * Bulk-safe: one SOQL query for all candidates, then an in-memory index. Leads routed earlier
 * in the same batch are added to the index, so two copies of one lead in a batch go together.
 */
public without sharing class LeadDuplicateMatcher {
    public static final Decimal SIMILARITY_CUTOFF = 0.85;
    public static final Integer FIND_DUPLICATES_CHUNK = 50; // platform limit per call
    public static final Set<String> PUBLIC_DOMAINS = new Set<String>{
        'gmail.com', 'yahoo.com', 'outlook.com', 'hotmail.com', 'icloud.com', 'aol.com', 'proton.me'
    };
    private static final Set<String> LEGAL_SUFFIXES = new Set<String>{
        'llc', 'inc', 'co', 'ltd', 'corp', 'company', 'limited', 'gmbh', 'plc'
    };
    private static final String LEAD_PREFIX = Lead.SObjectType.getDescribe().getKeyPrefix();

    /** Kill switch for the standard-rule lookup, e.g. if an org's rules are noisy. */
    @TestVisible
    private static Boolean useStandardRules = true;

    public class Match {
        public String kind; // email | company | duplicate_rule
        public Id leadId;
        public Id ownerId;
        public Match(String kind, Id leadId, Id ownerId) {
            this.kind = kind;
            this.leadId = leadId;
            this.ownerId = ownerId;
        }
    }

    private class Entry {
        Id leadId;
        Id ownerId;
        String companyKey;
        Entry(Id leadId, Id ownerId, String companyKey) {
            this.leadId = leadId;
            this.ownerId = ownerId;
            this.companyKey = companyKey;
        }
    }

    private Map<String, Entry> byEmail = new Map<String, Entry>();
    private Map<String, Entry> byCompany = new Map<String, Entry>();
    private Map<String, List<Entry>> bySurname = new Map<String, List<Entry>>();
    private Map<String, List<Entry>> byDomain = new Map<String, List<Entry>>();
    private Map<Id, Entry> byId = new Map<Id, Entry>();
    private Map<Integer, Id> standardMatchByIndex = new Map<Integer, Id>();

    // ------------------------------------------------------------------------------------
    // Keys
    // ------------------------------------------------------------------------------------

    /** 'Larkwell Bakery, Inc.' and 'Lark Well Bakery' both become 'larkwellbakery'. */
    public static String companyKey(String name) {
        if (String.isBlank(name)) {
            return null;
        }
        List<String> words = new List<String>();
        for (String w : name.toLowerCase().replaceAll('[^a-z0-9 ]', ' ').split(' ')) {
            if (String.isNotBlank(w)) {
                words.add(w);
            }
        }
        while (!words.isEmpty() && LEGAL_SUFFIXES.contains(words[words.size() - 1])) {
            words.remove(words.size() - 1);
        }
        String key = String.join(words, '');
        return String.isBlank(key) ? null : key.left(255);
    }

    public static String emailDomain(String email) {
        if (String.isBlank(email) || !email.contains('@')) {
            return null;
        }
        return email.substringAfterLast('@').toLowerCase().trim();
    }

    /** Email domain, or null for public mail providers (they say nothing about the company). */
    public static String businessDomain(String email) {
        String domain = emailDomain(email);
        return (domain == null || PUBLIC_DOMAINS.contains(domain)) ? null : domain.left(255);
    }

    public static String surname(String lastName) {
        if (String.isBlank(lastName)) {
            return null;
        }
        List<String> words = lastName.toLowerCase().replaceAll('[^a-z ]', ' ').normalizeSpace().split(' ');
        return String.isBlank(words[words.size() - 1]) ? null : words[words.size() - 1];
    }

    /** 1 - Levenshtein distance / longer length, compared with SIMILARITY_CUTOFF. */
    public static Boolean similar(String a, String b) {
        if (String.isBlank(a) || String.isBlank(b)) {
            return false;
        }
        Integer longer = Math.max(a.length(), b.length());
        Decimal ratio = 1 - (Decimal.valueOf(a.getLevenshteinDistance(b)) / longer);
        return ratio >= SIMILARITY_CUTOFF;
    }

    /** Keep the indexed key fields in step with Company and Email. No DML: call in a before trigger. */
    public static void stampKeys(List<Lead> leads) {
        for (Lead l : leads) {
            l.Company_Key__c = companyKey(l.Company);
            l.Email_Domain__c = businessDomain(l.Email);
        }
    }

    // ------------------------------------------------------------------------------------
    // Index
    // ------------------------------------------------------------------------------------

    /** Load every existing lead that could match any lead in the batch. One query. */
    public LeadDuplicateMatcher(List<Lead> incoming) {
        Set<String> emails = new Set<String>();
        Set<String> keys = new Set<String>();
        Set<String> domains = new Set<String>();
        Set<String> surnames = new Set<String>();
        for (Lead l : incoming) {
            if (String.isNotBlank(l.Email)) {
                emails.add(l.Email.toLowerCase());
            }
            String key = companyKey(l.Company);
            if (key != null) {
                keys.add(key);
            }
            String domain = businessDomain(l.Email);
            if (domain != null) {
                domains.add(domain);
            }
            String sn = surname(l.LastName);
            if (sn != null) {
                surnames.add(sn);
            }
        }
        Set<Id> standardIds = useStandardRules ? findWithStandardRules(incoming) : new Set<Id>();

        // Oldest first, so the original lead wins when several match.
        for (Lead existing : [
            SELECT Id, OwnerId, Email, Company, LastName
            FROM Lead
            WHERE IsConverted = FALSE
                AND (Id IN :standardIds
                    OR Email IN :emails
                    OR Company_Key__c IN :keys
                    OR Email_Domain__c IN :domains
                    OR LastName IN :surnames)
            ORDER BY CreatedDate ASC, Id ASC
            LIMIT 5000
        ]) {
            add(existing, existing.OwnerId);
        }
    }

    /** Owners of every indexed lead, so the caller can check which are active users. */
    public Set<Id> ownerIds() {
        Set<Id> ids = new Set<Id>();
        for (Entry e : byId.values()) {
            if (e.ownerId != null) {
                ids.add(e.ownerId);
            }
        }
        return ids;
    }

    /** Add a lead (existing or just routed) to the index. */
    public void add(Lead l, Id ownerId) {
        Entry e = new Entry(l.Id, ownerId, companyKey(l.Company));
        if (l.Id != null) {
            byId.put(l.Id, e);
        }
        if (String.isNotBlank(l.Email) && !byEmail.containsKey(l.Email.toLowerCase())) {
            byEmail.put(l.Email.toLowerCase(), e);
        }
        if (e.companyKey != null && !byCompany.containsKey(e.companyKey)) {
            byCompany.put(e.companyKey, e);
        }
        addTo(bySurname, surname(l.LastName), e);
        addTo(byDomain, businessDomain(l.Email), e);
    }

    /**
     * Match for the lead at position `index` in the incoming batch, or null.
     * Standard duplicate rule hits first, then exact email, exact company, fuzzy company.
     */
    public Match find(Lead l, Integer index) {
        Id standardId = standardMatchByIndex.get(index);
        if (standardId != null && byId.containsKey(standardId)) {
            Entry e = byId.get(standardId);
            return new Match('duplicate_rule', e.leadId, e.ownerId);
        }
        if (String.isNotBlank(l.Email) && byEmail.containsKey(l.Email.toLowerCase())) {
            Entry e = byEmail.get(l.Email.toLowerCase());
            return new Match('email', e.leadId, e.ownerId);
        }
        String key = companyKey(l.Company);
        if (key == null) {
            return null;
        }
        if (byCompany.containsKey(key)) {
            Entry e = byCompany.get(key);
            return new Match('company', e.leadId, e.ownerId);
        }
        // Fuzzy: only leads that already share a surname or business domain are candidates,
        // which is the second signal. Then the names must be close.
        List<Entry> candidates = new List<Entry>();
        String sn = surname(l.LastName);
        String domain = businessDomain(l.Email);
        if (sn != null && bySurname.containsKey(sn)) {
            candidates.addAll(bySurname.get(sn));
        }
        if (domain != null && byDomain.containsKey(domain)) {
            candidates.addAll(byDomain.get(domain));
        }
        for (Entry e : candidates) {
            if (similar(key, e.companyKey)) {
                return new Match('company', e.leadId, e.ownerId);
            }
        }
        return null;
    }

    // ------------------------------------------------------------------------------------
    // Standard duplicate rules
    // ------------------------------------------------------------------------------------

    /** Run the org's active Lead duplicate rules, 50 records per call. Returns matched lead Ids. */
    private Set<Id> findWithStandardRules(List<Lead> incoming) {
        Set<Id> matched = new Set<Id>();
        try {
            for (Integer start = 0; start < incoming.size(); start += FIND_DUPLICATES_CHUNK) {
                List<Lead> chunk = new List<Lead>();
                for (Integer i = start; i < Math.min(start + FIND_DUPLICATES_CHUNK, incoming.size()); i++) {
                    chunk.add(incoming[i]);
                }
                List<Datacloud.FindDuplicatesResult> results = Datacloud.FindDuplicates.findDuplicates(chunk);
                for (Integer i = 0; i < results.size(); i++) {
                    Id hit = firstLeadMatch(results[i]);
                    if (hit != null) {
                        standardMatchByIndex.put(start + i, hit);
                        matched.add(hit);
                    }
                }
            }
        } catch (Exception e) {
            // No active duplicate rules, or the call is unavailable: the Apex checks still run.
            standardMatchByIndex.clear();
            matched.clear();
        }
        return matched;
    }

    private static Id firstLeadMatch(Datacloud.FindDuplicatesResult result) {
        for (Datacloud.DuplicateResult dr : result.getDuplicateResults()) {
            for (Datacloud.MatchResult mr : dr.getMatchResults()) {
                for (Datacloud.MatchRecord rec : mr.getMatchRecords()) {
                    Id recordId = rec.getRecord().Id;
                    if (recordId != null && String.valueOf(recordId).startsWith(LEAD_PREFIX)) {
                        return recordId;
                    }
                }
            }
        }
        return null;
    }

    private static void addTo(Map<String, List<Entry>> index, String key, Entry e) {
        if (key == null) {
            return;
        }
        if (!index.containsKey(key)) {
            index.put(key, new List<Entry>());
        }
        index.get(key).add(e);
    }
}
