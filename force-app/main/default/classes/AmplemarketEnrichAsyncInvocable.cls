/**
 * Permission-independent enrichment entry point for automated flows.
 *
 * AmplemarketEnrichInvocable calls Amplemarket directly, so the running user must
 * hold the Amplemarket permission set and External Credential principal — Salesforce
 * blocks a Named Credential callout when the running user lacks principal access, and
 * no Apex modifier overrides that.
 *
 * This action instead writes an Enrichment_Request__c row. The automated enrichment
 * job (AmplemarketEnrichRequestProcessor) drains the queue and performs the callouts
 * as the admin who enabled it from the Amplemarket Settings tab, because scheduled
 * Apex runs as the user who scheduled it. The user who triggered the flow therefore
 * needs no Amplemarket permissions.
 *
 * Trade-off: enrichment is asynchronous, so this action returns "queued" rather than
 * field-level results. Outcomes land on the Enrichment Log. Use the synchronous
 * "Enrich with Amplemarket" action for screen flows where the user waits for results.
 *
 * `without sharing` so an automated flow can queue work for records the triggering
 * user may not personally have access to.
 */
global without sharing class AmplemarketEnrichAsyncInvocable {

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
        @InvocableVariable(label='Queued')
        global Boolean queued;
        @InvocableVariable(label='Message')
        global String message;
        @InvocableVariable(label='Enrichment Request Id')
        global Id requestId;
    }

    @InvocableMethod(
        label='Enrich with Amplemarket (Async, No User Permissions)'
        description='Queues an Amplemarket enrichment. The callout runs later as the admin who enabled automated enrichment, so the triggering user needs no Amplemarket permissions. Results appear on the Enrichment Log.'
    )
    global static List<Response> enrich(List<Request> reqs) {
        List<Response> out = new List<Response>();
        if (reqs == null || reqs.isEmpty()) return out;

        List<Enrichment_Request__c> rows = new List<Enrichment_Request__c>();
        List<Integer> rowIdxByRequest = new List<Integer>();

        for (Request r : reqs) {
            Response resp = new Response();
            out.add(resp);
            if (r.recordId == null) {
                resp.queued = false;
                resp.message = 'recordId is required';
                rowIdxByRequest.add(-1);
                continue;
            }
            String objApi = String.isNotBlank(r.objectApiName)
                ? r.objectApiName
                : r.recordId.getSObjectType().getDescribe().getName();

            rows.add(new Enrichment_Request__c(
                Record_Id__c = String.valueOf(r.recordId),
                Object_API_Name__c = objApi,
                Reveal_Email__c = r.revealEmail == null ? null : String.valueOf(r.revealEmail),
                Reveal_Phone__c = r.revealPhone == null ? null : String.valueOf(r.revealPhone),
                Status__c = 'Pending'
            ));
            rowIdxByRequest.add(rows.size() - 1);
        }

        if (rows.isEmpty()) return out;

        List<Database.SaveResult> saves = Database.insert(rows, false);
        for (Integer i = 0; i < out.size(); i++) {
            Integer idx = rowIdxByRequest[i];
            if (idx < 0) continue; // already carries the validation error
            Response resp = out[i];
            Database.SaveResult sr = saves[idx];
            if (sr.isSuccess()) {
                resp.queued = true;
                resp.requestId = sr.getId();
                resp.message = 'Enrichment queued. Results will appear on the Enrichment Log.';
            } else {
                resp.queued = false;
                resp.message = 'Could not queue enrichment: '
                    + (sr.getErrors().isEmpty() ? 'unknown error' : sr.getErrors()[0].getMessage());
            }
        }
        return out;
    }
}
