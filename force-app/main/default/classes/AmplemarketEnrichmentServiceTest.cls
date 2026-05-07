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

        List<Enrichment_Log_Field__c> outcomes = [
            SELECT Salesforce_Field__c, Status__c, New_Value__c
            FROM Enrichment_Log_Field__c
            WHERE Enrichment_Log__c = :res.logId
            ORDER BY Salesforce_Field__c
        ];
        System.assertEquals(2, outcomes.size(), 'Expect one child row per output mapping');
        for (Enrichment_Log_Field__c o : outcomes) {
            System.assertEquals('Applied', o.Status__c, o.Salesforce_Field__c + ' should be applied');
        }
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

    private class CapturingMock implements HttpCalloutMock {
        public String capturedEndpoint;
        public HttpResponse respond(HttpRequest req) {
            capturedEndpoint = req.getEndpoint();
            HttpResponse res = new HttpResponse();
            res.setStatusCode(200);
            res.setBody('{"id":"abc","title":"VP"}');
            return res;
        }
    }

    @IsTest
    static void doesNotSendRevealEmailWhenEmailIsMatchInput() {
        Lead l = new Lead(LastName = 'X', Company = 'Y', Email = 'jane@acme.com');
        insert l;
        insert new List<Amplemarket_Mapping__c>{
            new Amplemarket_Mapping__c(
                Object_API_Name__c = 'Lead', Mapping_Type__c = 'Match Input',
                Amplemarket_Field__c = 'email', Salesforce_Field__c = 'Email',
                Reveal_Email__c = true, Is_Active__c = true),
            new Amplemarket_Mapping__c(
                Object_API_Name__c = 'Lead', Mapping_Type__c = 'Output Field',
                Amplemarket_Field__c = 'title', Salesforce_Field__c = 'Title', Is_Active__c = true)
        };
        CapturingMock mock = new CapturingMock();
        Test.setMock(HttpCalloutMock.class, mock);

        Test.startTest();
        AmplemarketEnrichmentService.enrichSingle(l.Id, 'Lead');
        Test.stopTest();

        System.assert(mock.capturedEndpoint.contains('email='), 'email match input should be sent');
        System.assert(!mock.capturedEndpoint.contains('reveal_email'),
            'reveal_email must NOT be sent when email is already a match input. Got: ' + mock.capturedEndpoint);
    }

    @IsTest
    static void normalizeMatchValueStripsProtocolAndWww() {
        System.assertEquals('acme.com', AmplemarketEnrichmentService.normalizeMatchValue('domain', 'https://www.acme.com/about'));
        System.assertEquals('acme.com', AmplemarketEnrichmentService.normalizeMatchValue('domain', 'http://acme.com'));
        System.assertEquals('acme.com', AmplemarketEnrichmentService.normalizeMatchValue('domain', 'www.Acme.com'));
        System.assertEquals('acme.com', AmplemarketEnrichmentService.normalizeMatchValue('company_domain', 'acme.com'));
        // Non-domain keys are passed through (just trimmed)
        System.assertEquals('jane@acme.com', AmplemarketEnrichmentService.normalizeMatchValue('email', '  jane@acme.com '));
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

    @IsTest
    static void successResultIncludesAppliedFieldsHtml() {
        Lead l = new Lead(LastName = 'Doe', Company = 'Acme', Email = 'jane@acme.com');
        insert l;
        seedLeadMappings();
        Test.setMock(HttpCalloutMock.class, new PersonMock(200,
            '{"id":"abc","title":"VP of Engineering","company":{"industry":"SaaS"},"email":"jane@acme.com"}'));

        Test.startTest();
        AmplemarketEnrichmentService.ServiceResult res = AmplemarketEnrichmentService.enrichSingle(l.Id, 'Lead');
        Test.stopTest();

        System.assert(res.success, res.message);
        System.assertNotEquals(null, res.appliedFieldsHtml);
        System.assert(res.appliedFieldsHtml.contains('Successfully enriched'),
            'Expected success heading: ' + res.appliedFieldsHtml);
        // Field UI labels (not API names) should appear
        System.assert(res.appliedFieldsHtml.contains('Title:'), res.appliedFieldsHtml);
        System.assert(res.appliedFieldsHtml.contains('Industry:'), res.appliedFieldsHtml);
        // New values should appear
        System.assert(res.appliedFieldsHtml.contains('VP of Engineering'), res.appliedFieldsHtml);
        System.assert(res.appliedFieldsHtml.contains('SaaS'), res.appliedFieldsHtml);
    }

    @IsTest
    static void errorResultProducesAppliedFieldsHtml() {
        Lead l = new Lead(LastName = 'Doe', Company = 'Acme', Email = 'jane@acme.com');
        insert l;
        // No mappings seeded -> "No active match-input mappings configured" branch
        AmplemarketEnrichmentService.ServiceResult res = AmplemarketEnrichmentService.enrichSingle(l.Id, 'Lead');
        System.assertNotEquals(null, res.appliedFieldsHtml);
        System.assert(res.appliedFieldsHtml.contains('could not be completed'), res.appliedFieldsHtml);
    }
}
