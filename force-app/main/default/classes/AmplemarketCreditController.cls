/**
 * LWC controller for the Amplemarket Credit Tracking tab. Surfaces weekly + all-time
 * consumption per category, and reads/writes the Amplemarket_Credit_Config__c settings.
 */
public with sharing class AmplemarketCreditController {

    public class CategoryRow {
        @AuraEnabled public String key;
        @AuraEnabled public String label;
        @AuraEnabled public Decimal weeklyUsed;
        @AuraEnabled public Decimal weeklyLimit;
        @AuraEnabled public Decimal allTimeUsed;
    }

    public class DashboardData {
        @AuraEnabled public List<CategoryRow> categories = new List<CategoryRow>();
        @AuraEnabled public Boolean enforceLimits = false;
        @AuraEnabled public String notifyUserId;
        @AuraEnabled public String weekStart;
        // Annual contract pool
        @AuraEnabled public Boolean contractConfigured = false;
        @AuraEnabled public Decimal annualAllowance;
        @AuraEnabled public Decimal annualUsed = 0;
        @AuraEnabled public String contractStart;
        @AuraEnabled public String contractEnd;
        // Weekly digest
        @AuraEnabled public Boolean digestEnabled = false;
        @AuraEnabled public String digestRecipients;
        @AuraEnabled public String digestDayOfWeek;
        @AuraEnabled public Decimal digestHour;
        @AuraEnabled public Decimal digestMinute;
        @AuraEnabled public String digestNextRun;
        @AuraEnabled public String digestTimeZone;
    }

    /** Automated (permission-free) enrichment — surfaced on its own tab. */
    public class AutomationData {
        @AuraEnabled public Boolean enabled = false;
        @AuraEnabled public Decimal interval;
        @AuraEnabled public String runAsName;
        @AuraEnabled public Boolean runAsIsCurrentUser = false;
        @AuraEnabled public String nextRun;
        @AuraEnabled public Integer pending = 0;
        @AuraEnabled public Integer failed = 0;
        @AuraEnabled public String currentUserName;
    }

    public class UserOption {
        @AuraEnabled public String value;
        @AuraEnabled public String label;
        public UserOption(String value, String label) { this.value = value; this.label = label; }
    }

    @AuraEnabled(cacheable=false)
    public static DashboardData getDashboard() {
        // Rolls the contract period forward (and persists it) if the term has ended,
        // which is what resets annual consumption to zero for the new period.
        AmplemarketCreditMonitor.ContractPeriod period = AmplemarketCreditMonitor.ensureCurrentPeriod();

        Amplemarket_Credit_Config__c cfg = AmplemarketCreditMonitor.readConfig();
        AmplemarketCreditMonitor.Usage week = AmplemarketCreditMonitor.currentWeekUsage();
        AmplemarketCreditMonitor.Usage all = AmplemarketCreditMonitor.allTimeUsage();

        DashboardData d = new DashboardData();
        d.enforceLimits = cfg.Enforce_Limits__c == true;
        d.notifyUserId = cfg.Notify_User_Id__c;
        d.weekStart = String.valueOf(AmplemarketCreditMonitor.weekStartDate());
        d.annualAllowance = cfg.Annual_Credit_Allowance__c;
        d.contractConfigured = period.configured;
        d.digestEnabled = cfg.Digest_Enabled__c == true;
        d.digestRecipients = cfg.Digest_Recipients__c;
        d.digestDayOfWeek = String.isBlank(cfg.Digest_Day_Of_Week__c) ? 'MON' : cfg.Digest_Day_Of_Week__c;
        d.digestHour = cfg.Digest_Hour__c == null ? 8 : cfg.Digest_Hour__c;
        d.digestMinute = cfg.Digest_Minute__c == null ? 0 : cfg.Digest_Minute__c;
        d.digestTimeZone = UserInfo.getTimeZone().getID();
        Datetime nextRun = AmplemarketCreditDigest.nextRunTime();
        d.digestNextRun = nextRun == null ? null
            : nextRun.format('EEE d MMM yyyy, HH:mm', UserInfo.getTimeZone().getID());

        if (period.configured) {
            d.contractStart = String.valueOf(period.startDate);
            d.contractEnd = String.valueOf(period.endDate);
            d.annualUsed = AmplemarketCreditMonitor.periodTotalUsed(period);
        }
        d.categories.add(row('personSearch', 'Person Search',
            week.personSearch, cfg.Person_Search_Limit__c, all.personSearch));
        d.categories.add(row('companySearch', 'Company Search',
            week.companySearch, cfg.Company_Search_Limit__c, all.companySearch));
        d.categories.add(row('emailReveal', 'Email Reveals',
            week.emailReveal, cfg.Email_Reveal_Limit__c, all.emailReveal));
        d.categories.add(row('phoneReveal', 'Phone Reveals',
            week.phoneReveal, cfg.Phone_Reveal_Limit__c, all.phoneReveal));
        return d;
    }

    // ---- Automated enrichment (its own tab) ---------------------------------

    @AuraEnabled(cacheable=false)
    public static AutomationData getAutomation() {
        Amplemarket_Credit_Config__c cfg = AmplemarketCreditMonitor.readConfig();
        AutomationData a = new AutomationData();
        a.enabled = cfg.Auto_Enrichment_Enabled__c == true;
        a.interval = cfg.Auto_Enrichment_Interval__c == null ? 15 : cfg.Auto_Enrichment_Interval__c;
        a.pending = AmplemarketEnrichRequestProcessor.pendingCount();
        a.failed = [SELECT COUNT() FROM Enrichment_Request__c WHERE Status__c = 'Failed'];
        a.currentUserName = UserInfo.getName();

        Datetime next = AmplemarketEnrichRequestProcessor.nextRunTime();
        a.nextRun = next == null ? null
            : next.format('EEE d MMM yyyy, HH:mm', UserInfo.getTimeZone().getID());

        if (String.isNotBlank(cfg.Auto_Enrichment_Run_As__c)) {
            a.runAsIsCurrentUser = cfg.Auto_Enrichment_Run_As__c == UserInfo.getUserId();
            List<User> runAs = [SELECT Name FROM User WHERE Id = :cfg.Auto_Enrichment_Run_As__c LIMIT 1];
            a.runAsName = runAs.isEmpty() ? 'Unknown user' : runAs[0].Name;
        }
        return a;
    }

    /**
     * Saves the automation settings and (re)schedules the drain job. Scheduled Apex
     * runs as whoever schedules it, so the saving user becomes the effective
     * integration user for every automated callout.
     */
    @AuraEnabled
    public static void saveAutomation(Boolean enabled, Decimal interval) {
        if (!Schema.SObjectType.Amplemarket_Credit_Config__c.isCreateable()) {
            throw new AuraHandledException('You do not have access to edit Amplemarket settings.');
        }
        Amplemarket_Credit_Config__c cfg = AmplemarketCreditMonitor.configForUpdate();
        cfg.Auto_Enrichment_Enabled__c = enabled == true;
        cfg.Auto_Enrichment_Interval__c = interval == null ? 15 : interval;
        if (enabled == true) {
            cfg.Auto_Enrichment_Run_As__c = UserInfo.getUserId();
        }
        try {
            upsert cfg;
        } catch (DmlException e) {
            throw new AuraHandledException('Could not save settings: ' + e.getDmlMessage(0));
        }
        try {
            AmplemarketEnrichRequestProcessor.reschedule(cfg);
        } catch (Exception e) {
            throw new AuraHandledException(
                'Settings saved, but the schedule could not be updated: ' + e.getMessage());
        }
    }

    private static CategoryRow row(String key, String label, Decimal weeklyUsed, Decimal weeklyLimit, Decimal allTimeUsed) {
        CategoryRow r = new CategoryRow();
        r.key = key;
        r.label = label;
        r.weeklyUsed = weeklyUsed == null ? 0 : weeklyUsed;
        r.weeklyLimit = weeklyLimit;
        r.allTimeUsed = allTimeUsed == null ? 0 : allTimeUsed;
        return r;
    }

    @AuraEnabled
    public static void saveConfig(Decimal personLimit, Decimal companyLimit,
            Decimal emailLimit, Decimal phoneLimit, Boolean enforceLimits, String notifyUserId,
            Decimal annualAllowance, String contractStart, String contractEnd,
            Boolean digestEnabled, String digestRecipients, String digestDayOfWeek,
            Decimal digestHour, Decimal digestMinute) {
        if (!Schema.SObjectType.Amplemarket_Credit_Config__c.isCreateable()) {
            throw new AuraHandledException('You do not have access to edit Amplemarket credit settings.');
        }
        Date startDate = parseDate(contractStart);
        Date endDate = parseDate(contractEnd);
        if (startDate != null && endDate != null && endDate < startDate) {
            throw new AuraHandledException('Contract end date must be on or after the start date.');
        }

        List<String> recipients = AmplemarketCreditDigest.parseRecipients(digestRecipients);
        for (String addr : recipients) {
            if (!AmplemarketCreditDigest.isValidEmail(addr)) {
                throw new AuraHandledException('Not a valid email address: ' + addr);
            }
        }
        if (digestEnabled == true && recipients.isEmpty()) {
            throw new AuraHandledException('Add at least one recipient email before enabling the weekly digest.');
        }

        Amplemarket_Credit_Config__c cfg = AmplemarketCreditMonitor.configForUpdate();
        cfg.Person_Search_Limit__c = personLimit;
        cfg.Company_Search_Limit__c = companyLimit;
        cfg.Email_Reveal_Limit__c = emailLimit;
        cfg.Phone_Reveal_Limit__c = phoneLimit;
        cfg.Enforce_Limits__c = enforceLimits == true;
        cfg.Notify_User_Id__c = String.isBlank(notifyUserId) ? null : notifyUserId;
        cfg.Annual_Credit_Allowance__c = annualAllowance;
        // Changing the contract dates starts a fresh period, so allow the annual alert again.
        if (cfg.Contract_Start_Date__c != startDate) cfg.Annual_Notified_Period__c = null;
        cfg.Contract_Start_Date__c = startDate;
        cfg.Contract_End_Date__c = endDate;
        cfg.Digest_Enabled__c = digestEnabled == true;
        cfg.Digest_Recipients__c = recipients.isEmpty() ? null : String.join(recipients, ', ');
        cfg.Digest_Day_Of_Week__c = String.isBlank(digestDayOfWeek) ? 'MON' : digestDayOfWeek.toUpperCase();
        cfg.Digest_Hour__c = digestHour;
        cfg.Digest_Minute__c = digestMinute;
        try {
            upsert cfg;
        } catch (DmlException e) {
            throw new AuraHandledException('Could not save settings: ' + e.getDmlMessage(0));
        }

        // Re-point the scheduled jobs (or cancel them when disabled).
        try {
            AmplemarketCreditDigest.reschedule(cfg);
        } catch (Exception e) {
            throw new AuraHandledException('Settings saved, but the digest schedule could not be updated: '
                + e.getMessage());
        }
    }

    /** Drains the queue immediately, so an admin can verify automation without waiting. */
    @AuraEnabled
    public static String runAutomationNow() {
        if (!Schema.SObjectType.Amplemarket_Credit_Config__c.isCreateable()) {
            throw new AuraHandledException('You do not have access to Amplemarket credit settings.');
        }
        Integer claimed = AmplemarketEnrichRequestProcessor.run();
        return claimed == 0
            ? 'No pending enrichment requests.'
            : 'Processing ' + claimed + ' queued request' + (claimed == 1 ? '' : 's') + '.';
    }

    /**
     * Sends the weekly digest immediately to the saved recipients so an admin can
     * confirm delivery. Explicitly invoked from the Credit Tracking tab.
     */
    @AuraEnabled
    public static String sendDigestNow() {
        if (!Schema.SObjectType.Amplemarket_Credit_Config__c.isCreateable()) {
            throw new AuraHandledException('You do not have access to Amplemarket credit settings.');
        }
        return AmplemarketCreditDigest.send();
    }

    private static Date parseDate(String s) {
        if (String.isBlank(s)) return null;
        try {
            return Date.valueOf(s); // LWC date inputs send ISO yyyy-MM-dd
        } catch (Exception e) {
            throw new AuraHandledException('Invalid date: ' + s);
        }
    }

    @AuraEnabled(cacheable=true)
    public static List<UserOption> getEligibleUsers() {
        Set<Id> adminIds = new Set<Id>();
        for (PermissionSetAssignment psa : [
            SELECT AssigneeId FROM PermissionSetAssignment
            WHERE PermissionSet.Name = 'Amplemarket_Admin' AND Assignee.IsActive = true]) {
            adminIds.add(psa.AssigneeId);
        }
        List<UserOption> opts = new List<UserOption>();
        if (!adminIds.isEmpty()) {
            for (User u : [SELECT Id, Name FROM User WHERE Id IN :adminIds ORDER BY Name]) {
                opts.add(new UserOption(u.Id, u.Name));
            }
        } else {
            for (User u : [SELECT Id, Name FROM User WHERE IsActive = true ORDER BY Name LIMIT 200]) {
                opts.add(new UserOption(u.Id, u.Name));
            }
        }
        return opts;
    }
}
