/**
 * One trigger per object; all logic is in LeadTriggerHandler.
 */
trigger LeadTrigger on Lead(before insert, before update) {
    LeadTriggerHandler.handle(Trigger.operationType, Trigger.new, Trigger.oldMap);
}
