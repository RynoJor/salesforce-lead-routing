@IsTest
private class LeadDuplicateMatcherTest {
    @IsTest
    static void companyKeyNormalisesCasePunctuationAndSuffixes() {
        Assert.areEqual('larkwellbakery', LeadDuplicateMatcher.companyKey('Larkwell Bakery, Inc.'));
        Assert.areEqual('larkwellbakery', LeadDuplicateMatcher.companyKey('Lark Well Bakery LLC'));
        Assert.areEqual('sunridgecoffee', LeadDuplicateMatcher.companyKey('Sunridge Coffee Co.'));
        Assert.isNull(LeadDuplicateMatcher.companyKey('  '));
        Assert.isNull(LeadDuplicateMatcher.companyKey('Ltd.'));
    }

    @IsTest
    static void publicMailDomainsAreNotBusinessDomains() {
        Assert.areEqual('maplewoodphysio.example.com', LeadDuplicateMatcher.businessDomain('Jo@MaplewoodPhysio.example.com'));
        Assert.isNull(LeadDuplicateMatcher.businessDomain('someone@gmail.com'));
        Assert.isNull(LeadDuplicateMatcher.businessDomain('not-an-email'));
        Assert.isNull(LeadDuplicateMatcher.emailDomain(null));
    }

    @IsTest
    static void surnameIsTheLastWord() {
        Assert.areEqual('galloway', LeadDuplicateMatcher.surname('Van Galloway'));
        Assert.isNull(LeadDuplicateMatcher.surname(''));
        Assert.isNull(LeadDuplicateMatcher.surname('123'));
    }

    @IsTest
    static void similarityUsesTheCutoff() {
        Assert.isTrue(LeadDuplicateMatcher.similar('riverlightclinic', 'riverlightclinik'));
        Assert.isFalse(LeadDuplicateMatcher.similar('riverlightclinic', 'harborlights'));
        Assert.isFalse(LeadDuplicateMatcher.similar(null, 'x'));
    }

    @IsTest
    static void findReturnsNullWithoutACompany() {
        LeadDuplicateMatcher.useStandardRules = false;
        Lead l = new Lead(LastName = 'Nobody', Company = '...', Email = 'n@nowhere.example.com');
        LeadDuplicateMatcher m = new LeadDuplicateMatcher(new List<Lead>{ l });
        Assert.isNull(m.find(l, 0));
        Assert.isTrue(m.ownerIds().isEmpty());
    }

    @IsTest
    static void surnameIsASecondSignalForFuzzyNames() {
        LeadDuplicateMatcher.useStandardRules = false;
        LeadTriggerHandler.bypass = true;
        Lead existing = new Lead(LastName = 'Ortiz', Company = 'Maplewood Physio', Email = 'sam@gmail.com');
        insert existing;
        Lead incoming = new Lead(LastName = 'Ortiz', Company = 'Maplewood Physyo', Email = 'sam.o@yahoo.com');
        LeadDuplicateMatcher m = new LeadDuplicateMatcher(new List<Lead>{ incoming });
        LeadDuplicateMatcher.Match hit = m.find(incoming, 0);
        Assert.isNotNull(hit);
        Assert.areEqual('company', hit.kind);
        Assert.areEqual(existing.Id, hit.leadId);
        Assert.isTrue(m.ownerIds().contains(UserInfo.getUserId()));
    }
}
