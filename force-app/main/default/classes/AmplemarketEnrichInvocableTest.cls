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

    private class CapturingMock implements HttpCalloutMock {
        public List<String> endpoints = new List<String>();
        public HttpResponse respond(HttpRequest req) {
            endpoints.add(req.getEndpoint());
            HttpResponse res = new HttpResponse();
            res.setStatusCode(200);
            res.setBody('{"id":"abc","title":"VP","email":"a@b.com"}');
            return res;
        }
    }

    @IsTest
    static void singleRecordPassesRevealOverrides() {
        Lead l = new Lead(LastName = 'A', Company = 'C', Website = 'https://linkedin.com/in/a');
        insert l;
        insert new List<Amplemarket_Mapping__c>{
            new Amplemarket_Mapping__c(
                Object_API_Name__c = 'Lead', Mapping_Type__c = 'Match Input',
                Amplemarket_Field__c = 'linkedin_url', Salesforce_Field__c = 'Website',
                Reveal_Email__c = false, Reveal_Phone__c = false, Is_Active__c = true),
            new Amplemarket_Mapping__c(
                Object_API_Name__c = 'Lead', Mapping_Type__c = 'Output Field',
                Amplemarket_Field__c = 'title', Salesforce_Field__c = 'Title', Is_Active__c = true)
        };
        CapturingMock mock = new CapturingMock();
        Test.setMock(HttpCalloutMock.class, mock);

        AmplemarketEnrichInvocable.Request r = new AmplemarketEnrichInvocable.Request();
        r.recordId = l.Id;
        r.objectApiName = 'Lead';
        r.revealEmail = true;
        r.revealPhone = true;

        Test.startTest();
        AmplemarketEnrichInvocable.enrich(new List<AmplemarketEnrichInvocable.Request>{ r });
        Test.stopTest();

        System.assertEquals(1, mock.endpoints.size());
        System.assert(mock.endpoints[0].contains('reveal_email=true'), mock.endpoints[0]);
        System.assert(mock.endpoints[0].contains('reveal_phone_numbers=true'), mock.endpoints[0]);
    }

    @IsTest
    static void bulkGroupsByRevealOverride() {
        // Two leads with different overrides must produce two callouts with distinct params.
        List<Lead> leads = new List<Lead>{
            new Lead(LastName = 'A', Company = 'C', Website = 'https://linkedin.com/in/a'),
            new Lead(LastName = 'B', Company = 'C', Website = 'https://linkedin.com/in/b')
        };
        insert leads;
        insert new List<Amplemarket_Mapping__c>{
            new Amplemarket_Mapping__c(
                Object_API_Name__c = 'Lead', Mapping_Type__c = 'Match Input',
                Amplemarket_Field__c = 'linkedin_url', Salesforce_Field__c = 'Website',
                Reveal_Email__c = false, Reveal_Phone__c = false, Is_Active__c = true),
            new Amplemarket_Mapping__c(
                Object_API_Name__c = 'Lead', Mapping_Type__c = 'Output Field',
                Amplemarket_Field__c = 'title', Salesforce_Field__c = 'Title', Is_Active__c = true)
        };
        CapturingMock mock = new CapturingMock();
        Test.setMock(HttpCalloutMock.class, mock);

        AmplemarketEnrichInvocable.Request r1 = new AmplemarketEnrichInvocable.Request();
        r1.recordId = leads[0].Id; r1.revealEmail = true;  r1.revealPhone = false;
        AmplemarketEnrichInvocable.Request r2 = new AmplemarketEnrichInvocable.Request();
        r2.recordId = leads[1].Id; r2.revealEmail = false; r2.revealPhone = false;

        Test.startTest();
        AmplemarketEnrichInvocable.enrich(new List<AmplemarketEnrichInvocable.Request>{ r1, r2 });
        Test.stopTest();

        Integer withReveal = 0;
        for (String ep : mock.endpoints) {
            if (ep.contains('reveal_email=true')) withReveal++;
        }
        System.assertEquals(2, mock.endpoints.size(), 'two override groups -> two callouts');
        System.assertEquals(1, withReveal, 'exactly one group should send reveal_email');
    }

    @IsTest
    static void emptyInputReturnsEmpty() {
        List<AmplemarketEnrichInvocable.Response> out = AmplemarketEnrichInvocable.enrich(new List<AmplemarketEnrichInvocable.Request>());
        System.assertEquals(0, out.size());
    }
}
