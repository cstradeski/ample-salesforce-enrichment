/**
 * Performs enrichment for queued Enrichment_Request__c rows. Runs in whatever user
 * context enqueued it — the automated enrichment job schedules this as the admin who
 * enabled automation, which is how the triggering user avoids needing any Amplemarket
 * permissions.
 *
 * Processes ONE group (object + reveal-override combination) per execution and chains
 * the rest, because Apex allows only a single System.enqueueJob from an async context.
 */
public without sharing class AmplemarketAsyncEnrichQueueable implements Queueable, Database.AllowsCallouts {

    private static final Integer MAX_PER_TRANSACTION = 20;

    public class EnrichGroup {
        public String objectApiName;
        public List<Id> recordIds = new List<Id>();
        public List<Id> requestIds = new List<Id>(); // parallel to recordIds
        public Boolean revealEmail;
        public Boolean revealPhone;
        public EnrichGroup(String objectApiName, Boolean revealEmail, Boolean revealPhone) {
            this.objectApiName = objectApiName;
            this.revealEmail = revealEmail;
            this.revealPhone = revealPhone;
        }
    }

    private final List<EnrichGroup> groups;

    public AmplemarketAsyncEnrichQueueable(List<EnrichGroup> groups) {
        this.groups = groups;
    }

    public void execute(QueueableContext ctx) {
        if (groups == null || groups.isEmpty()) return;

        EnrichGroup g = groups[0];
        List<Id> chunkRecords = new List<Id>();
        List<Id> chunkRequests = new List<Id>();
        EnrichGroup leftover = new EnrichGroup(g.objectApiName, g.revealEmail, g.revealPhone);

        for (Integer i = 0; i < g.recordIds.size(); i++) {
            if (i < MAX_PER_TRANSACTION) {
                chunkRecords.add(g.recordIds[i]);
                if (i < g.requestIds.size()) chunkRequests.add(g.requestIds[i]);
            } else {
                leftover.recordIds.add(g.recordIds[i]);
                if (i < g.requestIds.size()) leftover.requestIds.add(g.requestIds[i]);
            }
        }

        String failure = null;
        try {
            AmplemarketEnrichmentService.enrichBatch(chunkRecords, g.objectApiName, g.revealEmail, g.revealPhone);
        } catch (Exception e) {
            // Per-record errors are already logged inside enrichBatch; this covers a
            // whole-transaction failure — most commonly the running user lacking the
            // External Credential principal.
            failure = e.getMessage();
            for (Id recId : chunkRecords) {
                try {
                    AmplemarketEnrichmentService.writeLog(
                        recId, g.objectApiName, null, 'Error', null, null,
                        'Automated enrichment failed: ' + failure, null, Datetime.now());
                } catch (Exception ignore) { /* swallow */ }
            }
        }

        closeRequests(chunkRequests, failure);

        List<EnrichGroup> rest = new List<EnrichGroup>();
        if (!leftover.recordIds.isEmpty()) rest.add(leftover);
        for (Integer i = 1; i < groups.size(); i++) rest.add(groups[i]);

        if (!rest.isEmpty() && !Test.isRunningTest()) {
            System.enqueueJob(new AmplemarketAsyncEnrichQueueable(rest));
        }
    }

    private static void closeRequests(List<Id> requestIds, String failure) {
        if (requestIds == null || requestIds.isEmpty()) return;
        List<Enrichment_Request__c> rows = new List<Enrichment_Request__c>();
        for (Id reqId : requestIds) {
            rows.add(new Enrichment_Request__c(
                Id = reqId,
                Status__c = failure == null ? 'Complete' : 'Failed',
                Error_Message__c = failure,
                Processed_At__c = Datetime.now()
            ));
        }
        try {
            update rows;
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN, 'Could not close enrichment requests: ' + e.getMessage());
        }
    }

    /** "true"/"false" from a queued request; blank means "use the settings default". */
    public static Boolean parseOverride(String raw) {
        if (String.isBlank(raw)) return null;
        return 'true'.equalsIgnoreCase(raw.trim());
    }

    /** Groups queued requests by object + reveal overrides so each group shares one batch. */
    public static List<EnrichGroup> groupRequests(List<Enrichment_Request__c> requests) {
        Map<String, EnrichGroup> byKey = new Map<String, EnrichGroup>();
        List<String> order = new List<String>();

        for (Enrichment_Request__c r : requests) {
            if (String.isBlank(r.Record_Id__c)) continue;
            Id recId;
            try {
                recId = Id.valueOf(r.Record_Id__c);
            } catch (Exception ex) {
                continue; // malformed id — nothing we can enrich
            }
            String objApi = String.isNotBlank(r.Object_API_Name__c)
                ? r.Object_API_Name__c
                : recId.getSObjectType().getDescribe().getName();
            Boolean re = parseOverride(r.Reveal_Email__c);
            Boolean rp = parseOverride(r.Reveal_Phone__c);

            String key = objApi + '|' + (re == null ? 'x' : String.valueOf(re))
                + '|' + (rp == null ? 'x' : String.valueOf(rp));
            if (!byKey.containsKey(key)) {
                byKey.put(key, new EnrichGroup(objApi, re, rp));
                order.add(key);
            }
            byKey.get(key).recordIds.add(recId);
            byKey.get(key).requestIds.add(r.Id);
        }

        List<EnrichGroup> out = new List<EnrichGroup>();
        for (String k : order) out.add(byKey.get(k));
        return out;
    }
}
