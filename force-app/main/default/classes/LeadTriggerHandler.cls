/**
 * Lead trigger dispatch. Before-save only, so routing fields and the owner are set on the
 * records in memory with no extra DML and no recursion.
 */
public without sharing class LeadTriggerHandler {
    /** Set to true to load or fix data without routing it. */
    public static Boolean bypass = false;

    public static void handle(System.TriggerOperation operation, List<Lead> newLeads, Map<Id, Lead> oldMap) {
        if (bypass) {
            return;
        }
        switch on operation {
            when BEFORE_INSERT {
                LeadDuplicateMatcher.stampKeys(newLeads);
                LeadRoutingService.route(newLeads);
            }
            when BEFORE_UPDATE {
                LeadDuplicateMatcher.stampKeys(newLeads);
                LeadRoutingService.stampFirstTouch(newLeads, oldMap);
            }
            when else {
                return;
            }
        }
    }
}
