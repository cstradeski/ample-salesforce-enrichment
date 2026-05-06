global with sharing class AmplemarketEnrichInvocable {

    global class Request {
        @InvocableVariable(required=true label='Record Id')
        global Id recordId;
        @InvocableVariable(label='Object API Name (optional, derived from Id if blank)')
        global String objectApiName;
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
            AmplemarketEnrichmentService.ServiceResult sr = AmplemarketEnrichmentService.enrichSingle(r.recordId, r.objectApiName);
            Response resp = new Response();
            resp.success = sr.success;
            resp.message = sr.message;
            resp.logId = sr.logId;
            resp.fieldsApplied = sr.fieldsApplied;
            out.add(resp);
            return out;
        }

        // Bulk path: group by object, dispatch async, return placeholders.
        Map<String, List<Id>> idsByObject = new Map<String, List<Id>>();
        for (Request r : reqs) {
            if (r.recordId == null) continue;
            String objApi = String.isNotBlank(r.objectApiName)
                ? r.objectApiName
                : r.recordId.getSObjectType().getDescribe().getName();
            if (!idsByObject.containsKey(objApi)) idsByObject.put(objApi, new List<Id>());
            idsByObject.get(objApi).add(r.recordId);
        }

        for (String objApi : idsByObject.keySet()) {
            System.enqueueJob(new AmplemarketBatchEnrichQueueable(objApi, idsByObject.get(objApi)));
        }

        for (Request r : reqs) {
            Response resp = new Response();
            resp.success = true;
            resp.message = 'Batch enrichment dispatched';
            resp.fieldsApplied = 0;
            out.add(resp);
        }
        return out;
    }
}
