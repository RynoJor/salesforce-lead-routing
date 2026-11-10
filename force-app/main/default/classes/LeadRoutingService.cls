/**
 * Speed-to-lead routing for new Leads. Runs in the Lead before-insert trigger, so it sets the
 * owner and routing fields with no extra DML on the leads.
 *
 *   validate -> duplicate check -> fit score -> assign (round-robin in region, skip full reps)
 *            -> SLA due time
 *
 * The rules (region -> pool queue, capacity, SLA minutes) live in Routing_Rule__mdt. Reps are
 * the active user members of each pool queue. A Rep_Capacity__c row overrides one rep's
 * capacity. The round-robin position per rule lives in Routing_Cursor__c.
 *
 * Bulk-safe: a fixed number of queries per transaction (rules come from the metadata cache),
 * and one upsert for the round-robin cursors, whatever the batch size.
 *
 * Runs without sharing on purpose: the duplicate check and rep loads must see every lead, not
 * just the ones the inserting user (a web form's guest user, an integration user) can see.
 */
public without sharing class LeadRoutingService {
    public static final Set<String> OPEN_STATUSES = new Set<String>{ 'Open - Not Contacted', 'Working - Contacted' };
    public static final String NOT_CONTACTED = 'Open - Not Contacted';
    public static final String DEFAULT_RULE = 'Default';
    public static final Integer DEFAULT_SLA_MINUTES = 60;

    public static final String REASON_ROUND_ROBIN = 'Round robin';
    public static final String REASON_SKIPPED = 'Round robin (skipped rep at capacity)';
    public static final String REASON_HELD = 'Held in queue (region at capacity)';
    public static final String REASON_NO_REPS = 'Held in queue (no active reps in pool)';
    public static final String REASON_NO_EMAIL = 'Not routed: missing email';
    public static final String REASON_EXISTING_PREFIX = 'Existing owner';

    @TestVisible
    private static Map<String, Routing_Rule__mdt> rulesOverride;
    @TestVisible
    private static String triageQueueName = 'Lead_Triage';

    /** Timing of the last route() call in this transaction, read by scripts/apex/bulk-benchmark.apex. */
    public static Long lastRunMillis;
    public static Integer lastRunQueries;
    public static Integer lastRunLeads;

    public static void route(List<Lead> leads) {
        if (leads == null || leads.isEmpty()) {
            return;
        }
        Long started = System.currentTimeMillis();
        Integer queriesBefore = Limits.getQueries();
        Datetime now = System.now();

        // ---- configuration (custom metadata: no SOQL) --------------------------------
        Map<String, Routing_Rule__mdt> rulesByRegion = new Map<String, Routing_Rule__mdt>();
        Set<String> queueNames = new Set<String>{ triageQueueName };
        for (Routing_Rule__mdt rule : activeRules().values()) {
            String key = rule.DeveloperName == DEFAULT_RULE ? DEFAULT_RULE : normalise(rule.Region__c);
            rulesByRegion.put(key, rule);
            if (String.isNotBlank(rule.Pool_Queue__c)) {
                queueNames.add(rule.Pool_Queue__c);
            }
        }

        // ---- pools: queues and their user members (1 query) ---------------------------
        Map<String, Id> queueIdByName = new Map<String, Id>();
        Map<String, List<Id>> membersByQueue = new Map<String, List<Id>>();
        Set<Id> candidateUsers = new Set<Id>();
        for (Group q : [
            SELECT Id, DeveloperName, (SELECT UserOrGroupId FROM GroupMembers)
            FROM Group
            WHERE Type = 'Queue' AND DeveloperName IN :queueNames
        ]) {
            queueIdByName.put(q.DeveloperName, q.Id);
            List<Id> members = new List<Id>();
            for (GroupMember m : q.GroupMembers) {
                if (m.UserOrGroupId.getSObjectType() == User.SObjectType) {
                    members.add(m.UserOrGroupId);
                }
            }
            membersByQueue.put(q.DeveloperName, members);
            candidateUsers.addAll(members);
        }

        // ---- duplicate check index (standard rules + 1 query) -------------------------
        LeadDuplicateMatcher matcher = new LeadDuplicateMatcher(leads);
        candidateUsers.addAll(matcher.ownerIds());

        // ---- active users, their loads and capacities (2 queries) ---------------------
        Set<Id> activeUsers = new Map<Id, User>(
                [SELECT Id FROM User WHERE IsActive = TRUE AND UserType = 'Standard' AND Id IN :candidateUsers]
            )
            .keySet();
        Map<Id, Integer> load = new Map<Id, Integer>();
        for (AggregateResult ar : [
            SELECT OwnerId owner, COUNT(Id) n
            FROM Lead
            WHERE OwnerId IN :activeUsers AND IsConverted = FALSE AND Status IN :OPEN_STATUSES
            GROUP BY OwnerId
        ]) {
            load.put((Id) ar.get('owner'), (Integer) ar.get('n'));
        }
        Map<Id, Integer> capacity = new Map<Id, Integer>();
        for (Id userId : activeUsers) {
            Rep_Capacity__c repCap = Rep_Capacity__c.getValues(userId);
            if (repCap != null && repCap.Max_Open_Leads__c != null) {
                capacity.put(userId, repCap.Max_Open_Leads__c.intValue());
            }
        }
        // Pools keep only active users, sorted by Id so the rotation order is stable.
        Map<String, List<Id>> poolByQueue = new Map<String, List<Id>>();
        for (String queueName : membersByQueue.keySet()) {
            List<Id> pool = new List<Id>();
            for (Id member : membersByQueue.get(queueName)) {
                if (activeUsers.contains(member)) {
                    pool.add(member);
                }
            }
            pool.sort();
            poolByQueue.put(queueName, pool);
        }

        // ---- round-robin cursors, locked for this transaction (1 query) ---------------
        Map<String, Routing_Cursor__c> cursorRows = new Map<String, Routing_Cursor__c>();
        for (Routing_Cursor__c c : [
            SELECT Id, Name, Next_Index__c
            FROM Routing_Cursor__c
            WHERE Name IN :ruleNames(rulesByRegion.values())
            FOR UPDATE
        ]) {
            cursorRows.put(c.Name, c);
        }
        Map<String, Integer> cursor = new Map<String, Integer>();
        for (Routing_Cursor__c c : cursorRows.values()) {
            cursor.put(c.Name, c.Next_Index__c == null ? 0 : c.Next_Index__c.intValue());
        }
        RoundRobinAssigner assigner = new RoundRobinAssigner(load, capacity, cursor);
        Id triageQueueId = queueIdByName.get(triageQueueName);

        // ---- route each lead (no SOQL or DML in this loop) ----------------------------
        for (Integer i = 0; i < leads.size(); i++) {
            Lead l = leads[i];
            List<String> flags = new List<String>();
            l.Fit_Score__c = LeadFitScorer.score(l);

            // 1. validate: no email means nobody can work the lead. Keep it, send it to triage.
            if (String.isBlank(l.Email)) {
                flags.add('missing_email');
                if (triageQueueId != null) {
                    l.OwnerId = triageQueueId;
                }
                setResult(l, REASON_NO_EMAIL, flags, null, null);
                continue;
            }
            if (String.isBlank(l.Region__c)) {
                flags.add('missing_region');
            }
            if (String.isBlank(l.Inbound_Source__c)) {
                flags.add('missing_source');
            }
            if (LeadDuplicateMatcher.businessDomain(l.Email) == null) {
                flags.add('public_email_domain');
            }

            // Rule for the region, or the Default rule.
            Routing_Rule__mdt rule = rulesByRegion.get(normalise(l.Region__c));
            if (rule == null) {
                rule = rulesByRegion.get(DEFAULT_RULE);
                if (!flags.contains('missing_region')) {
                    flags.add('unknown_region');
                }
            }
            Integer slaMinutes = (rule != null && rule.SLA_Minutes__c != null)
                ? rule.SLA_Minutes__c.intValue()
                : DEFAULT_SLA_MINUTES;

            // 2. duplicate check: a known person or account stays with its owner.
            Id ownerId;
            String reason;
            LeadDuplicateMatcher.Match match = matcher.find(l, i);
            if (match != null) {
                flags.add(match.kind == 'company' ? 'known_account' : 'duplicate_contact');
                if (match.ownerId != null && activeUsers.contains(match.ownerId)) {
                    ownerId = match.ownerId;
                    reason = REASON_EXISTING_PREFIX + ' (' + match.kind.replace('_', ' ') + ' match)';
                    assigner.take(ownerId);
                }
            }

            // 3. round-robin in the region's pool, skipping reps at capacity.
            if (ownerId == null && rule != null) {
                List<Id> pool = poolByQueue.get(rule.Pool_Queue__c);
                Integer poolCapacity = rule.Max_Open_Leads__c == null ? null : rule.Max_Open_Leads__c.intValue();
                RoundRobinAssigner.Pick pick = assigner.assign(rule.DeveloperName, pool, poolCapacity);
                if (pick != null) {
                    ownerId = pick.ownerId;
                    reason = pick.skipped > 0 ? REASON_SKIPPED : REASON_ROUND_ROBIN;
                } else {
                    // Nobody has room: the lead waits in the region queue, never unowned.
                    ownerId = queueIdByName.containsKey(rule.Pool_Queue__c)
                        ? queueIdByName.get(rule.Pool_Queue__c)
                        : triageQueueId;
                    Boolean noReps = pool == null || pool.isEmpty();
                    reason = noReps ? REASON_NO_REPS : REASON_HELD;
                    flags.add(noReps ? 'empty_pool' : 'over_capacity');
                }
            }
            if (ownerId == null) {
                ownerId = triageQueueId;
                reason = 'Held in triage (no routing rule)';
                flags.add('no_rule');
            }
            if (ownerId != null) {
                l.OwnerId = ownerId;
            }

            // 4. SLA clock.
            setResult(l, reason, flags, now, now.addMinutes(slaMinutes));
            matcher.add(l, ownerId);
        }

        // ---- persist round-robin positions (1 DML) -----------------------------------
        List<Routing_Cursor__c> changed = new List<Routing_Cursor__c>();
        for (String ruleName : assigner.cursor.keySet()) {
            Routing_Cursor__c row = cursorRows.containsKey(ruleName)
                ? cursorRows.get(ruleName)
                : new Routing_Cursor__c(Name = ruleName);
            Integer next = assigner.cursor.get(ruleName);
            if (row.Id == null || row.Next_Index__c != next) {
                row.Next_Index__c = next;
                changed.add(row);
            }
        }
        if (!changed.isEmpty()) {
            upsert changed;
        }

        lastRunMillis = System.currentTimeMillis() - started;
        lastRunQueries = Limits.getQueries() - queriesBefore;
        lastRunLeads = leads.size();
    }

    /** First touch: the first time Status moves off Open - Not Contacted. */
    public static void stampFirstTouch(List<Lead> leads, Map<Id, Lead> oldMap) {
        Datetime now = System.now();
        for (Lead l : leads) {
            Lead old = oldMap.get(l.Id);
            if (
                l.First_Touch_At__c == null &&
                old != null &&
                old.Status == NOT_CONTACTED &&
                l.Status != NOT_CONTACTED
            ) {
                l.First_Touch_At__c = now;
            }
        }
    }

    private static void setResult(Lead l, String reason, List<String> flags, Datetime routedAt, Datetime due) {
        l.Routing_Reason__c = reason;
        l.Routing_Flags__c = flags.isEmpty() ? null : String.join(flags, ';').left(255);
        l.Routed_At__c = routedAt;
        l.First_Response_Due__c = due;
    }

    private static Map<String, Routing_Rule__mdt> activeRules() {
        Map<String, Routing_Rule__mdt> all = rulesOverride != null ? rulesOverride : Routing_Rule__mdt.getAll();
        Map<String, Routing_Rule__mdt> active = new Map<String, Routing_Rule__mdt>();
        for (String name : all.keySet()) {
            if (all.get(name).Active__c) {
                active.put(name, all.get(name));
            }
        }
        return active;
    }

    private static Set<String> ruleNames(List<Routing_Rule__mdt> rules) {
        Set<String> names = new Set<String>();
        for (Routing_Rule__mdt r : rules) {
            names.add(r.DeveloperName);
        }
        return names;
    }

    private static String normalise(String region) {
        return String.isBlank(region) ? null : region.trim().toLowerCase();
    }
}
