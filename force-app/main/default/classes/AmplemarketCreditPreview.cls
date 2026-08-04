global with sharing class AmplemarketCreditPreview {

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
        @InvocableVariable(label='Has Active Match Inputs')
        global Boolean hasMappings;
        @InvocableVariable(label='Best Case Credits')
        global Decimal bestCase;
        @InvocableVariable(label='Match-Only Credits')
        global Decimal matchOnlyCase;
        @InvocableVariable(label='Worst Case Credits')
        global Decimal worstCase;
        @InvocableVariable(label='Summary HTML')
        global String summaryHtml;
    }

    @InvocableMethod(
        label='Preview Amplemarket Enrichment Credits'
        description='Returns a best/worst case credit estimate for a single record without calling the API.'
    )
    global static List<Response> previewCredits(List<Request> reqs) {
        List<Response> out = new List<Response>();
        if (reqs == null || reqs.isEmpty()) return out;
        for (Request r : reqs) {
            AmplemarketEnrichmentService.CreditPreview cp =
                AmplemarketEnrichmentService.previewCredits(
                    r.recordId, r.objectApiName, r.revealEmail, r.revealPhone);
            Response resp = new Response();
            resp.hasMappings = cp.hasMappings;
            resp.bestCase = cp.bestCase;
            resp.matchOnlyCase = cp.matchOnlyCase;
            resp.worstCase = cp.worstCase;
            resp.summaryHtml = cp.summaryHtml;
            out.add(resp);
        }
        return out;
    }
}
