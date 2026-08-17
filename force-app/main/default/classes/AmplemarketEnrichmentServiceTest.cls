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
        // 401 rather than 404 — a 404 now means "no match", which is not an error.
        Test.setMock(HttpCalloutMock.class, new PersonMock(401, '{"error":"unauthorized"}'));

        Test.startTest();
        AmplemarketEnrichmentService.ServiceResult res = AmplemarketEnrichmentService.enrichSingle(l.Id, 'Lead');
        Test.stopTest();

        System.assert(!res.success);
        System.assertEquals(1, [SELECT COUNT() FROM Enrichment_Log__c WHERE Status__c = 'Error']);
    }

    private static final String NOT_FOUND_BODY =
        '{"_errors":[{"code":"company_not_found","title":"Company Not Found",'
        + '"detail":"A matching company was not found in our database",'
        + '"source":{"pointer":"/linkedin_url"}}],"object":"error"}';

    @IsTest
    static void companyNotFoundIsRecordedAsNoMatchNotError() {
        Account a = new Account(Name = 'Acme', Website = 'acme.com');
        insert a;
        insert new List<Amplemarket_Mapping__c>{
            new Amplemarket_Mapping__c(
                Object_API_Name__c = 'Account', Mapping_Type__c = 'Match Input',
                Amplemarket_Field__c = 'domain', Salesforce_Field__c = 'Website', Is_Active__c = true),
            new Amplemarket_Mapping__c(
                Object_API_Name__c = 'Account', Mapping_Type__c = 'Output Field',
                Amplemarket_Field__c = 'estimated_number_of_employees',
                Salesforce_Field__c = 'NumberOfEmployees', Is_Active__c = true)
        };
        Test.setMock(HttpCalloutMock.class, new PersonMock(404, NOT_FOUND_BODY));

        Test.startTest();
        AmplemarketEnrichmentService.ServiceResult res =
            AmplemarketEnrichmentService.enrichSingle(a.Id, 'Account');
        Test.stopTest();

        System.assertEquals(false, res.success);
        System.assertEquals(0, res.creditsUsed, 'A miss must not bill credits');
        System.assert(res.message.contains('not found'), res.message);

        Enrichment_Log__c log = [
            SELECT Status__c, Credits_Used__c, Company_Search_Credits__c
            FROM Enrichment_Log__c WHERE Id = :res.logId];
        System.assertEquals('No Match', log.Status__c, 'A 404 miss is No Match, not Error');
        System.assertEquals(null, log.Credits_Used__c);
        System.assert(res.appliedFieldsHtml.contains('No matching company'), res.appliedFieldsHtml);
        // The API's own reason is surfaced to the user.
        System.assert(res.appliedFieldsHtml.contains('was not found in our database'),
            res.appliedFieldsHtml);
    }

    @IsTest
    static void personNotFoundIsAlsoNoMatch() {
        Lead l = new Lead(LastName = 'X', Company = 'Y', Email = 'nobody@nowhere.com');
        insert l;
        seedLeadMappings();
        Test.setMock(HttpCalloutMock.class, new PersonMock(404,
            '{"_errors":[{"code":"person_not_found","title":"Person Not Found"}],"object":"error"}'));

        Test.startTest();
        AmplemarketEnrichmentService.ServiceResult res =
            AmplemarketEnrichmentService.enrichSingle(l.Id, 'Lead');
        Test.stopTest();

        System.assertEquals('No Match',
            [SELECT Status__c FROM Enrichment_Log__c WHERE Id = :res.logId].Status__c);
        System.assert(res.appliedFieldsHtml.contains('No matching person'), res.appliedFieldsHtml);
    }

    @IsTest
    static void batchNotFoundIsNoMatchPerRecord() {
        List<Lead> leads = new List<Lead>{
            new Lead(LastName = 'A', Company = 'C', Email = 'a@b.com'),
            new Lead(LastName = 'B', Company = 'C', Email = 'b@b.com')
        };
        insert leads;
        seedLeadMappings();
        Test.setMock(HttpCalloutMock.class, new PersonMock(404,
            '{"_errors":[{"code":"person_not_found","detail":"A matching person was not found"}],"object":"error"}'));

        Test.startTest();
        List<AmplemarketEnrichmentService.ServiceResult> res =
            AmplemarketEnrichmentService.enrichBatch(new List<Id>{ leads[0].Id, leads[1].Id }, 'Lead');
        Test.stopTest();

        System.assertEquals(2, res.size());
        for (AmplemarketEnrichmentService.ServiceResult r : res) {
            System.assertEquals(false, r.success);
            System.assertEquals(0, r.creditsUsed);
        }
        System.assertEquals(2, [SELECT COUNT() FROM Enrichment_Log__c WHERE Status__c = 'No Match']);
        System.assertEquals(0, [SELECT COUNT() FROM Enrichment_Log__c WHERE Status__c = 'Error']);
    }

    @IsTest
    static void genuineApiErrorsStillReportAsErrors() {
        Lead l = new Lead(LastName = 'X', Company = 'Y', Email = 'a@b.com');
        insert l;
        seedLeadMappings();
        Test.setMock(HttpCalloutMock.class, new PersonMock(500, '{"message":"boom"}'));

        Test.startTest();
        AmplemarketEnrichmentService.ServiceResult res =
            AmplemarketEnrichmentService.enrichSingle(l.Id, 'Lead');
        Test.stopTest();

        System.assertEquals('Error',
            [SELECT Status__c FROM Enrichment_Log__c WHERE Id = :res.logId].Status__c,
            'Non-404 failures must still be errors');
        System.assert(res.message.contains('500'), res.message);
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
    static void revealOverrideForcesRevealOnWhenSettingsDefaultOff() {
        // LinkedIn match input (so email isn't a match key), reveal flags OFF in settings.
        Lead l = new Lead(LastName = 'X', Company = 'Y', Website = 'https://linkedin.com/in/jane');
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

        Test.startTest();
        AmplemarketEnrichmentService.enrichSingle(l.Id, 'Lead', true, true);
        Test.stopTest();

        System.assert(mock.capturedEndpoint.contains('reveal_email=true'),
            'override should force reveal_email on. Got: ' + mock.capturedEndpoint);
        System.assert(mock.capturedEndpoint.contains('reveal_phone_numbers=true'),
            'override should force reveal_phone on. Got: ' + mock.capturedEndpoint);
    }

    @IsTest
    static void revealOverrideForcesRevealOffWhenSettingsDefaultOn() {
        Lead l = new Lead(LastName = 'X', Company = 'Y', Website = 'https://linkedin.com/in/jane');
        insert l;
        insert new List<Amplemarket_Mapping__c>{
            new Amplemarket_Mapping__c(
                Object_API_Name__c = 'Lead', Mapping_Type__c = 'Match Input',
                Amplemarket_Field__c = 'linkedin_url', Salesforce_Field__c = 'Website',
                Reveal_Email__c = true, Reveal_Phone__c = true, Is_Active__c = true),
            new Amplemarket_Mapping__c(
                Object_API_Name__c = 'Lead', Mapping_Type__c = 'Output Field',
                Amplemarket_Field__c = 'title', Salesforce_Field__c = 'Title', Is_Active__c = true)
        };
        CapturingMock mock = new CapturingMock();
        Test.setMock(HttpCalloutMock.class, mock);

        Test.startTest();
        AmplemarketEnrichmentService.enrichSingle(l.Id, 'Lead', false, false);
        Test.stopTest();

        System.assert(!mock.capturedEndpoint.contains('reveal_email'),
            'override false should suppress reveal_email. Got: ' + mock.capturedEndpoint);
        System.assert(!mock.capturedEndpoint.contains('reveal_phone'),
            'override false should suppress reveal_phone. Got: ' + mock.capturedEndpoint);
    }

    @IsTest
    static void revealDefaultsReflectSettingsForPersonAndCompany() {
        insert new Amplemarket_Mapping__c(
            Object_API_Name__c = 'Lead', Mapping_Type__c = 'Match Input',
            Amplemarket_Field__c = 'linkedin_url', Salesforce_Field__c = 'Website',
            Reveal_Email__c = true, Reveal_Phone__c = false, Is_Active__c = true);

        AmplemarketEnrichmentService.RevealDefaults person =
            AmplemarketEnrichmentService.revealDefaults(null, 'Lead');
        System.assertEquals(true, person.isPerson);
        System.assertEquals(true, person.revealEmail);
        System.assertEquals(false, person.revealPhone);

        // Company objects never reveal — always false regardless of any config.
        AmplemarketEnrichmentService.RevealDefaults company =
            AmplemarketEnrichmentService.revealDefaults(null, 'Account');
        System.assertEquals(false, company.isPerson);
        System.assertEquals(false, company.revealEmail);
        System.assertEquals(false, company.revealPhone);
    }

    @IsTest
    static void previewCreditsOverrideRaisesWorstCase() {
        Lead l = new Lead(LastName = 'X', Company = 'Y', Website = 'https://linkedin.com/in/jane');
        insert l;
        // Settings default has reveals OFF; override turns both on for the estimate.
        insert new Amplemarket_Mapping__c(
            Object_API_Name__c = 'Lead', Mapping_Type__c = 'Match Input',
            Amplemarket_Field__c = 'linkedin_url', Salesforce_Field__c = 'Website',
            Reveal_Email__c = false, Reveal_Phone__c = false, Is_Active__c = true);

        AmplemarketEnrichmentService.CreditPreview def =
            AmplemarketEnrichmentService.previewCredits(l.Id, 'Lead');
        System.assertEquals(0.5, def.worstCase, 'no reveals -> match only');

        AmplemarketEnrichmentService.CreditPreview overridden =
            AmplemarketEnrichmentService.previewCredits(l.Id, 'Lead', true, true);
        System.assertEquals(2.5, overridden.worstCase, 'match + reveal email + reveal phone');
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

        // Company match credit lands in Company_Search_Credits__c, not Person_Search.
        Enrichment_Log__c log = [
            SELECT Person_Search_Credits__c, Company_Search_Credits__c,
                   Email_Reveal_Credits__c, Phone_Reveal_Credits__c, Credits_Used__c
            FROM Enrichment_Log__c WHERE Id = :res.logId];
        System.assertEquals(0.5, log.Company_Search_Credits__c);
        System.assertEquals(0, log.Person_Search_Credits__c);
        System.assertEquals(0.5, log.Credits_Used__c);
    }

    @IsTest
    static void breakdownFieldsWrittenForPersonWithReveals() {
        // LinkedIn match input (email not a match key), reveals forced on via override,
        // response returns email + phone, so all three person categories bill.
        Lead l = new Lead(LastName = 'X', Company = 'Y', Website = 'https://linkedin.com/in/jane');
        insert l;
        insert new List<Amplemarket_Mapping__c>{
            new Amplemarket_Mapping__c(
                Object_API_Name__c = 'Lead', Mapping_Type__c = 'Match Input',
                Amplemarket_Field__c = 'linkedin_url', Salesforce_Field__c = 'Website', Is_Active__c = true),
            new Amplemarket_Mapping__c(
                Object_API_Name__c = 'Lead', Mapping_Type__c = 'Output Field',
                Amplemarket_Field__c = 'title', Salesforce_Field__c = 'Title', Is_Active__c = true)
        };
        Test.setMock(HttpCalloutMock.class, new PersonMock(200,
            '{"id":"abc","title":"VP","email":"a@b.com","phone_numbers":[{"number":"+15551234"}]}'));

        Test.startTest();
        AmplemarketEnrichmentService.ServiceResult res =
            AmplemarketEnrichmentService.enrichSingle(l.Id, 'Lead', true, true);
        Test.stopTest();

        Enrichment_Log__c log = [
            SELECT Person_Search_Credits__c, Company_Search_Credits__c,
                   Email_Reveal_Credits__c, Phone_Reveal_Credits__c, Credits_Used__c
            FROM Enrichment_Log__c WHERE Id = :res.logId];
        System.assertEquals(0.5, log.Person_Search_Credits__c);
        System.assertEquals(0, log.Company_Search_Credits__c);
        System.assertEquals(1, log.Email_Reveal_Credits__c);
        System.assertEquals(1, log.Phone_Reveal_Credits__c);
        System.assertEquals(2.5, log.Credits_Used__c);
        System.assertEquals(2.5, res.creditsUsed);
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
        // Credits consumed line should appear and creditsUsed should be populated.
        // seedLeadMappings: email match + reveal_email=true. Service suppresses reveal_email
        // when email is the match key, so credits = 0.5 (just the match).
        System.assertEquals(0.5, res.creditsUsed);
        System.assert(res.appliedFieldsHtml.contains('credits consumed'), res.appliedFieldsHtml);
        System.assert(res.appliedFieldsHtml.contains('0.5'), res.appliedFieldsHtml);
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

    @IsTest
    static void previewCreditsWithoutMappings() {
        Lead l = new Lead(LastName = 'Doe', Company = 'Acme', Email = 'jane@acme.com');
        insert l;

        AmplemarketEnrichmentService.CreditPreview cp =
            AmplemarketEnrichmentService.previewCredits(l.Id, 'Lead');

        System.assertEquals(false, cp.hasMappings);
        System.assertEquals(0, cp.worstCase);
        System.assert(cp.summaryHtml.contains('No active match-input mappings'), cp.summaryHtml);
    }

    @IsTest
    static void previewCreditsLeadWithRevealEmailAndPhone() {
        Lead l = new Lead(LastName = 'Doe', Company = 'Acme', Email = 'jane@acme.com');
        insert l;
        // Match input is LinkedIn (not email), and reveal_email + reveal_phone enabled —
        // worst case should be 0.5 + 1 + 1 = 2.5
        insert new Amplemarket_Mapping__c(
            Object_API_Name__c = 'Lead', Mapping_Type__c = 'Match Input',
            Amplemarket_Field__c = 'linkedin_url', Salesforce_Field__c = 'Website',
            Reveal_Email__c = true, Reveal_Phone__c = true, Is_Active__c = true);

        AmplemarketEnrichmentService.CreditPreview cp =
            AmplemarketEnrichmentService.previewCredits(l.Id, 'Lead');

        System.assertEquals(true, cp.hasMappings);
        System.assertEquals(true, cp.isPerson);
        System.assertEquals(0.5, cp.matchOnlyCase);
        System.assertEquals(2.5, cp.worstCase);
        System.assert(cp.summaryHtml.contains('revealed email'), cp.summaryHtml);
        System.assert(cp.summaryHtml.contains('revealed phone'), cp.summaryHtml);
    }

    @IsTest
    static void previewCreditsLeadEmailMatchSuppressesRevealEmailCharge() {
        Lead l = new Lead(LastName = 'Doe', Company = 'Acme', Email = 'jane@acme.com');
        insert l;
        // email is the match input AND reveal_email is checked — service suppresses
        // reveal_email when email is already a match key, so worst case is 0.5 (no reveal cost)
        insert new Amplemarket_Mapping__c(
            Object_API_Name__c = 'Lead', Mapping_Type__c = 'Match Input',
            Amplemarket_Field__c = 'email', Salesforce_Field__c = 'Email',
            Reveal_Email__c = true, Reveal_Phone__c = false, Is_Active__c = true);

        AmplemarketEnrichmentService.CreditPreview cp =
            AmplemarketEnrichmentService.previewCredits(l.Id, 'Lead');

        System.assertEquals(0.5, cp.worstCase, 'reveal_email should not contribute when email is a match key');
    }

    @IsTest
    static void previewCreditsLeadEmailMatchWithBlankSourceStillBillsRevealEmail() {
        // Email is configured as a match input, but the source Lead's Email is blank.
        // The service iterates match inputs and sets revealEmail=true regardless of source,
        // but only puts 'email' in queryParams when the source has a value. Here the source
        // doesn't, so reveal_email IS sent and Amplemarket bills for it. Worst case = 1.5.
        Lead l = new Lead(LastName = 'Doe', Company = 'Acme'); // Email left blank
        insert l;
        insert new Amplemarket_Mapping__c(
            Object_API_Name__c = 'Lead', Mapping_Type__c = 'Match Input',
            Amplemarket_Field__c = 'email', Salesforce_Field__c = 'Email',
            Reveal_Email__c = true, Reveal_Phone__c = false, Is_Active__c = true);

        AmplemarketEnrichmentService.CreditPreview cp =
            AmplemarketEnrichmentService.previewCredits(l.Id, 'Lead');

        System.assertEquals(1.5, cp.worstCase,
            'Source email is blank, so reveal_email IS sent and worst case must include the +1 charge.');
    }

    @IsTest
    static void revealEmailChargedWhenSentForReal() {
        // Linkedin is the match key (so email is NOT a match input), reveal_email=true →
        // service does send reveal_email=true to API, and Amplemarket bills for the reveal.
        // Expected: 0.5 (match) + 1.0 (reveal email) = 1.5 credits.
        Lead l = new Lead(LastName = 'Doe', Company = 'Acme', Website = 'https://linkedin.com/in/jane');
        insert l;
        insert new Amplemarket_Mapping__c(
            Object_API_Name__c = 'Lead', Mapping_Type__c = 'Match Input',
            Amplemarket_Field__c = 'linkedin_url', Salesforce_Field__c = 'Website',
            Reveal_Email__c = true, Is_Active__c = true);

        Test.setMock(HttpCalloutMock.class, new PersonMock(200,
            '{"id":"abc","email":"jane@acme.com"}'));

        Test.startTest();
        AmplemarketEnrichmentService.ServiceResult res = AmplemarketEnrichmentService.enrichSingle(l.Id, 'Lead');
        Test.stopTest();

        System.assertEquals(1.5, res.creditsUsed, 'reveal_email was sent and email returned, so should bill 1.5');
    }

    @IsTest
    static void previewCreditsAccountIsHalfCredit() {
        Account a = new Account(Name = 'Acme', Website = 'acme.com');
        insert a;
        insert new Amplemarket_Mapping__c(
            Object_API_Name__c = 'Account', Mapping_Type__c = 'Match Input',
            Amplemarket_Field__c = 'domain', Salesforce_Field__c = 'Website', Is_Active__c = true);

        AmplemarketEnrichmentService.CreditPreview cp =
            AmplemarketEnrichmentService.previewCredits(a.Id, 'Account');

        System.assertEquals(true, cp.hasMappings);
        System.assertEquals(false, cp.isPerson);
        System.assertEquals(0.5, cp.worstCase);
        System.assertEquals(cp.matchOnlyCase, cp.worstCase, 'No reveals on companies — single tier');
    }
}
