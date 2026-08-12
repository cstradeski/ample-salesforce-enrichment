@IsTest
private class AmplemarketCreditControllerTest {

    @IsTest
    static void dashboardReturnsWeeklyAndAllTimePerCategory() {
        String rid = UserInfo.getUserId();
        insert new List<Enrichment_Log__c>{
            new Enrichment_Log__c(Record_Id__c = rid, Object_API_Name__c = 'Lead', Status__c = 'Success',
                Run_Timestamp__c = Datetime.now(),
                Person_Search_Credits__c = 0.5, Email_Reveal_Credits__c = 1),
            new Enrichment_Log__c(Record_Id__c = rid, Object_API_Name__c = 'Account', Status__c = 'Success',
                Run_Timestamp__c = Datetime.now(), Company_Search_Credits__c = 0.5),
            // Out-of-week row counts toward all-time but not weekly.
            new Enrichment_Log__c(Record_Id__c = rid, Object_API_Name__c = 'Lead', Status__c = 'Success',
                Run_Timestamp__c = AmplemarketCreditMonitor.weekStartDatetime().addDays(-2),
                Person_Search_Credits__c = 3)
        };

        AmplemarketCreditController.DashboardData d = AmplemarketCreditController.getDashboard();

        Map<String, AmplemarketCreditController.CategoryRow> byKey =
            new Map<String, AmplemarketCreditController.CategoryRow>();
        for (AmplemarketCreditController.CategoryRow r : d.categories) byKey.put(r.key, r);

        System.assertEquals(4, d.categories.size());
        System.assertEquals(0.5, byKey.get('personSearch').weeklyUsed);
        System.assertEquals(3.5, byKey.get('personSearch').allTimeUsed);
        System.assertEquals(1, byKey.get('emailReveal').weeklyUsed);
        System.assertEquals(0.5, byKey.get('companySearch').weeklyUsed);
    }

    @IsTest
    static void saveConfigRoundTrips() {
        Test.startTest();
        AmplemarketCreditController.saveConfig(10, 20, 5, 5, true, UserInfo.getUserId(),
            1000, String.valueOf(Date.today().addDays(-10)), String.valueOf(Date.today().addDays(355)),
            false, null, 'MON', 8, 0);
        Test.stopTest();

        Amplemarket_Credit_Config__c cfg = [
            SELECT Person_Search_Limit__c, Company_Search_Limit__c, Email_Reveal_Limit__c,
                   Phone_Reveal_Limit__c, Enforce_Limits__c, Notify_User_Id__c
            FROM Amplemarket_Credit_Config__c
            WHERE SetupOwnerId = :UserInfo.getOrganizationId() LIMIT 1];
        System.assertEquals(10, cfg.Person_Search_Limit__c);
        System.assertEquals(20, cfg.Company_Search_Limit__c);
        System.assertEquals(5, cfg.Email_Reveal_Limit__c);
        System.assertEquals(true, cfg.Enforce_Limits__c);
        System.assertEquals(UserInfo.getUserId(), cfg.Notify_User_Id__c);

        // Dashboard reflects the saved config.
        AmplemarketCreditController.DashboardData d = AmplemarketCreditController.getDashboard();
        System.assertEquals(true, d.enforceLimits);
        System.assertEquals(UserInfo.getUserId(), d.notifyUserId);
        System.assertEquals(1000, d.annualAllowance);
        System.assertEquals(true, d.contractConfigured);
        System.assertEquals(String.valueOf(Date.today().addDays(-10)), d.contractStart);
    }

    @IsTest
    static void saveConfigRejectsEndBeforeStart() {
        Boolean threw = false;
        try {
            AmplemarketCreditController.saveConfig(null, null, null, null, false, null,
                100, String.valueOf(Date.today()), String.valueOf(Date.today().addDays(-1)),
                false, null, 'MON', 8, 0);
        } catch (AuraHandledException e) {
            threw = true;
        }
        System.assertEquals(true, threw, 'End before start should be rejected');
    }

    @IsTest
    static void dashboardCountsOnlyCurrentContractPeriod() {
        String rid = UserInfo.getUserId();
        // Contract started 5 days ago; a log from before it must not count.
        AmplemarketCreditController.saveConfig(null, null, null, null, false, null,
            500, String.valueOf(Date.today().addDays(-5)), String.valueOf(Date.today().addDays(360)),
            false, null, 'MON', 8, 0);
        insert new List<Enrichment_Log__c>{
            new Enrichment_Log__c(Record_Id__c = rid, Object_API_Name__c = 'Lead', Status__c = 'Success',
                Run_Timestamp__c = Datetime.now(), Person_Search_Credits__c = 2, Credits_Used__c = 2),
            new Enrichment_Log__c(Record_Id__c = rid, Object_API_Name__c = 'Lead', Status__c = 'Success',
                Run_Timestamp__c = Datetime.now().addDays(-30), Person_Search_Credits__c = 9, Credits_Used__c = 9)
        };

        AmplemarketCreditController.DashboardData d = AmplemarketCreditController.getDashboard();
        System.assertEquals(2, d.annualUsed, 'Only spend inside the current contract period should count');
    }

    @IsTest
    static void saveConfigClearsNotifyUserWhenBlank() {
        AmplemarketCreditController.saveConfig(1, null, null, null, false, '', null, null, null,
            false, null, 'MON', 8, 0);
        Amplemarket_Credit_Config__c cfg = [
            SELECT Notify_User_Id__c FROM Amplemarket_Credit_Config__c
            WHERE SetupOwnerId = :UserInfo.getOrganizationId() LIMIT 1];
        System.assertEquals(null, cfg.Notify_User_Id__c);
    }

    @IsTest
    static void savingEnabledDigestSchedulesTheJob() {
        Test.startTest();
        AmplemarketCreditController.saveConfig(null, null, null, null, false, null,
            null, null, null, true, 'ops@example.com, finance@example.com', 'WED', 17, 30);
        Test.stopTest();

        List<CronTrigger> jobs = [
            SELECT CronExpression FROM CronTrigger
            WHERE CronJobDetail.Name = :AmplemarketCreditDigest.JOB_NAME];
        System.assertEquals(1, jobs.size(), 'Enabling the digest should schedule one job');
        System.assertEquals('0 30 17 ? * WED', jobs[0].CronExpression);

        Amplemarket_Credit_Config__c cfg = [
            SELECT Digest_Enabled__c, Digest_Recipients__c, Digest_Day_Of_Week__c,
                   Digest_Hour__c, Digest_Minute__c
            FROM Amplemarket_Credit_Config__c
            WHERE SetupOwnerId = :UserInfo.getOrganizationId() LIMIT 1];
        System.assertEquals(true, cfg.Digest_Enabled__c);
        System.assertEquals('ops@example.com, finance@example.com', cfg.Digest_Recipients__c);
        System.assertEquals('WED', cfg.Digest_Day_Of_Week__c);
        System.assertEquals(17, cfg.Digest_Hour__c);
        System.assertEquals(30, cfg.Digest_Minute__c);
    }

    @IsTest
    static void enablingDigestWithoutRecipientsIsRejected() {
        Boolean threw = false;
        try {
            AmplemarketCreditController.saveConfig(null, null, null, null, false, null,
                null, null, null, true, '   ', 'MON', 8, 0);
        } catch (AuraHandledException e) {
            threw = true;
        }
        System.assertEquals(true, threw, 'Enabling the digest with no recipients should be rejected');
    }

    @IsTest
    static void invalidDigestEmailIsRejected() {
        Boolean threw = false;
        try {
            AmplemarketCreditController.saveConfig(null, null, null, null, false, null,
                null, null, null, false, 'not-an-email', 'MON', 8, 0);
        } catch (AuraHandledException e) {
            threw = true;
        }
        System.assertEquals(true, threw, 'Malformed recipient address should be rejected');
    }

    @IsTest
    static void sendDigestNowReturnsMessage() {
        Test.startTest();
        AmplemarketCreditController.saveConfig(null, null, null, null, false, null,
            null, null, null, false, 'ops@example.com', 'MON', 8, 0);
        String msg = AmplemarketCreditController.sendDigestNow();
        Test.stopTest();
        System.assertNotEquals(null, msg);
        System.assert(msg.contains('ops@example.com'), msg);
    }

    @IsTest
    static void enablingAutomationSchedulesJobAndRecordsRunAsUser() {
        Test.startTest();
        AmplemarketCreditController.saveAutomation(true, 30);
        Test.stopTest();

        Amplemarket_Credit_Config__c cfg = [
            SELECT Auto_Enrichment_Enabled__c, Auto_Enrichment_Interval__c, Auto_Enrichment_Run_As__c
            FROM Amplemarket_Credit_Config__c
            WHERE SetupOwnerId = :UserInfo.getOrganizationId() LIMIT 1];
        System.assertEquals(true, cfg.Auto_Enrichment_Enabled__c);
        System.assertEquals(30, cfg.Auto_Enrichment_Interval__c);
        System.assertEquals(UserInfo.getUserId(), cfg.Auto_Enrichment_Run_As__c,
            'The saving user becomes the run-as user for automated callouts');

        String prefix = AmplemarketEnrichRequestProcessor.JOB_NAME + '%';
        System.assertEquals(2, [
            SELECT COUNT() FROM CronTrigger WHERE CronJobDetail.Name LIKE :prefix],
            'A 30-minute cadence schedules two jobs');

        AmplemarketCreditController.AutomationData a = AmplemarketCreditController.getAutomation();
        System.assertEquals(true, a.enabled);
        System.assertEquals(30, a.interval);
        System.assertEquals(true, a.runAsIsCurrentUser);
        System.assertNotEquals(null, a.runAsName);
        System.assertNotEquals(null, a.currentUserName);
        System.assertEquals(0, a.pending);
    }

    @IsTest
    static void disablingAutomationAbortsJobsFromController() {
        Test.startTest();
        AmplemarketCreditController.saveAutomation(true, 60);
        AmplemarketCreditController.saveAutomation(false, 60);
        Test.stopTest();

        String prefix = AmplemarketEnrichRequestProcessor.JOB_NAME + '%';
        System.assertEquals(0, [
            SELECT COUNT() FROM CronTrigger WHERE CronJobDetail.Name LIKE :prefix]);
        AmplemarketCreditController.AutomationData a = AmplemarketCreditController.getAutomation();
        System.assertEquals(false, a.enabled);
        System.assertEquals(null, a.nextRun);
    }

    @IsTest
    static void runAutomationNowReportsQueueState() {
        Test.startTest();
        String empty = AmplemarketCreditController.runAutomationNow();
        Test.stopTest();
        System.assert(empty.contains('No pending'), empty);
    }

    @IsTest
    static void eligibleUsersReturnsList() {
        List<AmplemarketCreditController.UserOption> opts = AmplemarketCreditController.getEligibleUsers();
        System.assert(opts != null);
        System.assert(!opts.isEmpty(), 'Fallback should return at least the current active user');
    }
}
