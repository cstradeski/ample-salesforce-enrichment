@IsTest
private class AmplemarketBatchEnrichQueueableTest {

    private class OkMock implements HttpCalloutMock {
        public HttpResponse respond(HttpRequest req) {
            HttpResponse res = new HttpResponse();
            res.setStatusCode(200);
            res.setBody('{"id":"abc","title":"Sales Director"}');
            return res;
        }
    }

    @IsTest
    static void executesEnrichmentForEachId() {
        List<Lead> leads = new List<Lead>{
            new Lead(LastName = 'A', Company = 'C', Email = 'a@b.com'),
            new Lead(LastName = 'B', Company = 'C', Email = 'b@b.com'),
            new Lead(LastName = 'C', Company = 'C', Email = 'c@b.com')
        };
        insert leads;

        AmplemarketEnrichmentService.testMappingOverride = new List<Amplemarket_Enrichment_Mapping__mdt>{
            new Amplemarket_Enrichment_Mapping__mdt(
                Object_API_Name__c = 'Lead', Mapping_Type__c = 'Match Input',
                Amplemarket_Field__c = 'email', Salesforce_Field__c = 'Email', Is_Active__c = true),
            new Amplemarket_Enrichment_Mapping__mdt(
                Object_API_Name__c = 'Lead', Mapping_Type__c = 'Output Field',
                Amplemarket_Field__c = 'title', Salesforce_Field__c = 'Title', Is_Active__c = true)
        };
        Test.setMock(HttpCalloutMock.class, new OkMock());

        List<Id> ids = new List<Id>();
        for (Lead l : leads) ids.add(l.Id);

        Test.startTest();
        System.enqueueJob(new AmplemarketBatchEnrichQueueable('Lead', ids));
        Test.stopTest();

        System.assertEquals(3, [SELECT COUNT() FROM Lead WHERE Title = 'Sales Director' AND Id IN :leads]);
    }

    @IsTest
    static void emptyIdListNoOps() {
        Test.startTest();
        new AmplemarketBatchEnrichQueueable('Lead', new List<Id>()).execute(null);
        Test.stopTest();
        // Should reach this point with no exception
        System.assert(true);
    }
}
