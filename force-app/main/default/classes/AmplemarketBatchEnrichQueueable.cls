public with sharing class AmplemarketBatchEnrichQueueable implements Queueable, Database.AllowsCallouts {

    private final String objectApiName;
    private final List<Id> recordIds;

    public AmplemarketBatchEnrichQueueable(String objectApiName, List<Id> recordIds) {
        this.objectApiName = objectApiName;
        this.recordIds = recordIds;
    }

    public void execute(QueueableContext ctx) {
        if (recordIds == null || recordIds.isEmpty()) return;

        // For now run each record synchronously inside the queueable. With small batches
        // (< ~20) this stays under callout-per-transaction limits. For larger batches,
        // an admin can wire a chained queueable or a scheduled flow that calls the
        // invocable with smaller chunks.
        Integer maxPerTransaction = 20;
        List<Id> chunk = new List<Id>();
        List<Id> remainder = new List<Id>();
        for (Integer i = 0; i < recordIds.size(); i++) {
            if (i < maxPerTransaction) chunk.add(recordIds[i]);
            else remainder.add(recordIds[i]);
        }

        for (Id recId : chunk) {
            try {
                AmplemarketEnrichmentService.enrichSingle(recId, objectApiName);
            } catch (Exception e) {
                // Service writes its own error logs; this is a final safety net.
                AmplemarketEnrichmentService.writeLog(
                    recId, objectApiName, null, 'Error',
                    null, null, 'Queueable failure: ' + e.getMessage(), null, Datetime.now()
                );
            }
        }

        if (!remainder.isEmpty() && !Test.isRunningTest()) {
            System.enqueueJob(new AmplemarketBatchEnrichQueueable(objectApiName, remainder));
        }
    }
}
