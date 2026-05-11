public with sharing class AmplemarketBatchEnrichQueueable implements Queueable, Database.AllowsCallouts {

    private final String objectApiName;
    private final List<Id> recordIds;

    public AmplemarketBatchEnrichQueueable(String objectApiName, List<Id> recordIds) {
        this.objectApiName = objectApiName;
        this.recordIds = recordIds;
    }

    public void execute(QueueableContext ctx) {
        if (recordIds == null || recordIds.isEmpty()) return;

        // Run up to 20 records per transaction. enrichBatch keeps all callouts ahead of
        // all DML so we don't hit "uncommitted work pending" between iterations.
        Integer maxPerTransaction = 20;
        List<Id> chunk = new List<Id>();
        List<Id> remainder = new List<Id>();
        for (Integer i = 0; i < recordIds.size(); i++) {
            if (i < maxPerTransaction) chunk.add(recordIds[i]);
            else remainder.add(recordIds[i]);
        }

        try {
            AmplemarketEnrichmentService.enrichBatch(chunk, objectApiName);
        } catch (Exception e) {
            // Last-resort fallback: log a single batch-level failure for any record we
            // couldn't process. Per-record errors are already logged inside enrichBatch.
            for (Id recId : chunk) {
                try {
                    AmplemarketEnrichmentService.writeLog(
                        recId, objectApiName, null, 'Error',
                        null, null, 'Queueable failure: ' + e.getMessage(), null, Datetime.now()
                    );
                } catch (Exception ignore) { /* swallow */ }
            }
        }

        if (!remainder.isEmpty() && !Test.isRunningTest()) {
            System.enqueueJob(new AmplemarketBatchEnrichQueueable(objectApiName, remainder));
        }
    }
}
