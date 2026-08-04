global with sharing class AmplemarketRevealDefaults {

    global class Request {
        @InvocableVariable(required=true label='Record Id')
        global Id recordId;
        @InvocableVariable(label='Object API Name (optional, derived from Id if blank)')
        global String objectApiName;
    }

    global class Response {
        @InvocableVariable(label='Reveal Email Default')
        global Boolean revealEmailDefault;
        @InvocableVariable(label='Reveal Phone Default')
        global Boolean revealPhoneDefault;
        @InvocableVariable(label='Is Person Object')
        global Boolean isPerson;
    }

    @InvocableMethod(
        label='Get Amplemarket Reveal Defaults'
        description='Returns the settings-configured Reveal Email / Reveal Phone defaults for a record, used to pre-seed the reveal toggles in a screen flow.'
    )
    global static List<Response> getDefaults(List<Request> reqs) {
        List<Response> out = new List<Response>();
        if (reqs == null || reqs.isEmpty()) return out;
        for (Request r : reqs) {
            AmplemarketEnrichmentService.RevealDefaults rd =
                AmplemarketEnrichmentService.revealDefaults(r.recordId, r.objectApiName);
            Response resp = new Response();
            resp.revealEmailDefault = rd.revealEmail;
            resp.revealPhoneDefault = rd.revealPhone;
            resp.isPerson = rd.isPerson;
            out.add(resp);
        }
        return out;
    }
}
