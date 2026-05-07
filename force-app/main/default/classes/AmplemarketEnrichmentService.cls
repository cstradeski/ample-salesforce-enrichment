public with sharing class AmplemarketEnrichmentService {

    private static final Integer LOG_PAYLOAD_TRUNCATE = 30000;

    public class ServiceResult {
        public Boolean success = false;
        public String message;
        public Id logId;
        public Integer fieldsApplied = 0;
        public String appliedFieldsHtml;
    }

    /**
     * Synchronous single-record enrichment. Used by the screen-flow path.
     */
    public static ServiceResult enrichSingle(Id recordId, String objectApiName) {
        ServiceResult result = new ServiceResult();
        Datetime started = Datetime.now();

        if (recordId == null) {
            result.message = 'recordId is required';
            return result;
        }
        String objApi = String.isNotBlank(objectApiName)
            ? objectApiName
            : recordId.getSObjectType().getDescribe().getName();

        Map<String, List<Amplemarket_Mapping__c>> grouped = loadMappings(objApi);
        List<Amplemarket_Mapping__c> matchInputs = grouped.get(AmplemarketDTO.MAPPING_MATCH_INPUT);
        List<Amplemarket_Mapping__c> outputs = grouped.get(AmplemarketDTO.MAPPING_OUTPUT_FIELD);

        if (matchInputs == null || matchInputs.isEmpty()) {
            result.message = 'No active match-input mappings configured for ' + objApi;
            result.appliedFieldsHtml = errorHtml(result.message);
            result.logId = writeLog(recordId, objApi, null, 'Error', null, null, result.message, null, started);
            return result;
        }

        SObject record;
        try {
            record = querySourceRecord(objApi, recordId, matchInputs, outputs);
        } catch (Exception e) {
            result.message = 'Could not load source record: ' + e.getMessage();
            result.appliedFieldsHtml = errorHtml(result.message);
            result.logId = writeLog(recordId, objApi, null, 'Error', null, null, result.message, null, started);
            return result;
        }

        Map<String, String> queryParams = new Map<String, String>();
        Boolean revealEmail = false;
        Boolean revealPhone = false;

        for (Amplemarket_Mapping__c m : matchInputs) {
            if (m.Is_Active__c != true) continue;
            String key = m.Amplemarket_Field__c;
            if (String.isBlank(key)) continue;
            if (m.Reveal_Email__c == true) revealEmail = true;
            if (m.Reveal_Phone__c == true) revealPhone = true;
            Object val = record.get(m.Salesforce_Field__c);
            if (val != null && String.isNotBlank(String.valueOf(val))) {
                String normalized = normalizeMatchValue(key, String.valueOf(val));
                if (String.isNotBlank(normalized)) queryParams.put(key, normalized);
            }
        }

        if (queryParams.isEmpty()) {
            result.message = 'Source record has no values for any configured match input.';
            result.appliedFieldsHtml = errorHtml(result.message);
            result.logId = writeLog(recordId, objApi, null, 'Error', null, null, result.message, null, started);
            return result;
        }

        String endpoint;
        if (AmplemarketDTO.isPersonObject(objApi)) {
            endpoint = '/people/find';
            // Amplemarket rejects reveal_email when email is already a match input
            // (and there's nothing to reveal). Same defensive check for phone.
            if (revealEmail && !queryParams.containsKey('email')) {
                queryParams.put('reveal_email', 'true');
            }
            if (revealPhone) queryParams.put('reveal_phone_numbers', 'true');
        } else if (AmplemarketDTO.isCompanyObject(objApi)) {
            endpoint = '/companies/find';
        } else {
            result.message = 'Object not supported: ' + objApi;
            result.appliedFieldsHtml = errorHtml(result.message);
            result.logId = writeLog(recordId, objApi, null, 'Error', null, null, result.message, null, started);
            return result;
        }

        AmplemarketHttpClient.Result http;
        try {
            http = new AmplemarketHttpClient().get(endpoint, queryParams);
        } catch (AmplemarketHttpClient.CalloutException ce) {
            result.message = ce.getMessage();
            result.appliedFieldsHtml = errorHtml(result.message);
            result.logId = writeLog(recordId, objApi, endpoint, 'Error',
                JSON.serialize(queryParams), null, result.message, null, started);
            return result;
        }

        if (!http.isSuccess()) {
            result.message = 'API returned ' + http.statusCode + ': ' + http.status;
            result.appliedFieldsHtml = errorHtml(result.message);
            result.logId = writeLog(recordId, objApi, endpoint, 'Error',
                JSON.serialize(queryParams), http.body, result.message, null, started);
            return result;
        }

        Map<String, Object> parsed;
        try {
            parsed = (Map<String, Object>) JSON.deserializeUntyped(http.body);
        } catch (Exception e) {
            result.message = 'Could not parse Amplemarket response: ' + e.getMessage();
            result.appliedFieldsHtml = errorHtml(result.message);
            result.logId = writeLog(recordId, objApi, endpoint, 'Error',
                JSON.serialize(queryParams), http.body, result.message, null, started);
            return result;
        }

        SObject toUpdate = Schema.getGlobalDescribe().get(objApi).newSObject(recordId);
        AmplemarketFieldMapper.FieldMapResult mapRes = AmplemarketFieldMapper.applyOutputs(
            toUpdate, record, objApi, parsed,
            outputs == null ? new List<Amplemarket_Mapping__c>() : outputs
        );
        result.fieldsApplied = mapRes.fieldsApplied;

        try {
            if (mapRes.fieldsApplied > 0) {
                update toUpdate;
            }
        } catch (DmlException de) {
            result.message = 'DML failed when writing enrichment: ' + de.getMessage();
            result.appliedFieldsHtml = errorHtml(result.message);
            result.logId = writeLog(recordId, objApi, endpoint, 'Error',
                JSON.serialize(queryParams), http.body, result.message, null, started);
            return result;
        }

        Decimal credits = estimateCredits(parsed, revealEmail, revealPhone);
        String status = mapRes.warnings.isEmpty() && mapRes.fieldsApplied > 0
            ? 'Success'
            : (mapRes.fieldsApplied > 0 ? 'Partial' : 'Error');
        String msg = mapRes.fieldsApplied + ' field(s) updated' +
            (mapRes.warnings.isEmpty() ? '' : '; warnings: ' + String.join(mapRes.warnings, '; '));
        result.success = mapRes.fieldsApplied > 0;
        result.message = msg;
        result.appliedFieldsHtml = buildAppliedFieldsHtml(objApi, mapRes);
        result.logId = writeLog(recordId, objApi, endpoint, status,
            JSON.serialize(queryParams), http.body, msg, credits, started);
        writeFieldOutcomes(result.logId, mapRes.outcomes);
        return result;
    }

    @TestVisible
    private static String buildAppliedFieldsHtml(String objectApiName, AmplemarketFieldMapper.FieldMapResult mapRes) {
        if (mapRes == null || mapRes.outcomes == null) return null;

        List<AmplemarketFieldMapper.FieldOutcome> applied = new List<AmplemarketFieldMapper.FieldOutcome>();
        Integer skippedPopulated = 0;
        Integer skippedNoValue = 0;
        for (AmplemarketFieldMapper.FieldOutcome o : mapRes.outcomes) {
            if (o.status == AmplemarketFieldMapper.STATUS_APPLIED) {
                applied.add(o);
            } else if (o.status == AmplemarketFieldMapper.STATUS_SKIPPED_POPULATED) {
                skippedPopulated++;
            } else if (o.status == AmplemarketFieldMapper.STATUS_SKIPPED_NO_VALUE) {
                skippedNoValue++;
            }
        }

        String html;
        if (applied.isEmpty()) {
            html = '<p>No fields were updated. Either Amplemarket returned no new values, '
                + 'or all mapped fields are already populated on this ' + escapeHtml(objectApiName) + '.</p>';
        } else {
            html = '<p><strong>Successfully enriched ' + applied.size() + ' field'
                + (applied.size() == 1 ? '' : 's')
                + ' on this ' + escapeHtml(objectApiName) + ':</strong></p><ul>';
            for (AmplemarketFieldMapper.FieldOutcome o : applied) {
                String label = String.isNotBlank(o.salesforceLabel) ? o.salesforceLabel : o.salesforceField;
                String val = o.newValue == null ? '' : o.newValue;
                if (val.length() > 250) val = val.substring(0, 250) + '…';
                html += '<li><strong>' + escapeHtml(label) + ':</strong> '
                    + (String.isBlank(val) ? '<em>(blank)</em>' : escapeHtml(val))
                    + '</li>';
            }
            html += '</ul>';
        }

        if (skippedPopulated > 0) {
            html += '<p><em>' + skippedPopulated + ' field'
                + (skippedPopulated == 1 ? ' was' : 's were')
                + ' left unchanged because the existing value is already populated.</em></p>';
        }
        if (skippedNoValue > 0 && !applied.isEmpty()) {
            html += '<p><em>' + skippedNoValue + ' mapped field'
                + (skippedNoValue == 1 ? ' had' : 's had')
                + ' no value returned by Amplemarket.</em></p>';
        }
        if (mapRes.warnings != null && !mapRes.warnings.isEmpty()) {
            html += '<p><strong>Warnings:</strong></p><ul>';
            for (String w : mapRes.warnings) {
                html += '<li>' + escapeHtml(w) + '</li>';
            }
            html += '</ul>';
        }
        return html;
    }

    @TestVisible
    private static String errorHtml(String message) {
        return '<p>Enrichment could not be completed: ' + escapeHtml(message) + '</p>';
    }

    private static String escapeHtml(String s) {
        return s == null ? '' : s.escapeHtml4();
    }

    @TestVisible
    private static String normalizeMatchValue(String key, String raw) {
        if (String.isBlank(raw)) return null;
        String v = raw.trim();
        if (key == 'domain' || key == 'company_domain') {
            String d = v.toLowerCase();
            Integer scheme = d.indexOf('://');
            if (scheme >= 0) d = d.substring(scheme + 3);
            if (d.startsWith('www.')) d = d.substring(4);
            Integer slash = d.indexOf('/');
            if (slash >= 0) d = d.substring(0, slash);
            return d;
        }
        return v;
    }

    @TestVisible
    private static void writeFieldOutcomes(Id logId, List<AmplemarketFieldMapper.FieldOutcome> outcomes) {
        if (logId == null || outcomes == null || outcomes.isEmpty()) return;
        List<Enrichment_Log_Field__c> rows = new List<Enrichment_Log_Field__c>();
        for (AmplemarketFieldMapper.FieldOutcome o : outcomes) {
            rows.add(new Enrichment_Log_Field__c(
                Enrichment_Log__c = logId,
                Salesforce_Field__c = o.salesforceField,
                Amplemarket_Field__c = o.amplemarketField,
                Old_Value__c = o.oldValue,
                New_Value__c = o.newValue,
                Status__c = o.status,
                Error_Detail__c = o.errorDetail
            ));
        }
        insert rows;
    }

    private static Map<String, List<Amplemarket_Mapping__c>> loadMappings(String objectApiName) {
        Map<String, List<Amplemarket_Mapping__c>> grouped = new Map<String, List<Amplemarket_Mapping__c>>{
            AmplemarketDTO.MAPPING_MATCH_INPUT => new List<Amplemarket_Mapping__c>(),
            AmplemarketDTO.MAPPING_OUTPUT_FIELD => new List<Amplemarket_Mapping__c>()
        };
        for (Amplemarket_Mapping__c m : [
            SELECT Object_API_Name__c, Mapping_Type__c, Amplemarket_Field__c,
                   Salesforce_Field__c, Reveal_Email__c, Reveal_Phone__c,
                   Update_Behavior__c, Is_Active__c
            FROM Amplemarket_Mapping__c
            WHERE Object_API_Name__c = :objectApiName
              AND Is_Active__c = true
        ]) {
            List<Amplemarket_Mapping__c> bucket = grouped.get(m.Mapping_Type__c);
            if (bucket != null) bucket.add(m);
        }
        return grouped;
    }

    private static SObject querySourceRecord(String objectApiName, Id recordId,
            List<Amplemarket_Mapping__c> matchInputs, List<Amplemarket_Mapping__c> outputs) {
        Set<String> fields = new Set<String>{ 'Id' };
        for (Amplemarket_Mapping__c m : matchInputs) {
            if (String.isNotBlank(m.Salesforce_Field__c)) fields.add(m.Salesforce_Field__c);
        }
        if (outputs != null) {
            for (Amplemarket_Mapping__c m : outputs) {
                if (String.isNotBlank(m.Salesforce_Field__c)) fields.add(m.Salesforce_Field__c);
            }
        }
        String soql = 'SELECT ' + String.join(new List<String>(fields), ', ')
            + ' FROM ' + objectApiName + ' WHERE Id = :recordId LIMIT 1';
        List<SObject> rows = Database.query(soql);
        if (rows.isEmpty()) {
            throw new QueryException(objectApiName + ' ' + recordId + ' not found');
        }
        return rows[0];
    }

    private static Decimal estimateCredits(Map<String, Object> parsed, Boolean revealEmail, Boolean revealPhone) {
        Decimal total = 0;
        if (parsed != null && parsed.get('id') != null) total += 0.5;
        if (revealEmail && parsed != null && parsed.get('email') != null) total += 1;
        if (revealPhone && parsed != null) {
            Object pn = parsed.get('phone_numbers');
            if (pn instanceof List<Object> && !((List<Object>) pn).isEmpty()) total += 1;
        }
        return total;
    }

    public static Id writeLog(Id recordId, String objectApiName, String endpoint, String status,
            String requestPayload, String responsePayload, String errorMessage,
            Decimal creditsUsed, Datetime started) {
        Enrichment_Log__c log = new Enrichment_Log__c(
            Record_Id__c = recordId,
            Object_API_Name__c = objectApiName,
            Endpoint__c = endpoint,
            Status__c = status,
            Request_Payload__c = truncate(requestPayload, LOG_PAYLOAD_TRUNCATE),
            Response_Payload__c = truncate(responsePayload, 130000),
            Error_Message__c = truncate(errorMessage, LOG_PAYLOAD_TRUNCATE),
            Credits_Used__c = creditsUsed,
            Run_Timestamp__c = started == null ? Datetime.now() : started
        );
        insert log;
        return log.Id;
    }

    private static String truncate(String s, Integer max) {
        if (s == null) return null;
        return s.length() <= max ? s : s.substring(0, max);
    }
}
