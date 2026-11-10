/**
 * Fit score 0-100, the same points idea as fit_score() in the Python router:
 * buying intent (source) + company size + industry fit + business email.
 */
public with sharing class LeadFitScorer {
    @TestVisible
    private static final Map<String, Integer> SOURCE_POINTS = new Map<String, Integer>{
        'Demo Request' => 35,
        'Free Trial' => 30,
        'Website Form' => 20,
        'Content Download' => 10
    };
    /** Standard Lead.Industry values closest to the Python router's core industries. */
    @TestVisible
    private static final Set<String> CORE_INDUSTRIES = new Set<String>{ 'Healthcare', 'Recreation', 'Consulting' };

    public static Integer score(Lead l) {
        Integer score = 0;
        if (l.Inbound_Source__c != null && SOURCE_POINTS.containsKey(l.Inbound_Source__c)) {
            score += SOURCE_POINTS.get(l.Inbound_Source__c);
        }
        score += sizePoints(l.NumberOfEmployees);
        if (String.isNotBlank(l.Industry)) {
            score += CORE_INDUSTRIES.contains(l.Industry) ? 20 : 10;
        }
        if (LeadDuplicateMatcher.businessDomain(l.Email) != null) {
            score += 15;
        }
        return Math.min(score, 100);
    }

    @TestVisible
    private static Integer sizePoints(Integer employees) {
        if (employees == null || employees < 1) {
            return 0;
        }
        if (employees > 50) {
            return 30;
        }
        return employees > 10 ? 25 : 10;
    }
}
