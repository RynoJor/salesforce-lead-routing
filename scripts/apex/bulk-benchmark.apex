// Inserts 200 synthetic leads in ONE transaction, prints how long routing took, then rolls
// everything back so the org is unchanged.
// Run with: sf apex run --file scripts/apex/bulk-benchmark.apex --target-org <alias>
List<String> regions = new List<String>{ 'North America', 'EMEA', 'APAC', 'LATAM' };
List<String> sources = new List<String>{ 'Demo Request', 'Free Trial', 'Website Form', 'Content Download' };
List<Lead> leads = new List<Lead>();
Integer batchSize = 200; // change to 1 to time a single lead
for (Integer i = 0; i < batchSize; i++) {
    String h = EncodingUtil.convertToHex(Crypto.generateDigest('MD5', Blob.valueOf('bench' + i)));
    leads.add(new Lead(
        FirstName = 'Bench', LastName = 'Lead ' + h.left(8), Company = 'Benchmark ' + h.substring(8, 20),
        Email = 'b' + h.left(6) + '@b' + h.substring(6, 18) + '.example.com',
        Region__c = regions[Math.mod(i, 4)], Inbound_Source__c = sources[Math.mod(i, 4)],
        Industry = 'Healthcare', NumberOfEmployees = 40, Status = 'Open - Not Contacted'));
}
Savepoint sp = Database.setSavepoint();
Integer cpu0 = Limits.getCpuTime();
Long t0 = System.currentTimeMillis();
insert leads;
Long totalMs = System.currentTimeMillis() - t0;
Integer cpu = Limits.getCpuTime() - cpu0;
Integer routed = [SELECT COUNT() FROM Lead WHERE Id IN :leads AND Routing_Reason__c != null];
Integer tasks = [SELECT COUNT() FROM Task WHERE WhoId IN :leads];
System.debug('BENCH leads=' + LeadRoutingService.lastRunLeads + ' route_ms=' + LeadRoutingService.lastRunMillis
    + ' route_soql=' + LeadRoutingService.lastRunQueries + ' insert_total_ms=' + totalMs + ' cpu_ms=' + cpu
    + ' routed=' + routed + ' tasks_from_flow=' + tasks);
Database.rollback(sp);
