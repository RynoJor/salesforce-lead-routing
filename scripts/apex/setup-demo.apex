// One-off demo setup: make the running user a member of every routing queue, so the pools
// have a rep. Run with: sf apex run --file scripts/apex/setup-demo.apex --target-org <alias>
Set<String> names = new Set<String>{ 'Lead_Pool_North_America', 'Lead_Pool_EMEA', 'Lead_Pool_APAC', 'Lead_Triage' };
Set<Id> already = new Set<Id>();
for (GroupMember m : [SELECT GroupId FROM GroupMember WHERE UserOrGroupId = :UserInfo.getUserId() AND Group.DeveloperName IN :names]) {
    already.add(m.GroupId);
}
List<GroupMember> add = new List<GroupMember>();
for (Group q : [SELECT Id FROM Group WHERE Type = 'Queue' AND DeveloperName IN :names]) {
    if (!already.contains(q.Id)) {
        add.add(new GroupMember(GroupId = q.Id, UserOrGroupId = UserInfo.getUserId()));
    }
}
insert add;
Integer open = [SELECT COUNT() FROM Lead WHERE OwnerId = :UserInfo.getUserId() AND IsConverted = false AND Status IN :LeadRoutingService.OPEN_STATUSES];
System.debug('SETUP added memberships=' + add.size() + ' open leads already owned=' + open);
