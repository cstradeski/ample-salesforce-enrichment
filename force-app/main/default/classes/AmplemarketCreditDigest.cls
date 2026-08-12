/**
 * Weekly credit-usage digest, emailed to arbitrary addresses on a configurable
 * day and time. Implements Schedulable so it can be scheduled from the Credit
 * Tracking tab (or from Setup > Apex Classes > Schedule Apex as a fallback).
 *
 * The digest reports the PREVIOUS COMPLETED calendar week (Monday 00:00 through
 * the following Monday 00:00), so the figures are always a stable, finished week.
 *
 * Scheduled Apex runs in the timezone of the user who scheduled the job, so the
 * configured hour/minute are in that user's timezone.
 */
global without sharing class AmplemarketCreditDigest implements Schedulable {

    public static final String JOB_NAME = 'Amplemarket Weekly Credit Digest';

    private static final Map<String, Integer> DAY_TOKENS = new Map<String, Integer>{
        'SUN' => 1, 'MON' => 2, 'TUE' => 3, 'WED' => 4, 'THU' => 5, 'FRI' => 6, 'SAT' => 7
    };

    global void execute(SchedulableContext ctx) {
        send();
    }

    // ---- Sending ------------------------------------------------------------

    /** Builds and sends the digest to the configured recipients. Returns what happened. */
    public static String send() {
        Amplemarket_Credit_Config__c cfg = AmplemarketCreditMonitor.configForUpdate();
        List<String> to = parseRecipients(cfg.Digest_Recipients__c);
        if (to.isEmpty()) return 'No digest recipients configured.';
        return sendTo(to, cfg);
    }

    public static String sendTo(List<String> to, Amplemarket_Credit_Config__c cfg) {
        if (to == null || to.isEmpty()) return 'No digest recipients configured.';

        Date weekStart = AmplemarketCreditMonitor.weekStartDate().addDays(-7); // previous Monday
        Date weekEnd = weekStart.addDays(6);                                   // that Sunday
        Datetime fromDt = Datetime.newInstance(weekStart, Time.newInstance(0, 0, 0, 0));
        Datetime toDt = Datetime.newInstance(weekStart.addDays(7), Time.newInstance(0, 0, 0, 0));

        AmplemarketCreditMonitor.Usage u = AmplemarketCreditMonitor.usageBetween(fromDt, toDt);
        AmplemarketCreditMonitor.ContractPeriod period = AmplemarketCreditMonitor.currentPeriod(cfg);

        Messaging.SingleEmailMessage m = new Messaging.SingleEmailMessage();
        m.setToAddresses(to);
        m.setSubject('Amplemarket credit digest — week of ' + String.valueOf(weekStart));
        m.setHtmlBody(buildHtml(u, cfg, period, weekStart, weekEnd));
        m.setPlainTextBody(buildText(u, cfg, period, weekStart, weekEnd));

        try {
            Messaging.sendEmail(new List<Messaging.SingleEmailMessage>{ m });
            return 'Digest sent to ' + String.join(to, ', ') + '.';
        } catch (Exception e) {
            return 'Digest could not be sent: ' + e.getMessage();
        }
    }

    // ---- Content ------------------------------------------------------------

    private static Decimal weekTotal(AmplemarketCreditMonitor.Usage u) {
        return nvl(u.personSearch) + nvl(u.companySearch) + nvl(u.emailReveal) + nvl(u.phoneReveal);
    }

    @TestVisible
    private static String buildHtml(AmplemarketCreditMonitor.Usage u, Amplemarket_Credit_Config__c cfg,
            AmplemarketCreditMonitor.ContractPeriod period, Date weekStart, Date weekEnd) {
        String h = '<div style="font-family:Arial,Helvetica,sans-serif;font-size:14px;color:#16325c;">';
        h += '<h2 style="margin:0 0 4px;">Amplemarket credit digest</h2>';
        h += '<p style="margin:0 0 16px;color:#54698d;">Week of ' + String.valueOf(weekStart)
            + ' to ' + String.valueOf(weekEnd) + '</p>';

        h += '<table cellpadding="8" cellspacing="0" border="0" style="border-collapse:collapse;min-width:380px;">';
        h += '<tr style="background:#f4f6f9;"><th align="left">Category</th>'
            + '<th align="right">Credits used</th><th align="right">Weekly limit</th></tr>';
        h += htmlRow('Person Search', u.personSearch, cfg.Person_Search_Limit__c);
        h += htmlRow('Company Search', u.companySearch, cfg.Company_Search_Limit__c);
        h += htmlRow('Email Reveals', u.emailReveal, cfg.Email_Reveal_Limit__c);
        h += htmlRow('Phone Reveals', u.phoneReveal, cfg.Phone_Reveal_Limit__c);
        h += '<tr style="border-top:2px solid #d8dde6;"><td><strong>Total</strong></td>'
            + '<td align="right"><strong>' + weekTotal(u) + '</strong></td><td></td></tr>';
        h += '</table>';

        if (period.configured) {
            Decimal used = AmplemarketCreditMonitor.periodTotalUsed(period);
            h += '<h3 style="margin:20px 0 4px;">Annual contract</h3>';
            h += '<p style="margin:0;color:#54698d;">Period ' + String.valueOf(period.startDate)
                + ' to ' + String.valueOf(period.endDate) + '</p>';
            if (cfg.Annual_Credit_Allowance__c != null && cfg.Annual_Credit_Allowance__c > 0) {
                Decimal remaining = cfg.Annual_Credit_Allowance__c - used;
                h += '<p style="margin:4px 0 0;">Used <strong>' + used + '</strong> of <strong>'
                    + cfg.Annual_Credit_Allowance__c + '</strong> credits &mdash; <strong>'
                    + (remaining > 0 ? remaining : 0) + '</strong> remaining.</p>';
            } else {
                h += '<p style="margin:4px 0 0;">Used <strong>' + used + '</strong> credits this period '
                    + '(no allowance set).</p>';
            }
        }

        h += '<p style="margin:20px 0 0;font-size:12px;color:#54698d;">'
            + 'Sent by the Amplemarket Enrichment package. Manage this digest on the '
            + 'Amplemarket Credit Tracking tab.</p></div>';
        return h;
    }

    private static String htmlRow(String label, Decimal used, Decimal limitValue) {
        String limitText = (limitValue != null && limitValue > 0) ? String.valueOf(limitValue) : '—';
        Boolean over = limitValue != null && limitValue > 0 && nvl(used) >= limitValue;
        String style = over ? ' style="color:#ba0517;font-weight:bold;"' : '';
        return '<tr><td>' + label + '</td><td align="right"' + style + '>' + nvl(used)
            + '</td><td align="right">' + limitText + '</td></tr>';
    }

    @TestVisible
    private static String buildText(AmplemarketCreditMonitor.Usage u, Amplemarket_Credit_Config__c cfg,
            AmplemarketCreditMonitor.ContractPeriod period, Date weekStart, Date weekEnd) {
        String t = 'Amplemarket credit digest\n';
        t += 'Week of ' + String.valueOf(weekStart) + ' to ' + String.valueOf(weekEnd) + '\n\n';
        t += 'Person Search:  ' + nvl(u.personSearch) + '\n';
        t += 'Company Search: ' + nvl(u.companySearch) + '\n';
        t += 'Email Reveals:  ' + nvl(u.emailReveal) + '\n';
        t += 'Phone Reveals:  ' + nvl(u.phoneReveal) + '\n';
        t += 'Total:          ' + weekTotal(u) + '\n';
        if (period.configured) {
            Decimal used = AmplemarketCreditMonitor.periodTotalUsed(period);
            t += '\nAnnual contract (' + String.valueOf(period.startDate) + ' to '
                + String.valueOf(period.endDate) + '): ' + used;
            if (cfg.Annual_Credit_Allowance__c != null && cfg.Annual_Credit_Allowance__c > 0) {
                t += ' of ' + cfg.Annual_Credit_Allowance__c;
            }
            t += ' credits used.\n';
        }
        return t;
    }

    // ---- Scheduling ---------------------------------------------------------

    /** Cron for a weekly run, e.g. "0 30 8 ? * MON". */
    @TestVisible
    private static String buildCron(Amplemarket_Credit_Config__c cfg) {
        String day = normalizeDay(cfg.Digest_Day_Of_Week__c);
        Integer hour = cfg.Digest_Hour__c == null ? 8 : Math.min(23, Math.max(0, Integer.valueOf(cfg.Digest_Hour__c)));
        Integer minute = cfg.Digest_Minute__c == null ? 0 : Math.min(59, Math.max(0, Integer.valueOf(cfg.Digest_Minute__c)));
        return '0 ' + minute + ' ' + hour + ' ? * ' + day;
    }

    @TestVisible
    private static String normalizeDay(String raw) {
        if (String.isBlank(raw)) return 'MON';
        String d = raw.trim().toUpperCase();
        return DAY_TOKENS.containsKey(d) ? d : 'MON';
    }

    /** Aborts any existing digest job, then schedules a new one if the digest is enabled. */
    public static String reschedule(Amplemarket_Credit_Config__c cfg) {
        abortExisting();
        if (cfg == null || cfg.Digest_Enabled__c != true) return null;
        if (parseRecipients(cfg.Digest_Recipients__c).isEmpty()) {
            throw new AmplemarketDigestException('Add at least one digest recipient before enabling the weekly digest.');
        }
        String cron = buildCron(cfg);
        System.schedule(JOB_NAME, cron, new AmplemarketCreditDigest());
        return cron;
    }

    public static void abortExisting() {
        for (CronTrigger ct : [
            SELECT Id FROM CronTrigger WHERE CronJobDetail.Name = :JOB_NAME]) {
            try {
                System.abortJob(ct.Id);
            } catch (Exception e) {
                System.debug(LoggingLevel.WARN, 'Could not abort digest job: ' + e.getMessage());
            }
        }
    }

    /** Next scheduled fire time, or null when the digest is not scheduled. */
    public static Datetime nextRunTime() {
        List<CronTrigger> cts = [
            SELECT NextFireTime FROM CronTrigger
            WHERE CronJobDetail.Name = :JOB_NAME LIMIT 1];
        return cts.isEmpty() ? null : cts[0].NextFireTime;
    }

    // ---- Helpers ------------------------------------------------------------

    /** Splits a comma-separated list into trimmed, non-blank addresses. */
    public static List<String> parseRecipients(String raw) {
        List<String> out = new List<String>();
        if (String.isBlank(raw)) return out;
        for (String part : raw.split(',')) {
            String s = part.trim();
            if (String.isNotBlank(s)) out.add(s);
        }
        return out;
    }

    public static Boolean isValidEmail(String address) {
        if (String.isBlank(address)) return false;
        return Pattern.matches('^[^@\\s,]+@[^@\\s,\\.]+(\\.[^@\\s,\\.]+)+$', address.trim());
    }

    private static Decimal nvl(Decimal d) {
        return d == null ? 0 : d;
    }

    public class AmplemarketDigestException extends Exception {}
}
