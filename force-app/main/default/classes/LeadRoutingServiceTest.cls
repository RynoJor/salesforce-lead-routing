/**
 * End-to-end tests through the Lead trigger. Each test uses its own queues and users (created
 * in @TestSetup) and in-memory Routing Rules, so results do not depend on the org's own
 * queue members or custom metadata values.
 */
@IsTest
private class LeadRoutingServiceTest {
    private static final String POOL_NA = 'Test_Pool_NA';
    private static final String POOL_EMEA = 'Test_Pool_EMEA';
    private static final String POOL_EMPTY = 'Test_Pool_Empty';
    private static final String TRIAGE = 'Test_Triage';

    @TestSetup
    static void setup() {
        User me = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(me) {
            Profile p = [SELECT Id FROM Profile WHERE Name = 'Standard User' LIMIT 1];
            String suffix = String.valueOf(Crypto.getRandomInteger()).replace('-', '');
            List<User> reps = new List<User>();
            for (Integer i = 0; i < 3; i++) {
                reps.add(
                    new User(
                        Alias = 'rrep' + i,
                        Email = 'rep' + i + '@routing-test.example.com',
                        EmailEncodingKey = 'UTF-8',
                        FirstName = 'Test',
                        LastName = 'Rep' + i,
                        LanguageLocaleKey = 'en_US',
                        LocaleSidKey = 'en_US',
                        ProfileId = p.Id,
                        TimeZoneSidKey = 'GMT',
                        Username = 'routing.rep' + i + '.' + suffix + '@routing-test.example.com'
                    )
                );
            }
            insert reps;

            List<Group> queues = new List<Group>();
            for (String name : new List<String>{ POOL_NA, POOL_EMEA, POOL_EMPTY, TRIAGE }) {
                queues.add(new Group(Name = name, DeveloperName = name, Type = 'Queue'));
            }
            insert queues;
            List<QueueSobject> leadAccess = new List<QueueSobject>();
            for (Group q : queues) {
                leadAccess.add(new QueueSobject(QueueId = q.Id, SobjectType = 'Lead'));
            }
            insert leadAccess;
            insert new List<GroupMember>{
                new GroupMember(GroupId = queues[0].Id, UserOrGroupId = reps[0].Id),
                new GroupMember(GroupId = queues[0].Id, UserOrGroupId = reps[1].Id),
                new GroupMember(GroupId = queues[1].Id, UserOrGroupId = reps[2].Id)
            };
        }
    }

    // ---------------------------------------------------------------------------------
    // helpers
    // ---------------------------------------------------------------------------------

    private static Routing_Rule__mdt rule(String name, String region, String queue, Integer cap) {
        return new Routing_Rule__mdt(
            DeveloperName = name,
            Region__c = region,
            Pool_Queue__c = queue,
            Max_Open_Leads__c = cap,
            SLA_Minutes__c = 60,
            Active__c = true
        );
    }

    private static void configure(Integer emeaCapacity) {
        LeadRoutingService.rulesOverride = new Map<String, Routing_Rule__mdt>{
            'North_America' => rule('North_America', 'North America', POOL_NA, 100),
            'EMEA' => rule('EMEA', 'EMEA', POOL_EMEA, emeaCapacity),
            'APAC' => rule('APAC', 'APAC', POOL_EMPTY, 100),
            'Default' => rule('Default', 'Default', POOL_NA, 100)
        };
        LeadRoutingService.triageQueueName = TRIAGE;
    }

    private static Map<String, Id> reps() {
        Map<String, Id> byName = new Map<String, Id>();
        for (User u : [SELECT Id, LastName FROM User WHERE Email LIKE '%@routing-test.example.com']) {
            byName.put(u.LastName, u.Id);
        }
        return byName;
    }

    private static Id queueId(String name) {
        return [SELECT Id FROM Group WHERE DeveloperName = :name AND Type = 'Queue'].Id;
    }

    /** Distinct, unrelated names so leads in one test never look like each other. */
    private static Lead newLead(String tag, String region, String email) {
        String h = EncodingUtil.convertToHex(Crypto.generateDigest('MD5', Blob.valueOf(tag)));
        return new Lead(
            FirstName = 'F' + h.substring(0, 6),
            LastName = 'L' + h.substring(6, 14),
            Company = 'C' + h.substring(14, 26),
            Email = email == 'auto' ? 'x' + h.substring(0, 8) + '@d' + h.substring(8, 20) + '.example.com' : email,
            Region__c = region,
            Inbound_Source__c = 'Demo Request',
            Industry = 'Healthcare',
            NumberOfEmployees = 40,
            Status = LeadRoutingService.NOT_CONTACTED
        );
    }

    private static Lead reload(Id leadId) {
        return [
            SELECT
                OwnerId,
                Routing_Reason__c,
                Routing_Flags__c,
                Routed_At__c,
                First_Response_Due__c,
                Fit_Score__c,
                First_Touch_At__c,
                Company_Key__c,
                Email_Domain__c
            FROM Lead
            WHERE Id = :leadId
        ];
    }

    // ---------------------------------------------------------------------------------
    // tests
    // ---------------------------------------------------------------------------------

    @IsTest
    static void roundRobinAlternatesWithinRegionAndSetsSla() {
        configure(100);
        Map<String, Id> rep = reps();
        List<Lead> leads = new List<Lead>();
        for (Integer i = 0; i < 4; i++) {
            leads.add(newLead('rr' + i, 'North America', 'auto'));
        }
        Test.startTest();
        insert leads;
        Test.stopTest();

        Map<Id, Integer> perOwner = new Map<Id, Integer>();
        for (Lead l : [
            SELECT OwnerId, Routing_Reason__c, Routed_At__c, First_Response_Due__c, Fit_Score__c
            FROM Lead
            WHERE Id IN :leads
        ]) {
            Assert.areEqual(LeadRoutingService.REASON_ROUND_ROBIN, l.Routing_Reason__c);
            Assert.areEqual(l.Routed_At__c.addMinutes(60), l.First_Response_Due__c, 'SLA due = routed + 60 min');
            Assert.areEqual(35 + 25 + 20 + 15, l.Fit_Score__c);
            perOwner.put(l.OwnerId, (perOwner.containsKey(l.OwnerId) ? perOwner.get(l.OwnerId) : 0) + 1);
        }
        Assert.areEqual(2, perOwner.get(rep.get('Rep0')), 'Rep0 gets every other lead');
        Assert.areEqual(2, perOwner.get(rep.get('Rep1')), 'Rep1 gets every other lead');

        Routing_Cursor__c cursor = Routing_Cursor__c.getInstance('North_America');
        Assert.areEqual(0, cursor.Next_Index__c, 'Four leads over two reps wraps back to the start');
    }

    @IsTest
    static void cursorCarriesOverBetweenTransactions() {
        configure(100);
        Lead first = newLead('carry1', 'North America', 'auto');
        insert first;
        Lead second = newLead('carry2', 'North America', 'auto');
        insert second;
        Assert.areNotEqual(reload(first.Id).OwnerId, reload(second.Id).OwnerId, 'Next transaction takes the next rep');
    }

    @IsTest
    static void skipsRepAtCapacity() {
        configure(100);
        Map<String, Id> rep = reps();
        List<Id> pool = new List<Id>{ rep.get('Rep0'), rep.get('Rep1') };
        pool.sort(); // the service rotates in Id order, so pool[0] is tried first
        insert new Rep_Capacity__c(SetupOwnerId = pool[0], Max_Open_Leads__c = 0);
        List<Lead> leads = new List<Lead>{ newLead('cap1', 'North America', 'auto'), newLead('cap2', 'North America', 'auto') };
        insert leads;
        Lead first = reload(leads[0].Id);
        Assert.areEqual(pool[1], first.OwnerId);
        Assert.areEqual(LeadRoutingService.REASON_SKIPPED, first.Routing_Reason__c);
        Assert.areEqual(pool[1], reload(leads[1].Id).OwnerId);
    }

    @IsTest
    static void fullRegionHoldsLeadInQueue() {
        configure(1);
        Map<String, Id> rep = reps();
        List<Lead> leads = new List<Lead>{ newLead('full1', 'EMEA', 'auto'), newLead('full2', 'EMEA', 'auto') };
        insert leads;
        Assert.areEqual(rep.get('Rep2'), reload(leads[0].Id).OwnerId);
        Lead held = reload(leads[1].Id);
        Assert.areEqual(queueId(POOL_EMEA), held.OwnerId, 'Waits in the EMEA pool queue');
        Assert.areEqual(LeadRoutingService.REASON_HELD, held.Routing_Reason__c);
        Assert.isTrue(held.Routing_Flags__c.contains('over_capacity'));
        Assert.isNotNull(held.First_Response_Due__c, 'The SLA clock still runs while it waits');
    }

    @IsTest
    static void emptyPoolHoldsLeadInQueue() {
        configure(100);
        Lead l = newLead('apac', 'APAC', 'auto');
        insert l;
        Lead routed = reload(l.Id);
        Assert.areEqual(queueId(POOL_EMPTY), routed.OwnerId);
        Assert.areEqual(LeadRoutingService.REASON_NO_REPS, routed.Routing_Reason__c);
        Assert.isTrue(routed.Routing_Flags__c.contains('empty_pool'));
    }

    @IsTest
    static void sameEmailGoesToExistingOwner() {
        configure(100);
        Map<String, Id> rep = reps();
        Lead original = newLead('dup-original', 'EMEA', 'nora@larkwellbakery.example.com');
        insert original;
        Assert.areEqual(rep.get('Rep2'), reload(original.Id).OwnerId);

        Lead again = newLead('dup-again', 'North America', 'Nora@LarkwellBakery.example.com');
        insert again;
        Lead routed = reload(again.Id);
        Assert.areEqual(rep.get('Rep2'), routed.OwnerId, 'Same person stays with the same rep');
        Assert.isTrue(routed.Routing_Reason__c.startsWith(LeadRoutingService.REASON_EXISTING_PREFIX));
        Assert.isTrue(routed.Routing_Flags__c.contains('duplicate_contact'));
    }

    @IsTest
    static void apexFallbackMatchesEmailWhenStandardRulesAreOff() {
        configure(100);
        LeadDuplicateMatcher.useStandardRules = false;
        Map<String, Id> rep = reps();
        insert newLead('fb-original', 'EMEA', 'sam@harbor.example.com');
        Lead again = newLead('fb-again', 'North America', 'SAM@harbor.example.com');
        insert again;
        Lead routed = reload(again.Id);
        Assert.areEqual(rep.get('Rep2'), routed.OwnerId);
        Assert.areEqual('Existing owner (email match)', routed.Routing_Reason__c);
    }

    @IsTest
    static void companyMatchesIgnoringLegalSuffix() {
        configure(100);
        Map<String, Id> rep = reps();
        Lead original = newLead('co-original', 'EMEA', 'ann@brightpath.example.com');
        original.Company = 'Brightpath Tutoring';
        insert original;

        Lead other = newLead('co-other', 'North America', 'auto');
        other.Company = 'Brightpath Tutoring Ltd.';
        insert other;
        Lead routed = reload(other.Id);
        Assert.areEqual(rep.get('Rep2'), routed.OwnerId);
        Assert.areEqual('Existing owner (company match)', routed.Routing_Reason__c);
        Assert.isTrue(routed.Routing_Flags__c.contains('known_account'));
        Assert.areEqual('brightpathtutoring', routed.Company_Key__c);
    }

    @IsTest
    static void fuzzyCompanyNeedsASecondSignal() {
        configure(100);
        Map<String, Id> rep = reps();
        Lead original = newLead('fz-original', 'EMEA', 'sam@riverlight.example.com');
        original.FirstName = 'Sam';
        original.LastName = 'Ortiz';
        original.Company = 'Riverlight Clinic';
        insert original;

        Lead typo = newLead('fz-typo', 'North America', 'jo@riverlight.example.com');
        typo.FirstName = 'Jo';
        typo.LastName = 'Pereira';
        typo.Company = 'Riverlight Clinik';
        Lead lookalike = newLead('fz-lookalike', 'North America', 'kim@silverlight.example.com');
        lookalike.FirstName = 'Kim';
        lookalike.LastName = 'Larsen';
        lookalike.Company = 'Silverlight Clinic';
        insert new List<Lead>{ typo, lookalike };

        Assert.areEqual(rep.get('Rep2'), reload(typo.Id).OwnerId, 'Close name + same domain = same account');
        Lead other = reload(lookalike.Id);
        Assert.areNotEqual(rep.get('Rep2'), other.OwnerId, 'Close name alone is a different business');
        Assert.areEqual(LeadRoutingService.REASON_ROUND_ROBIN, other.Routing_Reason__c);
    }

    @IsTest
    static void duplicatesInsideOneBatchStayTogether() {
        configure(100);
        Lead a = newLead('batch-a', 'North America', 'pat@quillbrook.example.com');
        Lead b = newLead('batch-b', 'North America', 'pat@quillbrook.example.com');
        insert new List<Lead>{ a, b };
        Assert.areEqual(reload(a.Id).OwnerId, reload(b.Id).OwnerId);
        Assert.isTrue(reload(b.Id).Routing_Flags__c.contains('duplicate_contact'));
    }

    @IsTest
    static void missingEmailGoesToTriageWithoutSla() {
        configure(100);
        Lead l = newLead('noemail', 'EMEA', null);
        insert l;
        Lead routed = reload(l.Id);
        Assert.areEqual(queueId(TRIAGE), routed.OwnerId);
        Assert.areEqual(LeadRoutingService.REASON_NO_EMAIL, routed.Routing_Reason__c);
        Assert.isNull(routed.Routed_At__c);
        Assert.isNull(routed.First_Response_Due__c);
    }

    @IsTest
    static void unknownOrMissingRegionUsesDefaultRule() {
        configure(100);
        Map<String, Id> rep = reps();
        Lead latam = newLead('latam', 'LATAM', 'auto');
        Lead blank = newLead('blank', null, 'auto');
        blank.Inbound_Source__c = null;
        insert new List<Lead>{ latam, blank };

        Lead l1 = reload(latam.Id);
        Assert.isTrue(l1.Routing_Flags__c.contains('unknown_region'));
        Assert.isTrue(new Set<Id>{ rep.get('Rep0'), rep.get('Rep1') }.contains(l1.OwnerId), 'Default pool is NA');
        Lead l2 = reload(blank.Id);
        Assert.isTrue(l2.Routing_Flags__c.contains('missing_region'));
        Assert.isTrue(l2.Routing_Flags__c.contains('missing_source'));
    }

    @IsTest
    static void inactiveRuleFallsBackToDefault() {
        configure(100);
        LeadRoutingService.rulesOverride.get('EMEA').Active__c = false;
        Lead l = newLead('inactive', 'EMEA', 'auto');
        insert l;
        Assert.isTrue(reload(l.Id).Routing_Flags__c.contains('unknown_region'));
    }

    @IsTest
    static void noRulesAtAllSendsToTriage() {
        LeadRoutingService.rulesOverride = new Map<String, Routing_Rule__mdt>();
        LeadRoutingService.triageQueueName = TRIAGE;
        Lead l = newLead('norule', 'EMEA', 'auto');
        insert l;
        Lead routed = reload(l.Id);
        Assert.areEqual(queueId(TRIAGE), routed.OwnerId);
        Assert.isTrue(routed.Routing_Flags__c.contains('no_rule'));
    }

    @IsTest
    static void firstTouchIsStampedOnceWhenStatusMoves() {
        configure(100);
        Lead l = newLead('touch', 'EMEA', 'auto');
        insert l;
        Assert.isNull(reload(l.Id).First_Touch_At__c);

        l.Status = 'Working - Contacted';
        update l;
        Datetime firstTouch = reload(l.Id).First_Touch_At__c;
        Assert.isNotNull(firstTouch);

        l.Status = 'Closed - Not Converted';
        update l;
        Assert.areEqual(firstTouch, reload(l.Id).First_Touch_At__c, 'Only the first touch counts');
    }

    @IsTest
    static void bypassSkipsRouting() {
        configure(100);
        LeadTriggerHandler.bypass = true;
        Lead l = newLead('bypass', 'EMEA', 'auto');
        insert l;
        Assert.isNull(reload(l.Id).Routed_At__c);
    }

    @IsTest
    static void routesTwoHundredLeadsInOneTransaction() {
        configure(100);
        Map<String, Id> rep = reps();
        List<Lead> leads = new List<Lead>();
        for (Integer i = 0; i < 200; i++) {
            String region = i < 100 ? 'North America' : (i < 160 ? 'EMEA' : 'APAC');
            leads.add(newLead('bulk' + i, region, 'auto'));
        }

        Test.startTest();
        insert leads;
        Integer queries = LeadRoutingService.lastRunQueries;
        Long millis = LeadRoutingService.lastRunMillis;
        Test.stopTest();

        System.debug(LoggingLevel.INFO, 'BULK_ROUTE leads=200 ms=' + millis + ' soql=' + queries);
        Assert.areEqual(200, LeadRoutingService.lastRunLeads, 'All 200 arrive in one trigger call');
        Assert.isTrue(queries <= 10, 'Fixed query count, not one per lead: ' + queries);

        Map<Id, Integer> perOwner = new Map<Id, Integer>();
        Integer routed = 0;
        for (AggregateResult ar : [
            SELECT OwnerId owner, COUNT(Id) n
            FROM Lead
            WHERE Id IN :leads AND Routed_At__c != NULL
            GROUP BY OwnerId
        ]) {
            perOwner.put((Id) ar.get('owner'), (Integer) ar.get('n'));
            routed += (Integer) ar.get('n');
        }
        Assert.areEqual(200, routed, 'Every lead routed');
        Assert.areEqual(50, perOwner.get(rep.get('Rep0')), 'NA split evenly');
        Assert.areEqual(50, perOwner.get(rep.get('Rep1')), 'NA split evenly');
        Assert.areEqual(60, perOwner.get(rep.get('Rep2')), 'EMEA has one rep');
        Assert.areEqual(40, perOwner.get(queueId(POOL_EMPTY)), 'APAC has no reps, leads wait in its queue');
    }
}
