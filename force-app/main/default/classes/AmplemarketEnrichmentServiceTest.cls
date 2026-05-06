@IsTest
private class AmplemarketEnrichmentServiceTest {

    private class PersonMock implements HttpCalloutMock {
        Integer status;
        String body;
        public PersonMock(Integer s, String b) { status = s; body = b; }
        public HttpResponse respond(HttpRequest req) {
            HttpResponse res = new HttpResponse();
            res.setStatusCode(status);
            res.setBody(body);
            return res;
        }
    }

    private static void seedLeadMappings() {
        insert new List<Amplemarket_Mapping__c>{
            new Amplemarket_Mapping__c(
                Object_API_Name__c = 'Lead', Mapping_Type__c = 'Match Input',
                Amplemarket_Field__c = 'email', Salesforce_Field__c = 'Email',
                Reveal_Email__c = true, Is_Active__c = true),
            new Amplemarket_Mapping__c(
                Object_API_Name__c = 'Lead', Mapping_Type__c = 'Output Field',
                Amplemarket_Field__c = 'title', Salesforce_Field__c = 'Title', Is_Active__c = true),
            new Amplemarket_Mapping__c(
                Object_API_Name__c = 'Lead', Mapping_Type__c = 'Output Field',
                Amplemarket_Field__c = 'company.industry', Salesforce_Field__c = 'Industry', Is_Active__c = true)
        };
    }

    @IsTest
    static void enrichSinglePersonHappyPath() {
        Lead l = new Lead(LastName = 'Doe', Company = 'Acme', Email = 'jane@acme.com');
        insert l;
        seedLeadMappings();

        String json = '{"id":"abc","title":"VP","company":{"industry":"SaaS"},"email":"jane@acme.com"}';
        Test.setMock(HttpCalloutMock.class, new PersonMock(200, json));

        Test.startTest();
        AmplemarketEnrichmentService.ServiceResult res = AmplemarketEnrichmentService.enrichSingle(l.Id, 'Lead');
        Test.stopTest();

        System.assert(res.success, res.message);
        Lead updated = [SELECT Id, Title, Industry FROM Lead WHERE Id = :l.Id];
        System.assertEquals('VP', updated.Title);
        System.assertEquals('SaaS', updated.Industry);
        System.assertEquals(1, [SELECT COUNT() FROM Enrichment_Log__c WHERE Status__c = 'Success']);
    }

    @IsTest
    static void enrichSingleSurfacesApiError() {
        Lead l = new Lead(LastName = 'Doe', Company = 'Acme', Email = 'jane@acme.com');
        insert l;
        seedLeadMappings();
        Test.setMock(HttpCalloutMock.class, new PersonMock(404, '{"error":"not_found"}'));

        Test.startTest();
        AmplemarketEnrichmentService.ServiceResult res = AmplemarketEnrichmentService.enrichSingle(l.Id, 'Lead');
        Test.stopTest();

        System.assert(!res.success);
        System.assertEquals(1, [SELECT COUNT() FROM Enrichment_Log__c WHERE Status__c = 'Error']);
    }

    @IsTest
    static void enrichSingleErrorsWhenNoMappings() {
        Lead l = new Lead(LastName = 'X', Company = 'Y');
        insert l;

        Test.startTest();
        AmplemarketEnrichmentService.ServiceResult res = AmplemarketEnrichmentService.enrichSingle(l.Id, 'Lead');
        Test.stopTest();

        System.assert(!res.success);
        System.assertEquals(1, [SELECT COUNT() FROM Enrichment_Log__c WHERE Status__c = 'Error']);
    }

    @IsTest
    static void enrichSingleErrorsWhenMatchInputsHaveNoValues() {
        Lead l = new Lead(LastName = 'X', Company = 'Y');
        insert l;
        seedLeadMappings();

        Test.startTest();
        AmplemarketEnrichmentService.ServiceResult res = AmplemarketEnrichmentService.enrichSingle(l.Id, 'Lead');
        Test.stopTest();

        System.assert(!res.success);
        System.assertEquals('Source record has no values for any configured match input.', res.message);
    }

    @IsTest
    static void enrichSingleHandlesCompanyEndpoint() {
        Account a = new Account(Name = 'Acme', Website = 'acme.com');
        insert a;
        insert new List<Amplemarket_Mapping__c>{
            new Amplemarket_Mapping__c(
                Object_API_Name__c = 'Account', Mapping_Type__c = 'Match Input',
                Amplemarket_Field__c = 'domain', Salesforce_Field__c = 'Website', Is_Active__c = true),
            new Amplemarket_Mapping__c(
                Object_API_Name__c = 'Account', Mapping_Type__c = 'Output Field',
                Amplemarket_Field__c = 'estimated_number_of_employees', Salesforce_Field__c = 'NumberOfEmployees', Is_Active__c = true)
        };
        Test.setMock(HttpCalloutMock.class, new PersonMock(200, '{"id":"c1","estimated_number_of_employees":250}'));

        Test.startTest();
        AmplemarketEnrichmentService.ServiceResult res = AmplemarketEnrichmentService.enrichSingle(a.Id, 'Account');
        Test.stopTest();

        System.assert(res.success, res.message);
        System.assertEquals(250, [SELECT NumberOfEmployees FROM Account WHERE Id = :a.Id].NumberOfEmployees);
    }
}
