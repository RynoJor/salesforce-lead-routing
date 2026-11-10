@IsTest
private class LeadFitScorerTest {
    @IsTest
    static void bestLeadScoresTheMaximum() {
        Lead l = new Lead(
            Inbound_Source__c = 'Demo Request',
            NumberOfEmployees = 120,
            Industry = 'Healthcare',
            Email = 'a@clinic.example.com'
        );
        Assert.areEqual(100, LeadFitScorer.score(l)); // 35 + 30 + 20 + 15
    }

    @IsTest
    static void eachPartAddsItsPoints() {
        Assert.areEqual(0, LeadFitScorer.score(new Lead()));
        Assert.areEqual(10, LeadFitScorer.score(new Lead(Inbound_Source__c = 'Content Download')));
        Assert.areEqual(10, LeadFitScorer.score(new Lead(Industry = 'Retail')), 'Non-core industry');
        Assert.areEqual(0, LeadFitScorer.score(new Lead(Email = 'a@gmail.com')), 'Public email adds nothing');
        Assert.areEqual(15, LeadFitScorer.score(new Lead(Email = 'a@shop.example.com')));
    }

    @IsTest
    static void sizeBands() {
        Assert.areEqual(0, LeadFitScorer.sizePoints(null));
        Assert.areEqual(0, LeadFitScorer.sizePoints(0));
        Assert.areEqual(10, LeadFitScorer.sizePoints(10));
        Assert.areEqual(25, LeadFitScorer.sizePoints(11));
        Assert.areEqual(25, LeadFitScorer.sizePoints(50));
        Assert.areEqual(30, LeadFitScorer.sizePoints(51));
    }
}
