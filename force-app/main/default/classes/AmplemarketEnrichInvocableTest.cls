@IsTest
private class AmplemarketEnrichInvocableTest {

    private class OkMock implements HttpCalloutMock {
        public HttpResponse respond(HttpRequest req) {
            HttpResponse res = new HttpResponse();
            res.setStatusCode(200);
            res.setBody('{"id":"abc","title":"VP","email":"a@b.com"}');
            return res;
        }
    }

    private static void seedLeadMappings() {
        insert new List<Amplemarket_Mapping__c>{
            new Amplemarket_Mapping__c(
                Object_API_Name__c = 'Lead', Mapping_Type__c = 'Match Input',
                Amplemarket_Field__c = 'email', Salesforce_Field__c = 'Email', Is_Active__c = true),
            new Amplemarket_Mapping__c(
                Object_API_Name__c = 'Lead', Mapping_Type__c = 'Output Field',
                Amplemarket_Field__c = 'title', Salesforce_Field__c = 'Title', Is_Active__c = true)
        };
    }

    @IsTest
    static void singleRecordInvocationCallsService() {
        Lead l = new Lead(LastName = 'A', Company = 'C', Email = 'a@b.com');
        insert l;
        seedLeadMappings();
        Test.setMock(HttpCalloutMock.class, new OkMock());

        AmplemarketEnrichInvocable.Request r = new AmplemarketEnrichInvocable.Request();
        r.recordId = l.Id;
        r.objectApiName = 'Lead';

        Test.startTest();
        List<AmplemarketEnrichInvocable.Response> out = AmplemarketEnrichInvocable.enrich(
            new List<AmplemarketEnrichInvocable.Request>{ r }
        );
        Test.stopTest();

        System.assertEquals(1, out.size());
        System.assert(out[0].success, out[0].message);
        System.assertEquals('VP', [SELECT Title FROM Lead WHERE Id = :l.Id].Title);
    }

    @IsTest
    static void bulkRecordsDispatchAsync() {
        List<Lead> leads = new List<Lead>{
            new Lead(LastName = 'A', Company = 'C', Email = 'a@b.com'),
            new Lead(LastName = 'B', Company = 'C', Email = 'b@b.com')
        };
        insert leads;
        seedLeadMappings();
        Test.setMock(HttpCalloutMock.class, new OkMock());

        List<AmplemarketEnrichInvocable.Request> reqs = new List<AmplemarketEnrichInvocable.Request>();
        for (Lead l : leads) {
            AmplemarketEnrichInvocable.Request r = new AmplemarketEnrichInvocable.Request();
            r.recordId = l.Id;
            reqs.add(r);
        }

        Test.startTest();
        List<AmplemarketEnrichInvocable.Response> out = AmplemarketEnrichInvocable.enrich(reqs);
        Test.stopTest();

        System.assertEquals(2, out.size());
        Integer updated = [SELECT COUNT() FROM Lead WHERE Title = 'VP' AND Id IN :leads];
        System.assertEquals(2, updated);
    }

    @IsTest
    static void emptyInputReturnsEmpty() {
        List<AmplemarketEnrichInvocable.Response> out = AmplemarketEnrichInvocable.enrich(new List<AmplemarketEnrichInvocable.Request>());
        System.assertEquals(0, out.size());
    }
}
