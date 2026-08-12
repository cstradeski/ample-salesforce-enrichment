@IsTest
private class AmplemarketEnrichAsyncInvocableTest {

    private class OkMock implements HttpCalloutMock {
        public HttpResponse respond(HttpRequest req) {
            HttpResponse res = new HttpResponse();
            res.setStatusCode(200);
            res.setBody('{"id":"abc","title":"VP"}');
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

    private static AmplemarketEnrichAsyncInvocable.Request req(Id recordId, String objApi) {
        AmplemarketEnrichAsyncInvocable.Request r = new AmplemarketEnrichAsyncInvocable.Request();
        r.recordId = recordId;
        r.objectApiName = objApi;
        return r;
    }

    @IsTest
    static void queuesRequestWithoutCallingOut() {
        Lead l = new Lead(LastName = 'A', Company = 'C', Email = 'a@b.com');
        insert l;

        Test.startTest();
        List<AmplemarketEnrichAsyncInvocable.Response> out =
            AmplemarketEnrichAsyncInvocable.enrich(
                new List<AmplemarketEnrichAsyncInvocable.Request>{ req(l.Id, 'Lead') });
        Test.stopTest();

        System.assertEquals(1, out.size());
        System.assertEquals(true, out[0].queued, out[0].message);
        System.assertNotEquals(null, out[0].requestId);

        List<Enrichment_Request__c> rows = [
            SELECT Record_Id__c, Object_API_Name__c, Status__c FROM Enrichment_Request__c];
        System.assertEquals(1, rows.size());
        System.assertEquals('Pending', rows[0].Status__c);
        System.assertEquals(l.Id, rows[0].Record_Id__c);
        // Nothing enriched yet — the scheduled processor does that.
        System.assertEquals(null, [SELECT Title FROM Lead WHERE Id = :l.Id].Title);
    }

    @IsTest
    static void processorDrainsQueueAndEnriches() {
        Lead l = new Lead(LastName = 'A', Company = 'C', Email = 'a@b.com');
        insert l;
        seedLeadMappings();
        AmplemarketEnrichAsyncInvocable.enrich(
            new List<AmplemarketEnrichAsyncInvocable.Request>{ req(l.Id, 'Lead') });
        Test.setMock(HttpCalloutMock.class, new OkMock());

        Test.startTest();
        Integer claimed = AmplemarketEnrichRequestProcessor.run();
        Test.stopTest();

        System.assertEquals(1, claimed);
        System.assertEquals('VP', [SELECT Title FROM Lead WHERE Id = :l.Id].Title,
            'Processor should have enriched the queued record');
        Enrichment_Request__c row = [
            SELECT Status__c, Processed_At__c FROM Enrichment_Request__c LIMIT 1];
        System.assertEquals('Complete', row.Status__c);
        System.assertNotEquals(null, row.Processed_At__c);
    }

    @IsTest
    static void processorIsANoOpWithAnEmptyQueue() {
        Test.startTest();
        System.assertEquals(0, AmplemarketEnrichRequestProcessor.run());
        Test.stopTest();
    }

    @IsTest
    static void processorSkipsAlreadyClaimedRequests() {
        Lead l = new Lead(LastName = 'A', Company = 'C', Email = 'a@b.com');
        insert l;
        insert new Enrichment_Request__c(
            Record_Id__c = l.Id, Object_API_Name__c = 'Lead', Status__c = 'Processing');

        Test.startTest();
        System.assertEquals(0, AmplemarketEnrichRequestProcessor.run(),
            'Only Pending rows should be claimed');
        Test.stopTest();
    }

    @IsTest
    static void missingRecordIdIsReportedNotQueued() {
        AmplemarketEnrichAsyncInvocable.Request bad = new AmplemarketEnrichAsyncInvocable.Request();
        bad.recordId = null;

        List<AmplemarketEnrichAsyncInvocable.Response> out =
            AmplemarketEnrichAsyncInvocable.enrich(
                new List<AmplemarketEnrichAsyncInvocable.Request>{ bad });

        System.assertEquals(1, out.size());
        System.assertEquals(false, out[0].queued);
        System.assert(out[0].message.contains('recordId is required'), out[0].message);
        System.assertEquals(0, [SELECT COUNT() FROM Enrichment_Request__c]);
    }

    @IsTest
    static void emptyInputReturnsEmpty() {
        System.assertEquals(0, AmplemarketEnrichAsyncInvocable.enrich(null).size());
        System.assertEquals(0, AmplemarketEnrichAsyncInvocable.enrich(
            new List<AmplemarketEnrichAsyncInvocable.Request>()).size());
    }

    @IsTest
    static void groupingSplitsByObjectAndOverrides() {
        Lead a = new Lead(LastName = 'A', Company = 'C');
        Lead b = new Lead(LastName = 'B', Company = 'C');
        Account acct = new Account(Name = 'Acme');
        insert new List<SObject>{ a, b, acct };

        List<Enrichment_Request__c> rows = new List<Enrichment_Request__c>{
            new Enrichment_Request__c(Record_Id__c = a.Id, Object_API_Name__c = 'Lead',
                Reveal_Email__c = 'true', Status__c = 'Pending'),
            new Enrichment_Request__c(Record_Id__c = b.Id, Object_API_Name__c = 'Lead',
                Reveal_Email__c = 'false', Status__c = 'Pending'),
            new Enrichment_Request__c(Record_Id__c = acct.Id, Object_API_Name__c = 'Account',
                Status__c = 'Pending'),
            new Enrichment_Request__c(Record_Id__c = 'not-an-id', Object_API_Name__c = 'Lead',
                Status__c = 'Pending')
        };
        insert rows;

        List<AmplemarketAsyncEnrichQueueable.EnrichGroup> groups =
            AmplemarketAsyncEnrichQueueable.groupRequests(rows);

        System.assertEquals(3, groups.size(), 'Lead/true, Lead/false and Account are distinct groups');
        System.assertEquals(true, groups[0].revealEmail);
        System.assertEquals(false, groups[1].revealEmail);
        System.assertEquals('Account', groups[2].objectApiName);
        System.assertEquals(null, groups[2].revealEmail, 'Blank override means use the settings default');
        System.assertEquals(1, groups[0].requestIds.size(), 'Request ids track alongside record ids');
    }

    @IsTest
    static void parseOverrideHandlesBlankAndCase() {
        System.assertEquals(null, AmplemarketAsyncEnrichQueueable.parseOverride(null));
        System.assertEquals(null, AmplemarketAsyncEnrichQueueable.parseOverride('  '));
        System.assertEquals(true, AmplemarketAsyncEnrichQueueable.parseOverride('TRUE'));
        System.assertEquals(false, AmplemarketAsyncEnrichQueueable.parseOverride('false'));
    }

    @IsTest
    static void queueableWithNoGroupsIsSafe() {
        new AmplemarketAsyncEnrichQueueable(null).execute(null);
        new AmplemarketAsyncEnrichQueueable(
            new List<AmplemarketAsyncEnrichQueueable.EnrichGroup>()).execute(null);
        System.assertEquals(0, [SELECT COUNT() FROM Enrichment_Log__c]);
    }

    @IsTest
    static void cronMatchesTheChosenInterval() {
        Amplemarket_Credit_Config__c cfg = new Amplemarket_Credit_Config__c(
            SetupOwnerId = UserInfo.getOrganizationId(),
            Auto_Enrichment_Enabled__c = true,
            Auto_Enrichment_Interval__c = 15);
        insert cfg;

        // Apex needs a single integer minute, so an interval becomes one cron per offset.
        System.assertEquals(
            new List<String>{ '0 0 * * * ?', '0 15 * * * ?', '0 30 * * * ?', '0 45 * * * ?' },
            AmplemarketEnrichRequestProcessor.buildCrons(15));
        System.assertEquals(
            new List<String>{ '0 0 * * * ?', '0 30 * * * ?' },
            AmplemarketEnrichRequestProcessor.buildCrons(30));
        System.assertEquals(
            new List<String>{ '0 0 * * * ?' }, AmplemarketEnrichRequestProcessor.buildCrons(60));
        // Unsupported values fall back to 15 minutes.
        System.assertEquals(4, AmplemarketEnrichRequestProcessor.buildCrons(7).size());
        System.assertEquals(4, AmplemarketEnrichRequestProcessor.buildCrons(null).size());
        System.assertEquals(12, AmplemarketEnrichRequestProcessor.buildCrons(5).size());

        Test.startTest();
        Integer scheduled = AmplemarketEnrichRequestProcessor.reschedule(cfg);
        Test.stopTest();

        System.assertEquals(4, scheduled);
        String prefix = AmplemarketEnrichRequestProcessor.JOB_NAME + '%';
        System.assertEquals(4, [
            SELECT COUNT() FROM CronTrigger WHERE CronJobDetail.Name LIKE :prefix],
            'A 15-minute cadence schedules four jobs');
    }

    @IsTest
    static void disablingAutomationAbortsTheJob() {
        Amplemarket_Credit_Config__c cfg = new Amplemarket_Credit_Config__c(
            SetupOwnerId = UserInfo.getOrganizationId(),
            Auto_Enrichment_Enabled__c = true,
            Auto_Enrichment_Interval__c = 30);
        insert cfg;

        Test.startTest();
        System.assertEquals(2, AmplemarketEnrichRequestProcessor.reschedule(cfg));
        cfg.Auto_Enrichment_Enabled__c = false;
        System.assertEquals(0, AmplemarketEnrichRequestProcessor.reschedule(cfg));
        Test.stopTest();

        String prefix = AmplemarketEnrichRequestProcessor.JOB_NAME + '%';
        System.assertEquals(0, [
            SELECT COUNT() FROM CronTrigger WHERE CronJobDetail.Name LIKE :prefix]);
    }

    @IsTest
    static void schedulableEntryPointRuns() {
        Test.startTest();
        new AmplemarketEnrichRequestProcessor().execute(null);
        Test.stopTest();
        System.assertEquals(0, AmplemarketEnrichRequestProcessor.pendingCount());
    }
}
