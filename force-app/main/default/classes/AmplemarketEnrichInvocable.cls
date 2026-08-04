global with sharing class AmplemarketEnrichInvocable {

    global class Request {
        @InvocableVariable(required=true label='Record Id')
        global Id recordId;
        @InvocableVariable(label='Object API Name (optional, derived from Id if blank)')
        global String objectApiName;
        @InvocableVariable(label='Reveal Email (override; leave blank to use settings default)')
        global Boolean revealEmail;
        @InvocableVariable(label='Reveal Phone Number (override; leave blank to use settings default)')
        global Boolean revealPhone;
    }

    global class Response {
        @InvocableVariable(label='Success')
        global Boolean success;
        @InvocableVariable(label='Message')
        global String message;
        @InvocableVariable(label='Enrichment Log Id')
        global Id logId;
        @InvocableVariable(label='Fields Applied')
        global Integer fieldsApplied;
        @InvocableVariable(label='Applied Fields HTML')
        global String appliedFieldsHtml;
        @InvocableVariable(label='Credits Used')
        global Decimal creditsUsed;
    }

    @InvocableMethod(
        label='Enrich with Amplemarket'
        description='Calls Amplemarket Data Enrichment and writes mapped fields back to the record. Single record uses sync /find; bulk dispatches an async batch.'
        callout=true
    )
    global static List<Response> enrich(List<Request> reqs) {
        List<Response> out = new List<Response>();
        if (reqs == null || reqs.isEmpty()) return out;

        if (reqs.size() == 1) {
            Request r = reqs[0];
            AmplemarketEnrichmentService.ServiceResult sr = AmplemarketEnrichmentService.enrichSingle(
                r.recordId, r.objectApiName, r.revealEmail, r.revealPhone);
            Response resp = new Response();
            resp.success = sr.success;
            resp.message = sr.message;
            resp.logId = sr.logId;
            resp.fieldsApplied = sr.fieldsApplied;
            resp.appliedFieldsHtml = sr.appliedFieldsHtml;
            resp.creditsUsed = sr.creditsUsed;
            out.add(resp);
            return out;
        }

        // Bulk path: group by object AND reveal override (records with different
        // overrides can't share a batch), dispatch async, return placeholders.
        Map<String, List<Id>> idsByKey = new Map<String, List<Id>>();
        Map<String, String> objByKey = new Map<String, String>();
        Map<String, Boolean> revealEmailByKey = new Map<String, Boolean>();
        Map<String, Boolean> revealPhoneByKey = new Map<String, Boolean>();
        for (Request r : reqs) {
            if (r.recordId == null) continue;
            String objApi = String.isNotBlank(r.objectApiName)
                ? r.objectApiName
                : r.recordId.getSObjectType().getDescribe().getName();
            // 'x' marks a null (unset) override so it groups apart from explicit true/false.
            String key = objApi + '|'
                + (r.revealEmail == null ? 'x' : String.valueOf(r.revealEmail)) + '|'
                + (r.revealPhone == null ? 'x' : String.valueOf(r.revealPhone));
            if (!idsByKey.containsKey(key)) {
                idsByKey.put(key, new List<Id>());
                objByKey.put(key, objApi);
                revealEmailByKey.put(key, r.revealEmail);
                revealPhoneByKey.put(key, r.revealPhone);
            }
            idsByKey.get(key).add(r.recordId);
        }

        for (String key : idsByKey.keySet()) {
            System.enqueueJob(new AmplemarketBatchEnrichQueueable(
                objByKey.get(key), idsByKey.get(key),
                revealEmailByKey.get(key), revealPhoneByKey.get(key)));
        }

        for (Request r : reqs) {
            Response resp = new Response();
            resp.success = true;
            resp.message = 'Batch enrichment dispatched';
            resp.fieldsApplied = 0;
            resp.appliedFieldsHtml = '<p>Batch enrichment has been dispatched. Field-level results will appear on each record\'s Enrichment Logs once processing completes.</p>';
            out.add(resp);
        }
        return out;
    }
}
