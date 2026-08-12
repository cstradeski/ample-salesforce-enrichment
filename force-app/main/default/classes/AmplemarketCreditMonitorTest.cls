@IsTest
private class AmplemarketCreditMonitorTest {

    private static Enrichment_Log__c logRow(String obj, Decimal ps, Decimal cs, Decimal er, Decimal pr, Datetime ts) {
        return new Enrichment_Log__c(
            Record_Id__c = UserInfo.getUserId(),
            Object_API_Name__c = obj, Status__c = 'Success', Run_Timestamp__c = ts,
            Person_Search_Credits__c = ps, Company_Search_Credits__c = cs,
            Email_Reveal_Credits__c = er, Phone_Reveal_Credits__c = pr);
    }

    private static Amplemarket_Credit_Config__c config(Boolean enforce, String notifyUserId,
            Decimal personLimit, Decimal companyLimit, Decimal emailLimit, Decimal phoneLimit) {
        Amplemarket_Credit_Config__c cfg = new Amplemarket_Credit_Config__c(
            SetupOwnerId = UserInfo.getOrganizationId(),
            Enforce_Limits__c = enforce,
            Notify_User_Id__c = notifyUserId,
            Person_Search_Limit__c = personLimit,
            Company_Search_Limit__c = companyLimit,
            Email_Reveal_Limit__c = emailLimit,
            Phone_Reveal_Limit__c = phoneLimit);
        insert cfg;
        return cfg;
    }

    @IsTest
    static void weekStartIsMonday() {
        Date ws = AmplemarketCreditMonitor.weekStartDate();
        String dow = Datetime.newInstance(ws, Time.newInstance(0, 0, 0, 0)).format('u');
        System.assertEquals('1', dow, 'Week start should be a Monday (ISO day 1)');
        System.assert(ws <= Date.today(), 'Week start should be on or before today');
    }

    @IsTest
    static void currentWeekUsageSumsInWindowOnly() {
        insert new List<Enrichment_Log__c>{
            logRow('Lead', 0.5, 0, 1, 1, Datetime.now()),
            logRow('Account', 0, 0.5, 0, 0, Datetime.now()),
            // Out of window (last week) — must be excluded.
            logRow('Lead', 99, 99, 99, 99, AmplemarketCreditMonitor.weekStartDatetime().addDays(-1))
        };

        AmplemarketCreditMonitor.Usage u = AmplemarketCreditMonitor.currentWeekUsage();
        System.assertEquals(0.5, u.personSearch);
        System.assertEquals(0.5, u.companySearch);
        System.assertEquals(1, u.emailReveal);
        System.assertEquals(1, u.phoneReveal);
    }

    @IsTest
    static void enforcementOffNeverBlocks() {
        config(false, null, 1, 1, 1, 1);
        insert logRow('Lead', 5, 0, 5, 5, Datetime.now()); // way over
        AmplemarketCreditMonitor.Decision d =
            AmplemarketCreditMonitor.preCheck('Lead', true, true);
        System.assertEquals(false, d.blocked);
        System.assertEquals(true, d.revealEmail);
        System.assertEquals(true, d.revealPhone);
    }

    @IsTest
    static void enforcementBlocksSearchOverLimit() {
        config(true, null, 1, 1, null, null);
        insert logRow('Lead', 1, 0, 0, 0, Datetime.now());
        AmplemarketCreditMonitor.Decision d =
            AmplemarketCreditMonitor.preCheck('Lead', true, true);
        System.assertEquals(true, d.blocked);
        System.assertEquals('Person Search', d.blockedReason);
    }

    @IsTest
    static void enforcementSuppressesRevealButAllowsSearch() {
        // Email reveal over limit; person search under (no limit) -> search runs, email suppressed.
        config(true, null, null, null, 1, 5);
        insert logRow('Lead', 0, 0, 1, 0, Datetime.now());
        AmplemarketCreditMonitor.Decision d =
            AmplemarketCreditMonitor.preCheck('Lead', true, true);
        System.assertEquals(false, d.blocked);
        System.assertEquals(false, d.revealEmail, 'email reveal over limit should be suppressed');
        System.assertEquals(true, d.revealPhone, 'phone reveal under limit should remain');
    }

    @IsTest
    static void enforcementBlocksCompanyOverLimit() {
        config(true, null, null, 1, null, null);
        insert logRow('Account', 0, 1, 0, 0, Datetime.now());
        AmplemarketCreditMonitor.Decision d =
            AmplemarketCreditMonitor.preCheck('Account', false, false);
        System.assertEquals(true, d.blocked);
        System.assertEquals('Company Search', d.blockedReason);
    }

    @IsTest
    static void recordAndNotifyStampsOncePerWeek() {
        config(false, UserInfo.getUserId(), 1, null, null, null);
        insert logRow('Lead', 1, 0, 0, 0, Datetime.now());

        Test.startTest();
        AmplemarketCreditMonitor.recordAndNotify();
        Test.stopTest();

        Amplemarket_Credit_Config__c after = [
            SELECT Person_Search_Notified_Week__c FROM Amplemarket_Credit_Config__c
            WHERE SetupOwnerId = :UserInfo.getOrganizationId() LIMIT 1];
        System.assertEquals(AmplemarketCreditMonitor.weekStartDate(), after.Person_Search_Notified_Week__c,
            'Person search should be stamped as notified for this week');

        // Second run: no exception, stamp unchanged (already notified this week).
        AmplemarketCreditMonitor.recordAndNotify();
        Amplemarket_Credit_Config__c again = [
            SELECT Person_Search_Notified_Week__c FROM Amplemarket_Credit_Config__c
            WHERE SetupOwnerId = :UserInfo.getOrganizationId() LIMIT 1];
        System.assertEquals(after.Person_Search_Notified_Week__c, again.Person_Search_Notified_Week__c);
    }

    @IsTest
    static void periodRollsForwardWhenTermHasEnded() {
        // A one-year term that ended last year should advance to cover today.
        Amplemarket_Credit_Config__c cfg = new Amplemarket_Credit_Config__c(
            SetupOwnerId = UserInfo.getOrganizationId(),
            Contract_Start_Date__c = Date.today().addYears(-2),
            Contract_End_Date__c = Date.today().addYears(-1).addDays(-1));
        insert cfg;

        AmplemarketCreditMonitor.ContractPeriod p =
            AmplemarketCreditMonitor.currentPeriod(AmplemarketCreditMonitor.configForUpdate());

        System.assertEquals(true, p.configured);
        System.assertEquals(true, p.rolled, 'Expired term should roll forward');
        System.assert(p.startDate <= Date.today(), 'Rolled period should start on or before today');
        System.assert(p.endDate >= Date.today(), 'Rolled period should end on or after today');
    }

    @IsTest
    static void ensureCurrentPeriodPersistsTheRoll() {
        insert new Amplemarket_Credit_Config__c(
            SetupOwnerId = UserInfo.getOrganizationId(),
            Contract_Start_Date__c = Date.today().addYears(-2),
            Contract_End_Date__c = Date.today().addYears(-1).addDays(-1));

        Test.startTest();
        AmplemarketCreditMonitor.ContractPeriod p = AmplemarketCreditMonitor.ensureCurrentPeriod();
        Test.stopTest();

        Amplemarket_Credit_Config__c after = [
            SELECT Contract_Start_Date__c, Contract_End_Date__c FROM Amplemarket_Credit_Config__c
            WHERE SetupOwnerId = :UserInfo.getOrganizationId() LIMIT 1];
        System.assertEquals(p.startDate, after.Contract_Start_Date__c, 'Roll should be persisted');
        System.assertEquals(p.endDate, after.Contract_End_Date__c);
    }

    @IsTest
    static void periodNotRolledWhileTermIsCurrent() {
        insert new Amplemarket_Credit_Config__c(
            SetupOwnerId = UserInfo.getOrganizationId(),
            Contract_Start_Date__c = Date.today().addDays(-10),
            Contract_End_Date__c = Date.today().addDays(300));

        AmplemarketCreditMonitor.ContractPeriod p =
            AmplemarketCreditMonitor.currentPeriod(AmplemarketCreditMonitor.configForUpdate());
        System.assertEquals(false, p.rolled);
        System.assertEquals(Date.today().addDays(-10), p.startDate);
    }

    @IsTest
    static void annualAllowanceBlocksEverythingWhenEnforced() {
        Amplemarket_Credit_Config__c cfg = new Amplemarket_Credit_Config__c(
            SetupOwnerId = UserInfo.getOrganizationId(),
            Enforce_Limits__c = true,
            Annual_Credit_Allowance__c = 5,
            Contract_Start_Date__c = Date.today().addDays(-5),
            Contract_End_Date__c = Date.today().addDays(300));
        insert cfg;
        insert new Enrichment_Log__c(Record_Id__c = UserInfo.getUserId(), Object_API_Name__c = 'Lead',
            Status__c = 'Success', Run_Timestamp__c = Datetime.now(),
            Person_Search_Credits__c = 5, Credits_Used__c = 5);

        // Both person and company enrichment are blocked by the shared annual pool.
        AmplemarketCreditMonitor.Decision person =
            AmplemarketCreditMonitor.preCheck('Lead', true, true);
        AmplemarketCreditMonitor.Decision company =
            AmplemarketCreditMonitor.preCheck('Account', false, false);

        System.assertEquals(true, person.blocked);
        System.assertEquals('Annual Contract', person.blockedReason);
        System.assertEquals(true, company.blocked);
        System.assertEquals('Annual Contract', company.blockedReason);
    }

    @IsTest
    static void annualAllowanceDoesNotBlockWhenEnforcementOff() {
        insert new Amplemarket_Credit_Config__c(
            SetupOwnerId = UserInfo.getOrganizationId(),
            Enforce_Limits__c = false,
            Annual_Credit_Allowance__c = 1,
            Contract_Start_Date__c = Date.today().addDays(-5),
            Contract_End_Date__c = Date.today().addDays(300));
        insert new Enrichment_Log__c(Record_Id__c = UserInfo.getUserId(), Object_API_Name__c = 'Lead',
            Status__c = 'Success', Run_Timestamp__c = Datetime.now(),
            Person_Search_Credits__c = 9, Credits_Used__c = 9);

        AmplemarketCreditMonitor.Decision d = AmplemarketCreditMonitor.preCheck('Lead', true, true);
        System.assertEquals(false, d.blocked);
    }

    @IsTest
    static void annualAlertStampsPeriodOnce() {
        Date start = Date.today().addDays(-5);
        insert new Amplemarket_Credit_Config__c(
            SetupOwnerId = UserInfo.getOrganizationId(),
            Notify_User_Id__c = UserInfo.getUserId(),
            Annual_Credit_Allowance__c = 2,
            Contract_Start_Date__c = start,
            Contract_End_Date__c = Date.today().addDays(300));
        insert new Enrichment_Log__c(Record_Id__c = UserInfo.getUserId(), Object_API_Name__c = 'Lead',
            Status__c = 'Success', Run_Timestamp__c = Datetime.now(),
            Person_Search_Credits__c = 3, Credits_Used__c = 3);

        Test.startTest();
        AmplemarketCreditMonitor.recordAndNotify();
        Test.stopTest();

        Amplemarket_Credit_Config__c after = [
            SELECT Annual_Notified_Period__c FROM Amplemarket_Credit_Config__c
            WHERE SetupOwnerId = :UserInfo.getOrganizationId() LIMIT 1];
        System.assertEquals(start, after.Annual_Notified_Period__c,
            'Annual alert should stamp the contract period start');
    }

    @IsTest
    static void recordAndNotifyNoOpWithoutNotifyUser() {
        config(false, null, 1, null, null, null);
        insert logRow('Lead', 5, 0, 0, 0, Datetime.now());
        AmplemarketCreditMonitor.recordAndNotify();
        Amplemarket_Credit_Config__c after = [
            SELECT Person_Search_Notified_Week__c FROM Amplemarket_Credit_Config__c
            WHERE SetupOwnerId = :UserInfo.getOrganizationId() LIMIT 1];
        System.assertEquals(null, after.Person_Search_Notified_Week__c, 'No notify user -> no alert, no stamp');
    }
}
