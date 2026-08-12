/**
 * Weekly credit-limit enforcement and alerting for Amplemarket enrichment.
 *
 * Reads org-wide consumption from Enrichment_Log__c (public ReadWrite object, so
 * totals are org-wide) and the singleton Amplemarket_Credit_Config__c custom setting.
 * `without sharing` so budget checks always see the whole org's spend.
 *
 * - preCheck(): called before a callout. When Enforce Limits is on, blocks the call
 *   if the base search category is over its weekly limit, and suppresses an individual
 *   reveal that is over its limit (the search still runs).
 * - recordAndNotify(): called after logs are written. Sends an in-app + email alert to
 *   the configured user for each category over its weekly limit, at most once per week.
 */
public without sharing class AmplemarketCreditMonitor {

    private static final String NOTIF_TYPE = 'Amplemarket_Credit_Alert';

    public class Usage {
        public Decimal personSearch = 0;
        public Decimal companySearch = 0;
        public Decimal emailReveal = 0;
        public Decimal phoneReveal = 0;
        // Current contract period totals (all categories combined).
        public Boolean periodConfigured = false;
        public Decimal periodUsed = 0;
    }

    public class Decision {
        public Boolean blocked = false;
        public String blockedReason;
        public Boolean revealEmail;
        public Boolean revealPhone;
    }

    // ---- Config -------------------------------------------------------------

    public static Amplemarket_Credit_Config__c readConfig() {
        return Amplemarket_Credit_Config__c.getOrgDefaults();
    }

    public static Boolean enforcementActive(Amplemarket_Credit_Config__c cfg) {
        return cfg != null && cfg.Enforce_Limits__c == true;
    }

    private static Boolean anyLimitSet(Amplemarket_Credit_Config__c cfg) {
        return positive(cfg.Person_Search_Limit__c) || positive(cfg.Company_Search_Limit__c)
            || positive(cfg.Email_Reveal_Limit__c) || positive(cfg.Phone_Reveal_Limit__c)
            || positive(cfg.Annual_Credit_Allowance__c);
    }

    public static Amplemarket_Credit_Config__c configForUpdate() {
        List<Amplemarket_Credit_Config__c> rows = [
            SELECT Id, Enforce_Limits__c, Notify_User_Id__c,
                   Person_Search_Limit__c, Company_Search_Limit__c,
                   Email_Reveal_Limit__c, Phone_Reveal_Limit__c,
                   Person_Search_Notified_Week__c, Company_Search_Notified_Week__c,
                   Email_Reveal_Notified_Week__c, Phone_Reveal_Notified_Week__c,
                   Annual_Credit_Allowance__c, Contract_Start_Date__c,
                   Contract_End_Date__c, Annual_Notified_Period__c,
                   Digest_Enabled__c, Digest_Recipients__c, Digest_Day_Of_Week__c,
                   Digest_Hour__c, Digest_Minute__c
            FROM Amplemarket_Credit_Config__c
            WHERE SetupOwnerId = :UserInfo.getOrganizationId() LIMIT 1];
        if (!rows.isEmpty()) return rows[0];
        return new Amplemarket_Credit_Config__c(SetupOwnerId = UserInfo.getOrganizationId());
    }

    // ---- Week window --------------------------------------------------------

    public static Date weekStartDate() {
        Date today = Date.today();
        // 'u' = ISO day of week (1 = Monday ... 7 = Sunday) in the running user's timezone.
        Integer dow = Integer.valueOf(Datetime.newInstance(today, Time.newInstance(0, 0, 0, 0)).format('u'));
        return today.addDays(-(dow - 1));
    }

    public static Datetime weekStartDatetime() {
        return Datetime.newInstance(weekStartDate(), Time.newInstance(0, 0, 0, 0));
    }

    // ---- Contract period ----------------------------------------------------

    public class ContractPeriod {
        public Boolean configured = false;
        public Boolean rolled = false;
        public Date startDate;
        public Date endDate;
    }

    /**
     * The contract period covering today. If the stored end date has passed, the
     * period is advanced by its own length (preserving calendar alignment for whole-
     * month terms) until it covers today — that is what "resets" consumption to zero,
     * since usage is always counted within the current period. Pure: does not persist.
     */
    public static ContractPeriod currentPeriod(Amplemarket_Credit_Config__c cfg) {
        ContractPeriod p = new ContractPeriod();
        if (cfg == null || cfg.Contract_Start_Date__c == null || cfg.Contract_End_Date__c == null) return p;
        Date s = cfg.Contract_Start_Date__c;
        Date e = cfg.Contract_End_Date__c;
        if (e < s) return p; // misconfigured — treat as no contract period
        p.configured = true;

        Date today = Date.today();
        Integer guard = 0;
        while (today > e && guard < 200) {
            Integer months = s.monthsBetween(e.addDays(1));
            Date ns = e.addDays(1);
            Date ne = months >= 1 ? ns.addMonths(months).addDays(-1) : ns.addDays(s.daysBetween(e));
            s = ns;
            e = ne;
            p.rolled = true;
            guard++;
        }
        p.startDate = s;
        p.endDate = e;
        return p;
    }

    /** As currentPeriod, but persists a roll-forward so the stored dates stay current. */
    public static ContractPeriod ensureCurrentPeriod() {
        Amplemarket_Credit_Config__c cfg = configForUpdate();
        ContractPeriod p = currentPeriod(cfg);
        if (p.rolled) {
            try {
                cfg.Contract_Start_Date__c = p.startDate;
                cfg.Contract_End_Date__c = p.endDate;
                upsert cfg;
            } catch (Exception e) {
                System.debug(LoggingLevel.WARN, 'Amplemarket contract roll failed: ' + e.getMessage());
            }
        }
        return p;
    }

    /** Total credits consumed inside the given contract period (all categories). */
    public static Decimal periodTotalUsed(ContractPeriod p) {
        if (p == null || !p.configured) return 0;
        Datetime fromDt = Datetime.newInstance(p.startDate, Time.newInstance(0, 0, 0, 0));
        Datetime toDt = Datetime.newInstance(p.endDate.addDays(1), Time.newInstance(0, 0, 0, 0));
        for (AggregateResult ar : [
            SELECT SUM(Credits_Used__c) t FROM Enrichment_Log__c
            WHERE Run_Timestamp__c >= :fromDt AND Run_Timestamp__c < :toDt]) {
            return nvl((Decimal) ar.get('t'));
        }
        return 0;
    }

    // ---- Usage --------------------------------------------------------------

    /**
     * Weekly per-category usage plus current-contract-period totals, computed once so
     * a batch can reuse it across records without re-querying.
     */
    public static Usage snapshot(Amplemarket_Credit_Config__c cfg) {
        Usage u = currentWeekUsage();
        ContractPeriod p = currentPeriod(cfg);
        u.periodConfigured = p.configured;
        u.periodUsed = p.configured ? periodTotalUsed(p) : 0;
        return u;
    }

    public static Usage currentWeekUsage() {
        return usageSince(weekStartDatetime());
    }

    public static Usage allTimeUsage() {
        return usageSince(null);
    }

    /** Per-category usage in the half-open window [fromDt, toDt). */
    public static Usage usageBetween(Datetime fromDt, Datetime toDt) {
        Usage u = new Usage();
        for (AggregateResult ar : [
            SELECT SUM(Person_Search_Credits__c) ps, SUM(Company_Search_Credits__c) cs,
                   SUM(Email_Reveal_Credits__c) er, SUM(Phone_Reveal_Credits__c) pr
            FROM Enrichment_Log__c
            WHERE Run_Timestamp__c >= :fromDt AND Run_Timestamp__c < :toDt]) {
            u.personSearch = nvl((Decimal) ar.get('ps'));
            u.companySearch = nvl((Decimal) ar.get('cs'));
            u.emailReveal = nvl((Decimal) ar.get('er'));
            u.phoneReveal = nvl((Decimal) ar.get('pr'));
        }
        return u;
    }

    private static Usage usageSince(Datetime since) {
        Usage u = new Usage();
        String soql = 'SELECT SUM(Person_Search_Credits__c) ps, SUM(Company_Search_Credits__c) cs, '
            + 'SUM(Email_Reveal_Credits__c) er, SUM(Phone_Reveal_Credits__c) pr FROM Enrichment_Log__c';
        if (since != null) soql += ' WHERE Run_Timestamp__c >= :since';
        for (AggregateResult ar : Database.query(soql)) {
            u.personSearch = nvl((Decimal) ar.get('ps'));
            u.companySearch = nvl((Decimal) ar.get('cs'));
            u.emailReveal = nvl((Decimal) ar.get('er'));
            u.phoneReveal = nvl((Decimal) ar.get('pr'));
        }
        return u;
    }

    // ---- Enforcement --------------------------------------------------------

    public static Decision preCheck(String objApi, Boolean wantEmail, Boolean wantPhone) {
        Amplemarket_Credit_Config__c cfg = readConfig();
        Usage usage = enforcementActive(cfg) ? snapshot(cfg) : null;
        return preCheck(objApi, wantEmail, wantPhone, usage, cfg);
    }

    public static Decision preCheck(String objApi, Boolean wantEmail, Boolean wantPhone,
            Usage usage, Amplemarket_Credit_Config__c cfg) {
        Decision d = new Decision();
        d.revealEmail = wantEmail;
        d.revealPhone = wantPhone;
        if (usage == null || !enforcementActive(cfg)) return d; // enforcement off

        // The annual contract pool gates every category — nothing runs once it's spent.
        if (usage.periodConfigured && over(usage.periodUsed, cfg.Annual_Credit_Allowance__c)) {
            d.blocked = true; d.blockedReason = 'Annual Contract'; return d;
        }

        if (AmplemarketDTO.isPersonObject(objApi)) {
            if (over(usage.personSearch, cfg.Person_Search_Limit__c)) {
                d.blocked = true; d.blockedReason = 'Person Search'; return d;
            }
            if (wantEmail && over(usage.emailReveal, cfg.Email_Reveal_Limit__c)) d.revealEmail = false;
            if (wantPhone && over(usage.phoneReveal, cfg.Phone_Reveal_Limit__c)) d.revealPhone = false;
        } else if (AmplemarketDTO.isCompanyObject(objApi)) {
            if (over(usage.companySearch, cfg.Company_Search_Limit__c)) {
                d.blocked = true; d.blockedReason = 'Company Search'; return d;
            }
        }
        return d;
    }

    // ---- Alerting -----------------------------------------------------------

    public static void recordAndNotify() {
        try {
            Amplemarket_Credit_Config__c cfg = configForUpdate();

            // Keep the stored contract dates current even if no alerting is configured.
            ContractPeriod period = currentPeriod(cfg);
            if (period.rolled) {
                cfg.Contract_Start_Date__c = period.startDate;
                cfg.Contract_End_Date__c = period.endDate;
                upsert cfg;
            }

            if (String.isBlank(cfg.Notify_User_Id__c) || !anyLimitSet(cfg)) return;

            Usage u = currentWeekUsage();
            Date wk = weekStartDate();
            List<String> lines = new List<String>();

            if (period.configured && positive(cfg.Annual_Credit_Allowance__c)
                    && cfg.Annual_Notified_Period__c != period.startDate) {
                Decimal periodUsed = periodTotalUsed(period);
                if (periodUsed >= cfg.Annual_Credit_Allowance__c) {
                    lines.add('Annual contract allowance: ' + periodUsed + ' of '
                        + cfg.Annual_Credit_Allowance__c + ' credits used (period '
                        + String.valueOf(period.startDate) + ' to ' + String.valueOf(period.endDate) + ')');
                    cfg.Annual_Notified_Period__c = period.startDate;
                }
            }

            if (over(u.personSearch, cfg.Person_Search_Limit__c) && cfg.Person_Search_Notified_Week__c != wk) {
                lines.add(line('Person Search', u.personSearch, cfg.Person_Search_Limit__c));
                cfg.Person_Search_Notified_Week__c = wk;
            }
            if (over(u.companySearch, cfg.Company_Search_Limit__c) && cfg.Company_Search_Notified_Week__c != wk) {
                lines.add(line('Company Search', u.companySearch, cfg.Company_Search_Limit__c));
                cfg.Company_Search_Notified_Week__c = wk;
            }
            if (over(u.emailReveal, cfg.Email_Reveal_Limit__c) && cfg.Email_Reveal_Notified_Week__c != wk) {
                lines.add(line('Email Reveals', u.emailReveal, cfg.Email_Reveal_Limit__c));
                cfg.Email_Reveal_Notified_Week__c = wk;
            }
            if (over(u.phoneReveal, cfg.Phone_Reveal_Limit__c) && cfg.Phone_Reveal_Notified_Week__c != wk) {
                lines.add(line('Phone Reveals', u.phoneReveal, cfg.Phone_Reveal_Limit__c));
                cfg.Phone_Reveal_Notified_Week__c = wk;
            }

            if (lines.isEmpty()) return;

            String body = 'The following Amplemarket weekly credit limits were reached (week of '
                + String.valueOf(wk) + '):\n\n• ' + String.join(lines, '\n• ');
            sendInApp(cfg.Notify_User_Id__c, body);
            sendEmail(cfg.Notify_User_Id__c, body);
            upsert cfg; // persist notified-week stamps so we alert at most once per week
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN, 'Amplemarket credit alert failed: ' + e.getMessage());
        }
    }

    private static void sendInApp(String userId, String body) {
        try {
            List<CustomNotificationType> types = [
                SELECT Id FROM CustomNotificationType WHERE DeveloperName = :NOTIF_TYPE LIMIT 1];
            if (types.isEmpty()) return;
            Messaging.CustomNotification n = new Messaging.CustomNotification();
            n.setNotificationTypeId(types[0].Id);
            n.setTitle('Amplemarket credit limit reached');
            n.setBody(body);
            n.setTargetId(userId);
            n.send(new Set<String>{ userId });
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN, 'Amplemarket in-app alert failed: ' + e.getMessage());
        }
    }

    private static void sendEmail(String userId, String body) {
        try {
            List<User> users = [SELECT Email FROM User WHERE Id = :userId AND IsActive = true LIMIT 1];
            if (users.isEmpty() || String.isBlank(users[0].Email)) return;
            Messaging.SingleEmailMessage m = new Messaging.SingleEmailMessage();
            m.setToAddresses(new List<String>{ users[0].Email });
            m.setSubject('Amplemarket credit limit reached');
            m.setPlainTextBody(body);
            // No setSaveAsActivity here — it is only valid alongside setTargetObjectId
            // and otherwise throws, which this try/catch would silently swallow.
            Messaging.sendEmail(new List<Messaging.SingleEmailMessage>{ m });
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN, 'Amplemarket email alert failed: ' + e.getMessage());
        }
    }

    // ---- Helpers ------------------------------------------------------------

    private static Boolean over(Decimal used, Decimal limitValue) {
        return positive(limitValue) && nvl(used) >= limitValue;
    }

    private static Boolean positive(Decimal d) {
        return d != null && d > 0;
    }

    private static Decimal nvl(Decimal d) {
        return d == null ? 0 : d;
    }

    private static String line(String label, Decimal used, Decimal limitValue) {
        return label + ': ' + used + ' of ' + limitValue + ' credits used';
    }
}
