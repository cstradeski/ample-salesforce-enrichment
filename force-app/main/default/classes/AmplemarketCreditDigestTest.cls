@IsTest
private class AmplemarketCreditDigestTest {

    private static Amplemarket_Credit_Config__c cfg(String recipients, String day, Decimal hour, Decimal minute) {
        Amplemarket_Credit_Config__c c = new Amplemarket_Credit_Config__c(
            SetupOwnerId = UserInfo.getOrganizationId(),
            Digest_Enabled__c = true,
            Digest_Recipients__c = recipients,
            Digest_Day_Of_Week__c = day,
            Digest_Hour__c = hour,
            Digest_Minute__c = minute);
        insert c;
        return c;
    }

    private static Enrichment_Log__c logAt(Datetime ts, Decimal ps, Decimal er) {
        return new Enrichment_Log__c(
            Record_Id__c = UserInfo.getUserId(), Object_API_Name__c = 'Lead',
            Status__c = 'Success', Run_Timestamp__c = ts,
            Person_Search_Credits__c = ps, Email_Reveal_Credits__c = er,
            Credits_Used__c = (ps == null ? 0 : ps) + (er == null ? 0 : er));
    }

    @IsTest
    static void parseRecipientsTrimsAndDropsBlanks() {
        List<String> out = AmplemarketCreditDigest.parseRecipients(' a@b.com ,, c@d.com,  ');
        System.assertEquals(2, out.size());
        System.assertEquals('a@b.com', out[0]);
        System.assertEquals('c@d.com', out[1]);
        System.assertEquals(0, AmplemarketCreditDigest.parseRecipients(null).size());
        System.assertEquals(0, AmplemarketCreditDigest.parseRecipients('   ').size());
    }

    @IsTest
    static void emailValidation() {
        System.assertEquals(true, AmplemarketCreditDigest.isValidEmail('ops@example.com'));
        System.assertEquals(true, AmplemarketCreditDigest.isValidEmail('a.b+c@sub.example.co.uk'));
        System.assertEquals(false, AmplemarketCreditDigest.isValidEmail('not-an-email'));
        System.assertEquals(false, AmplemarketCreditDigest.isValidEmail('missing@domain'));
        System.assertEquals(false, AmplemarketCreditDigest.isValidEmail(''));
    }

    @IsTest
    static void cronIsBuiltFromDayAndTime() {
        Amplemarket_Credit_Config__c c = cfg('a@b.com', 'FRI', 17, 5);
        System.assertEquals('0 5 17 ? * FRI', AmplemarketCreditDigest.buildCron(c));

        // Defaults and clamping for missing / out-of-range values.
        Amplemarket_Credit_Config__c bare = new Amplemarket_Credit_Config__c();
        System.assertEquals('0 0 8 ? * MON', AmplemarketCreditDigest.buildCron(bare));

        Amplemarket_Credit_Config__c odd = new Amplemarket_Credit_Config__c(
            Digest_Day_Of_Week__c = 'nope', Digest_Hour__c = 99, Digest_Minute__c = -4);
        System.assertEquals('0 0 23 ? * MON', AmplemarketCreditDigest.buildCron(odd));
    }

    @IsTest
    static void normalizeDayAcceptsLowercaseAndFallsBack() {
        System.assertEquals('THU', AmplemarketCreditDigest.normalizeDay('thu'));
        System.assertEquals('SUN', AmplemarketCreditDigest.normalizeDay(' Sun '));
        System.assertEquals('MON', AmplemarketCreditDigest.normalizeDay('bogus'));
        System.assertEquals('MON', AmplemarketCreditDigest.normalizeDay(null));
    }

    @IsTest
    static void rescheduleCreatesAndReplacesTheJob() {
        Amplemarket_Credit_Config__c c = cfg('a@b.com', 'TUE', 9, 0);

        Test.startTest();
        AmplemarketCreditDigest.reschedule(c);
        System.assertEquals(1, [
            SELECT COUNT() FROM CronTrigger
            WHERE CronJobDetail.Name = :AmplemarketCreditDigest.JOB_NAME]);

        // Rescheduling replaces rather than duplicates.
        c.Digest_Day_Of_Week__c = 'THU';
        AmplemarketCreditDigest.reschedule(c);
        Test.stopTest();

        List<CronTrigger> jobs = [
            SELECT CronExpression FROM CronTrigger
            WHERE CronJobDetail.Name = :AmplemarketCreditDigest.JOB_NAME];
        System.assertEquals(1, jobs.size(), 'Should not accumulate duplicate jobs');
        System.assertEquals('0 0 9 ? * THU', jobs[0].CronExpression);
    }

    @IsTest
    static void rescheduleWhenDisabledAbortsTheJob() {
        Amplemarket_Credit_Config__c c = cfg('a@b.com', 'MON', 8, 0);
        Test.startTest();
        AmplemarketCreditDigest.reschedule(c);
        c.Digest_Enabled__c = false;
        AmplemarketCreditDigest.reschedule(c);
        Test.stopTest();
        System.assertEquals(0, [
            SELECT COUNT() FROM CronTrigger
            WHERE CronJobDetail.Name = :AmplemarketCreditDigest.JOB_NAME],
            'Disabling should leave no scheduled job');
    }

    @IsTest
    static void rescheduleRequiresRecipients() {
        Amplemarket_Credit_Config__c c = cfg(null, 'MON', 8, 0);
        Boolean threw = false;
        try {
            AmplemarketCreditDigest.reschedule(c);
        } catch (AmplemarketCreditDigest.AmplemarketDigestException e) {
            threw = true;
        }
        System.assertEquals(true, threw);
    }

    @IsTest
    static void digestReportsPreviousCompletedWeekOnly() {
        Amplemarket_Credit_Config__c c = cfg('ops@example.com', 'MON', 8, 0);
        Date thisMonday = AmplemarketCreditMonitor.weekStartDate();
        Datetime lastWeek = Datetime.newInstance(thisMonday.addDays(-3), Time.newInstance(12, 0, 0, 0));
        Datetime thisWeek = Datetime.newInstance(thisMonday, Time.newInstance(12, 0, 0, 0));

        insert new List<Enrichment_Log__c>{
            logAt(lastWeek, 4, 2),  // counts
            logAt(thisWeek, 7, 7)   // current week — must be excluded
        };

        Test.startTest();
        String result = AmplemarketCreditDigest.send();
        Test.stopTest();

        System.assert(result.contains('ops@example.com'), result);

        // Verify the numbers the digest body is built from.
        Datetime fromDt = Datetime.newInstance(thisMonday.addDays(-7), Time.newInstance(0, 0, 0, 0));
        Datetime toDt = Datetime.newInstance(thisMonday, Time.newInstance(0, 0, 0, 0));
        AmplemarketCreditMonitor.Usage u = AmplemarketCreditMonitor.usageBetween(fromDt, toDt);
        System.assertEquals(4, u.personSearch, 'Only the previous completed week should be counted');
        System.assertEquals(2, u.emailReveal);
    }

    @IsTest
    static void digestBodyIncludesCategoriesAndContract() {
        Amplemarket_Credit_Config__c c = cfg('ops@example.com', 'MON', 8, 0);
        c.Annual_Credit_Allowance__c = 100;
        c.Contract_Start_Date__c = Date.today().addDays(-10);
        c.Contract_End_Date__c = Date.today().addDays(300);
        c.Person_Search_Limit__c = 5;
        update c;

        AmplemarketCreditMonitor.Usage u = new AmplemarketCreditMonitor.Usage();
        u.personSearch = 6; // over the limit -> highlighted
        u.emailReveal = 1;
        AmplemarketCreditMonitor.ContractPeriod p = AmplemarketCreditMonitor.currentPeriod(c);

        String html = AmplemarketCreditDigest.buildHtml(u, c, p, Date.today().addDays(-7), Date.today().addDays(-1));
        String text = AmplemarketCreditDigest.buildText(u, c, p, Date.today().addDays(-7), Date.today().addDays(-1));

        System.assert(html.contains('Person Search'), html);
        System.assert(html.contains('Annual contract'), html);
        System.assert(html.contains('#ba0517'), 'Over-limit row should be highlighted');
        System.assert(text.contains('Person Search:  6'), text);
        System.assert(text.contains('Annual contract'), text);
    }

    @IsTest
    static void sendWithoutRecipientsIsANoOp() {
        cfg(null, 'MON', 8, 0);
        String msg = AmplemarketCreditDigest.send();
        System.assert(msg.contains('No digest recipients'), msg);
    }

    @IsTest
    static void schedulableExecuteRuns() {
        cfg('ops@example.com', 'MON', 8, 0);
        Test.startTest();
        new AmplemarketCreditDigest().execute(null);
        Test.stopTest();
        // Reaching here without exception is the assertion: the scheduled entry point works.
        System.assertEquals(1, [
            SELECT COUNT() FROM Amplemarket_Credit_Config__c
            WHERE SetupOwnerId = :UserInfo.getOrganizationId()]);
    }
}
