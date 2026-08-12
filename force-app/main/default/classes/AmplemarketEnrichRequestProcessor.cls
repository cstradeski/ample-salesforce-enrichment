/**
 * Drains queued Enrichment_Request__c rows on a schedule.
 *
 * Scheduled Apex runs as the user who scheduled it, so whoever enables automated
 * enrichment on the Amplemarket Settings tab becomes the effective integration user
 * and their External Credential access is what the callouts use. That is what lets an
 * automated flow enrich records even when the user who triggered it holds no
 * Amplemarket permissions — and it needs no Tooling API or platform event subscriber
 * configuration.
 */
global without sharing class AmplemarketEnrichRequestProcessor implements Schedulable {

    public static final String JOB_NAME = 'Amplemarket Automated Enrichment';
    /** Requests claimed per run. Each chained queueable handles 20 records. */
    public static final Integer MAX_PER_RUN = 200;
    public static final Set<Integer> ALLOWED_INTERVALS = new Set<Integer>{ 5, 10, 15, 20, 30, 60 };

    global void execute(SchedulableContext ctx) {
        run();
    }

    /** Claims pending requests and hands them to the callout queueable. */
    public static Integer run() {
        List<Enrichment_Request__c> pending = [
            SELECT Id, Record_Id__c, Object_API_Name__c, Reveal_Email__c, Reveal_Phone__c
            FROM Enrichment_Request__c
            WHERE Status__c = 'Pending'
            ORDER BY CreatedDate ASC
            LIMIT :MAX_PER_RUN];
        if (pending.isEmpty()) return 0;

        // Claim them first so an overlapping run cannot pick up the same rows.
        List<Enrichment_Request__c> claims = new List<Enrichment_Request__c>();
        for (Enrichment_Request__c r : pending) {
            claims.add(new Enrichment_Request__c(Id = r.Id, Status__c = 'Processing'));
        }
        update claims;

        List<AmplemarketAsyncEnrichQueueable.EnrichGroup> groups =
            AmplemarketAsyncEnrichQueueable.groupRequests(pending);
        if (!groups.isEmpty()) {
            System.enqueueJob(new AmplemarketAsyncEnrichQueueable(groups));
        }
        return pending.size();
    }

    // ---- Scheduling ---------------------------------------------------------

    /**
     * Cron expressions covering every `interval` minutes. Apex requires the minute
     * field to be a single integer (a comma list is rejected at schedule time), so a
     * sub-hourly cadence means one job per offset: 15 minutes -> minute 0, 15, 30, 45.
     */
    @TestVisible
    private static List<String> buildCrons(Integer interval) {
        Integer step = (interval == null || !ALLOWED_INTERVALS.contains(interval)) ? 15 : interval;
        List<String> crons = new List<String>();
        for (Integer m = 0; m < 60; m += step) {
            crons.add('0 ' + m + ' * * * ?');
        }
        return crons;
    }

    @TestVisible
    private static String jobNameFor(String cron) {
        // Minute is the second token, and is unique per job in a given schedule.
        return JOB_NAME + ' ' + cron.split(' ')[1];
    }

    /** Aborts existing jobs, then schedules a fresh set when automation is enabled. */
    public static Integer reschedule(Amplemarket_Credit_Config__c cfg) {
        abortExisting();
        if (cfg == null || cfg.Auto_Enrichment_Enabled__c != true) return 0;
        Integer interval = cfg.Auto_Enrichment_Interval__c == null
            ? 15 : Integer.valueOf(cfg.Auto_Enrichment_Interval__c);
        List<String> crons = buildCrons(interval);
        for (String cron : crons) {
            System.schedule(jobNameFor(cron), cron, new AmplemarketEnrichRequestProcessor());
        }
        return crons.size();
    }

    public static void abortExisting() {
        String prefix = JOB_NAME + '%';
        for (CronTrigger ct : [
            SELECT Id FROM CronTrigger WHERE CronJobDetail.Name LIKE :prefix]) {
            try {
                System.abortJob(ct.Id);
            } catch (Exception e) {
                System.debug(LoggingLevel.WARN, 'Could not abort automation job: ' + e.getMessage());
            }
        }
    }

    /** Soonest upcoming run across the scheduled set. */
    public static Datetime nextRunTime() {
        String prefix = JOB_NAME + '%';
        List<CronTrigger> cts = [
            SELECT NextFireTime FROM CronTrigger
            WHERE CronJobDetail.Name LIKE :prefix AND NextFireTime != NULL
            ORDER BY NextFireTime ASC LIMIT 1];
        return cts.isEmpty() ? null : cts[0].NextFireTime;
    }

    /** Count of requests still waiting, for the settings UI. */
    public static Integer pendingCount() {
        return [SELECT COUNT() FROM Enrichment_Request__c WHERE Status__c IN ('Pending', 'Processing')];
    }
}
