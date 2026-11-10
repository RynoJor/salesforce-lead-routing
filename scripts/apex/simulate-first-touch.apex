// DEMO ONLY: simulates rep activity on the seed leads so the dashboard has something to show.
// Moves each rep-owned seed lead's routing time back 3 hours, then marks most of them as
// contacted after a spread of response times (some inside the 60-minute SLA, some outside).
// The rest stay untouched, so they are past due and the SLA Flow's scheduled path escalates them.
// Run with: sf apex run --file scripts/apex/simulate-first-touch.apex --target-org <alias>
List<Integer> minutes = new List<Integer>{ 3, 6, 9, 12, 14, 18, 22, 25, 31, 38, 44, 52, 58, 67, 74, 88, 105, 140 };
List<Lead> leads = [
    SELECT Id, Routed_At__c FROM Lead
    WHERE Email LIKE '%example.com' AND Routed_At__c != null AND Owner.Type = 'User' AND First_Touch_At__c = null
    ORDER BY CreatedDate, Id
];
Datetime base = System.now().addHours(-3);
for (Integer i = 0; i < leads.size(); i++) {
    Lead l = leads[i];
    l.Routed_At__c = base.addMinutes(i);
    l.First_Response_Due__c = l.Routed_At__c.addMinutes(60);
    if (i < minutes.size()) {
        l.First_Touch_At__c = l.Routed_At__c.addMinutes(minutes[i]);
        l.Status = 'Working - Contacted';
    }
}
update leads;
System.debug('SIM leads=' + leads.size() + ' touched=' + Math.min(leads.size(), minutes.size()));
