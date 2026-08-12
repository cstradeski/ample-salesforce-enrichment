public with sharing class AmplemarketEnrichmentService {

    private static final Integer LOG_PAYLOAD_TRUNCATE = 30000;

    public class ServiceResult {
        public Boolean success = false;
        public String message;
        public Id logId;
        public Integer fieldsApplied = 0;
        public String appliedFieldsHtml;
        public Decimal creditsUsed = 0;
    }

    public class CreditPreview {
        public Boolean hasMappings = false;
        public Boolean isPerson = false;
        public Boolean revealEmail = false;
        public Boolean revealPhone = false;
        public Decimal bestCase = 0;     // 0 — no match found
        public Decimal matchOnlyCase = 0; // 0.5 if a match is found, no reveals
        public Decimal worstCase = 0;    // 0.5 + revealEmail (if applied) + revealPhone (if applied)
        public String summaryHtml;
    }

    /**
     * Settings-derived default reveal flags for an object. Mirrors the OR-across-
     * active-match-inputs logic used by enrichSingle/enrichBatch. Used to pre-seed
     * the reveal toggles in the screen flows (via AmplemarketRevealDefaults).
     */
    public class RevealDefaults {
        public Boolean isPerson = false;
        public Boolean revealEmail = false;
        public Boolean revealPhone = false;
    }

    public static RevealDefaults revealDefaults(Id recordId, String objectApiName) {
        RevealDefaults rd = new RevealDefaults();
        String objApi = String.isNotBlank(objectApiName)
            ? objectApiName
            : (recordId == null ? null : recordId.getSObjectType().getDescribe().getName());
        if (String.isBlank(objApi)) return rd;

        rd.isPerson = AmplemarketDTO.isPersonObject(objApi);
        if (!rd.isPerson) return rd; // reveals only apply to /people/find

        List<Amplemarket_Mapping__c> matchInputs =
            loadMappings(objApi).get(AmplemarketDTO.MAPPING_MATCH_INPUT);
        if (matchInputs == null) return rd;
        for (Amplemarket_Mapping__c m : matchInputs) {
            if (m.Is_Active__c != true) continue;
            if (String.isBlank(m.Amplemarket_Field__c)) continue;
            if (m.Reveal_Email__c == true) rd.revealEmail = true;
            if (m.Reveal_Phone__c == true) rd.revealPhone = true;
        }
        return rd;
    }

    /**
     * Pre-flight credit estimate. Reads mapping config and returns best/worst case
     * costs without making the callout. Surfaced via AmplemarketCreditPreview to
     * the screen flows so the user can confirm before spending credits.
     */
    public static CreditPreview previewCredits(Id recordId, String objectApiName) {
        return previewCredits(recordId, objectApiName, null, null);
    }

    /**
     * As previewCredits, but with optional per-run reveal overrides from the flow.
     * A null override falls back to the settings-derived default; a non-null value
     * (true/false) takes precedence, so the estimate matches what enrichSingle will send.
     */
    public static CreditPreview previewCredits(Id recordId, String objectApiName,
            Boolean revealEmailOverride, Boolean revealPhoneOverride) {
        CreditPreview cp = new CreditPreview();
        String objApi = String.isNotBlank(objectApiName)
            ? objectApiName
            : (recordId == null ? null : recordId.getSObjectType().getDescribe().getName());

        if (String.isBlank(objApi)) {
            cp.summaryHtml = '<p>Unable to determine object type for credit preview.</p>';
            return cp;
        }

        Map<String, List<Amplemarket_Mapping__c>> grouped = loadMappings(objApi);
        List<Amplemarket_Mapping__c> matchInputs = grouped.get(AmplemarketDTO.MAPPING_MATCH_INPUT);

        if (matchInputs == null || matchInputs.isEmpty()) {
            cp.summaryHtml = '<p><strong>No active match-input mappings are configured for ' + escapeHtml(objApi) + '.</strong></p>'
                + '<p>The enrichment will not consume credits, but it will return an error. '
                + 'Configure match inputs on the Amplemarket Settings tab before running enrichment.</p>';
            return cp;
        }
        cp.hasMappings = true;
        cp.isPerson = AmplemarketDTO.isPersonObject(objApi);

        // Mirror the service iteration. The service builds the same `revealEmail` /
        // `revealPhone` booleans by visiting only active rows with a non-blank
        // Amplemarket_Field__c.
        Set<String> emailMatchSfFields = new Set<String>();
        for (Amplemarket_Mapping__c m : matchInputs) {
            if (m.Is_Active__c != true) continue;
            if (String.isBlank(m.Amplemarket_Field__c)) continue;
            if (m.Amplemarket_Field__c == 'email' && String.isNotBlank(m.Salesforce_Field__c)) {
                emailMatchSfFields.add(m.Salesforce_Field__c);
            }
            if (m.Reveal_Email__c == true) cp.revealEmail = true;
            if (m.Reveal_Phone__c == true) cp.revealPhone = true;
        }

        // Flow overrides win over the settings default (null = keep default).
        if (revealEmailOverride != null) cp.revealEmail = revealEmailOverride;
        if (revealPhoneOverride != null) cp.revealPhone = revealPhoneOverride;

        // The service only suppresses reveal_email when 'email' actually ends up in
        // queryParams, which requires the source record to have a non-blank value
        // on the email-mapped Salesforce field. Query the source to mirror that.
        Boolean emailWillBeInQueryParams = false;
        if (cp.revealEmail && !emailMatchSfFields.isEmpty() && recordId != null) {
            try {
                String soql = 'SELECT ' + String.join(new List<String>(emailMatchSfFields), ', ')
                    + ' FROM ' + objApi + ' WHERE Id = :recordId LIMIT 1';
                List<SObject> rows = Database.query(soql);
                if (!rows.isEmpty()) {
                    SObject src = rows[0];
                    for (String f : emailMatchSfFields) {
                        Object v = src.get(f);
                        if (v != null && String.isNotBlank(String.valueOf(v))) {
                            emailWillBeInQueryParams = true;
                            break;
                        }
                    }
                }
            } catch (Exception e) {
                // Worst-case is safer than best-case for credit warnings.
                emailWillBeInQueryParams = false;
            }
        }

        cp.matchOnlyCase = 0.5;
        cp.worstCase = 0.5;
        if (cp.isPerson) {
            // Reveal_email is sent (and billed) unless 'email' is already in queryParams.
            if (cp.revealEmail && !emailWillBeInQueryParams) cp.worstCase += 1;
            if (cp.revealPhone) cp.worstCase += 1;
        }

        cp.summaryHtml = buildCreditPreviewHtml(cp, objApi);
        return cp;
    }

    private static String buildCreditPreviewHtml(CreditPreview cp, String objApi) {
        String objLabel = escapeHtml(objApi);
        String html = '<p>Running this enrichment will call the Amplemarket API. Credits are only charged on successful matches:</p>';
        html += '<ul>';
        html += '<li><strong>0 credits</strong> &mdash; if Amplemarket does not find a matching ' + objLabel + '</li>';

        if (cp.matchOnlyCase == cp.worstCase) {
            html += '<li><strong>' + formatCredits(cp.worstCase) + ' credit'
                + (cp.worstCase == 1 ? '' : 's') + '</strong> &mdash; if a match is found</li>';
        } else {
            html += '<li><strong>' + formatCredits(cp.matchOnlyCase) + ' credits</strong> &mdash; best case (match found, no extra data revealed)</li>';
            List<String> components = new List<String>{ 'match' };
            if (cp.isPerson && cp.revealEmail) components.add('revealed email');
            if (cp.isPerson && cp.revealPhone) components.add('revealed phone');
            html += '<li><strong>up to ' + formatCredits(cp.worstCase) + ' credits</strong> &mdash; worst case ('
                + String.join(components, ' + ') + ')</li>';
        }
        html += '</ul>';
        html += '<p>Click <strong>Next</strong> to run enrichment, or <strong>Cancel</strong> to abort.</p>';
        return html;
    }

    private static String formatCredits(Decimal d) {
        // 0.5 → "0.5", 2 → "2", 2.5 → "2.5"
        if (d == null) return '0';
        Decimal stripped = d.setScale(1);
        return (stripped == stripped.round()) ? String.valueOf(stripped.intValue()) : String.valueOf(stripped);
    }

    /**
     * Synchronous single-record enrichment. Used by the screen-flow path.
     */
    public static ServiceResult enrichSingle(Id recordId, String objectApiName) {
        return enrichSingle(recordId, objectApiName, null, null);
    }

    /**
     * As enrichSingle, with optional per-run reveal overrides from the flow.
     * Null override → settings default; non-null (true/false) → force that value.
     */
    public static ServiceResult enrichSingle(Id recordId, String objectApiName,
            Boolean revealEmailOverride, Boolean revealPhoneOverride) {
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

        // Flow overrides win over the settings default (null = keep default).
        if (revealEmailOverride != null) revealEmail = revealEmailOverride;
        if (revealPhoneOverride != null) revealPhone = revealPhoneOverride;

        // Weekly-limit enforcement. Blocks the call if the base search is over limit;
        // suppresses individual reveals that are over limit. No-op unless Enforce Limits is on.
        AmplemarketCreditMonitor.Decision gate = AmplemarketCreditMonitor.preCheck(objApi, revealEmail, revealPhone);
        if (gate.blocked) {
            result.message = 'Weekly ' + gate.blockedReason + ' credit limit reached — enrichment blocked.';
            result.appliedFieldsHtml = errorHtml(result.message);
            result.logId = writeLog(recordId, objApi, null, 'Error', null, null, result.message, null, started);
            return result;
        }
        revealEmail = gate.revealEmail;
        revealPhone = gate.revealPhone;

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

        CreditBreakdown credits = estimateCredits(parsed,
            AmplemarketDTO.isPersonObject(objApi),
            queryParams.containsKey('reveal_email'),
            queryParams.containsKey('reveal_phone_numbers'));
        String status = mapRes.warnings.isEmpty() && mapRes.fieldsApplied > 0
            ? 'Success'
            : (mapRes.fieldsApplied > 0 ? 'Partial' : 'Error');
        String msg = mapRes.fieldsApplied + ' field(s) updated' +
            (mapRes.warnings.isEmpty() ? '' : '; warnings: ' + String.join(mapRes.warnings, '; '));
        result.success = mapRes.fieldsApplied > 0;
        result.message = msg;
        result.creditsUsed = credits.total();
        result.appliedFieldsHtml = buildAppliedFieldsHtml(objApi, mapRes, credits.total());
        result.logId = writeLog(recordId, objApi, endpoint, status,
            JSON.serialize(queryParams), http.body, msg, credits, started);
        writeFieldOutcomes(result.logId, mapRes.outcomes);
        // Evaluate weekly limits for alerts (post-spend). Never breaks enrichment.
        AmplemarketCreditMonitor.recordAndNotify();
        return result;
    }

    /**
     * Bulk batch enrichment for the queueable path. Splits work into phases so that
     * ALL callouts happen before ANY DML in the transaction — otherwise iteration N+1's
     * callout would fail with "uncommitted work pending" after iteration N's DML.
     *
     * Returns one ServiceResult per input recordId, in the same order.
     */
    public static List<ServiceResult> enrichBatch(List<Id> recordIds, String objectApiName) {
        return enrichBatch(recordIds, objectApiName, null, null);
    }

    /**
     * As enrichBatch, with optional per-run reveal overrides applied to every record
     * in the batch. Null override → settings default; non-null → force that value.
     * The invocable groups records so a batch shares one override pair.
     */
    public static List<ServiceResult> enrichBatch(List<Id> recordIds, String objectApiName,
            Boolean revealEmailOverride, Boolean revealPhoneOverride) {
        List<ServiceResult> results = new List<ServiceResult>();
        if (recordIds == null || recordIds.isEmpty()) return results;

        Datetime started = Datetime.now();
        String objApi = String.isNotBlank(objectApiName)
            ? objectApiName
            : recordIds[0].getSObjectType().getDescribe().getName();

        // Pre-allocate one result slot per recordId (preserves input ordering).
        for (Integer i = 0; i < recordIds.size(); i++) results.add(new ServiceResult());

        Map<String, List<Amplemarket_Mapping__c>> grouped = loadMappings(objApi);
        List<Amplemarket_Mapping__c> matchInputs = grouped.get(AmplemarketDTO.MAPPING_MATCH_INPUT);
        List<Amplemarket_Mapping__c> outputs = grouped.get(AmplemarketDTO.MAPPING_OUTPUT_FIELD);

        // No mappings → all rows error out with a single bulk log insert at the end.
        if (matchInputs == null || matchInputs.isEmpty()) {
            String msg = 'No active match-input mappings configured for ' + objApi;
            List<Enrichment_Log__c> errLogs = new List<Enrichment_Log__c>();
            for (Integer i = 0; i < recordIds.size(); i++) {
                ServiceResult r = results[i];
                r.message = msg;
                r.appliedFieldsHtml = errorHtml(msg);
                errLogs.add(buildLog(recordIds[i], objApi, null, 'Error', null, null, msg, null, started));
            }
            insert errLogs;
            for (Integer i = 0; i < errLogs.size(); i++) results[i].logId = errLogs[i].Id;
            return results;
        }

        // One bulk query for all source records.
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
            + ' FROM ' + objApi + ' WHERE Id IN :recordIds';
        Map<Id, SObject> sourceById = new Map<Id, SObject>();
        for (SObject row : Database.query(soql)) {
            sourceById.put((Id) row.get('Id'), row);
        }

        // Per-record state collected across phases. Index aligns with `recordIds` / `results`.
        List<Map<String, String>> queryParamsByIdx = new List<Map<String, String>>();
        List<String> endpointByIdx = new List<String>();
        List<AmplemarketHttpClient.Result> httpByIdx = new List<AmplemarketHttpClient.Result>();
        List<String> errorByIdx = new List<String>();          // null if OK so far
        List<Map<String, Object>> parsedByIdx = new List<Map<String, Object>>();
        List<SObject> toUpdateByIdx = new List<SObject>();
        List<AmplemarketFieldMapper.FieldMapResult> mapResByIdx = new List<AmplemarketFieldMapper.FieldMapResult>();
        List<CreditBreakdown> creditsByIdx = new List<CreditBreakdown>();

        // Weekly-limit enforcement inputs: read config + current usage once for the batch.
        Amplemarket_Credit_Config__c creditCfg = AmplemarketCreditMonitor.readConfig();
        AmplemarketCreditMonitor.Usage creditUsage =
            AmplemarketCreditMonitor.enforcementActive(creditCfg)
                ? AmplemarketCreditMonitor.snapshot(creditCfg) : null;

        // Phase 1: per-record callout. NO DML in this phase.
        for (Integer i = 0; i < recordIds.size(); i++) {
            Id recId = recordIds[i];
            queryParamsByIdx.add(null);
            endpointByIdx.add(null);
            httpByIdx.add(null);
            errorByIdx.add(null);
            parsedByIdx.add(null);
            toUpdateByIdx.add(null);
            mapResByIdx.add(null);
            creditsByIdx.add(null);

            SObject record = sourceById.get(recId);
            if (record == null) {
                errorByIdx[i] = objApi + ' ' + recId + ' not found';
                continue;
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

            // Flow overrides win over the settings default (null = keep default).
            if (revealEmailOverride != null) revealEmail = revealEmailOverride;
            if (revealPhoneOverride != null) revealPhone = revealPhoneOverride;

            // Weekly-limit enforcement (shared config/usage for the batch; no-op unless Enforce Limits is on).
            AmplemarketCreditMonitor.Decision gate =
                AmplemarketCreditMonitor.preCheck(objApi, revealEmail, revealPhone, creditUsage, creditCfg);
            if (gate.blocked) {
                errorByIdx[i] = 'Weekly ' + gate.blockedReason + ' credit limit reached — enrichment blocked.';
                continue;
            }
            revealEmail = gate.revealEmail;
            revealPhone = gate.revealPhone;

            if (queryParams.isEmpty()) {
                errorByIdx[i] = 'Source record has no values for any configured match input.';
                continue;
            }

            String endpoint;
            if (AmplemarketDTO.isPersonObject(objApi)) {
                endpoint = '/people/find';
                if (revealEmail && !queryParams.containsKey('email')) {
                    queryParams.put('reveal_email', 'true');
                }
                if (revealPhone) queryParams.put('reveal_phone_numbers', 'true');
            } else if (AmplemarketDTO.isCompanyObject(objApi)) {
                endpoint = '/companies/find';
            } else {
                errorByIdx[i] = 'Object not supported: ' + objApi;
                continue;
            }
            queryParamsByIdx[i] = queryParams;
            endpointByIdx[i] = endpoint;

            try {
                httpByIdx[i] = new AmplemarketHttpClient().get(endpoint, queryParams);
            } catch (AmplemarketHttpClient.CalloutException ce) {
                errorByIdx[i] = ce.getMessage();
            } catch (Exception ex) {
                errorByIdx[i] = 'Callout failed: ' + ex.getMessage();
            }
        }

        // Phase 2: build SObjects to update, in memory only. Still NO DML.
        List<SObject> toUpdate = new List<SObject>();
        List<Integer> toUpdateIdx = new List<Integer>();
        for (Integer i = 0; i < recordIds.size(); i++) {
            if (errorByIdx[i] != null) continue;
            AmplemarketHttpClient.Result http = httpByIdx[i];
            if (http == null) continue;
            if (!http.isSuccess()) {
                errorByIdx[i] = 'API returned ' + http.statusCode + ': ' + http.status;
                continue;
            }
            Map<String, Object> parsed;
            try {
                parsed = (Map<String, Object>) JSON.deserializeUntyped(http.body);
            } catch (Exception e) {
                errorByIdx[i] = 'Could not parse Amplemarket response: ' + e.getMessage();
                continue;
            }
            parsedByIdx[i] = parsed;

            SObject sob = Schema.getGlobalDescribe().get(objApi).newSObject(recordIds[i]);
            AmplemarketFieldMapper.FieldMapResult mapRes = AmplemarketFieldMapper.applyOutputs(
                sob, sourceById.get(recordIds[i]), objApi, parsed,
                outputs == null ? new List<Amplemarket_Mapping__c>() : outputs
            );
            toUpdateByIdx[i] = sob;
            mapResByIdx[i] = mapRes;
            creditsByIdx[i] = estimateCredits(parsed,
                AmplemarketDTO.isPersonObject(objApi),
                queryParamsByIdx[i].containsKey('reveal_email'),
                queryParamsByIdx[i].containsKey('reveal_phone_numbers'));

            if (mapRes.fieldsApplied > 0) {
                toUpdate.add(sob);
                toUpdateIdx.add(i);
            }
        }

        // Phase 3: bulk DML — one update for the whole batch.
        if (!toUpdate.isEmpty()) {
            Database.SaveResult[] saveRes = Database.update(toUpdate, false);
            for (Integer k = 0; k < saveRes.size(); k++) {
                if (!saveRes[k].isSuccess() && !saveRes[k].getErrors().isEmpty()) {
                    Integer i = toUpdateIdx[k];
                    errorByIdx[i] = 'DML failed when writing enrichment: '
                        + saveRes[k].getErrors()[0].getMessage();
                }
            }
        }

        // Phase 4: bulk insert logs (one row per input record).
        List<Enrichment_Log__c> logs = new List<Enrichment_Log__c>();
        for (Integer i = 0; i < recordIds.size(); i++) {
            ServiceResult r = results[i];
            String reqJson = queryParamsByIdx[i] == null ? null : JSON.serialize(queryParamsByIdx[i]);
            String resBody = httpByIdx[i] == null ? null : httpByIdx[i].body;
            if (errorByIdx[i] != null) {
                r.message = errorByIdx[i];
                r.appliedFieldsHtml = errorHtml(r.message);
                r.success = false;
                r.fieldsApplied = 0;
                r.creditsUsed = 0;
                logs.add(buildLog(recordIds[i], objApi, endpointByIdx[i], 'Error',
                    reqJson, resBody, r.message, null, started));
            } else {
                AmplemarketFieldMapper.FieldMapResult mapRes = mapResByIdx[i];
                String status = mapRes.warnings.isEmpty() && mapRes.fieldsApplied > 0
                    ? 'Success'
                    : (mapRes.fieldsApplied > 0 ? 'Partial' : 'Error');
                String msg = mapRes.fieldsApplied + ' field(s) updated' +
                    (mapRes.warnings.isEmpty() ? '' : '; warnings: ' + String.join(mapRes.warnings, '; '));
                r.success = mapRes.fieldsApplied > 0;
                r.message = msg;
                r.fieldsApplied = mapRes.fieldsApplied;
                r.creditsUsed = creditsByIdx[i] == null ? 0 : creditsByIdx[i].total();
                r.appliedFieldsHtml = buildAppliedFieldsHtml(objApi, mapRes,
                    creditsByIdx[i] == null ? 0 : creditsByIdx[i].total());
                logs.add(buildLog(recordIds[i], objApi, endpointByIdx[i], status,
                    reqJson, resBody, msg, creditsByIdx[i], started));
            }
        }
        insert logs;
        for (Integer i = 0; i < logs.size(); i++) results[i].logId = logs[i].Id;

        // Phase 5: bulk insert field outcomes.
        List<Enrichment_Log_Field__c> outcomeRows = new List<Enrichment_Log_Field__c>();
        for (Integer i = 0; i < recordIds.size(); i++) {
            AmplemarketFieldMapper.FieldMapResult mapRes = mapResByIdx[i];
            if (mapRes == null || mapRes.outcomes == null) continue;
            Id parentLogId = logs[i].Id;
            for (AmplemarketFieldMapper.FieldOutcome o : mapRes.outcomes) {
                outcomeRows.add(new Enrichment_Log_Field__c(
                    Enrichment_Log__c = parentLogId,
                    Salesforce_Field__c = o.salesforceField,
                    Amplemarket_Field__c = o.amplemarketField,
                    Old_Value__c = o.oldValue,
                    New_Value__c = o.newValue,
                    Status__c = o.status,
                    Error_Detail__c = o.errorDetail
                ));
            }
        }
        if (!outcomeRows.isEmpty()) insert outcomeRows;

        // Evaluate weekly limits for alerts once for the whole batch. Never breaks enrichment.
        AmplemarketCreditMonitor.recordAndNotify();

        return results;
    }

    private static Enrichment_Log__c buildLog(Id recordId, String objectApiName, String endpoint, String status,
            String requestPayload, String responsePayload, String errorMessage,
            CreditBreakdown breakdown, Datetime started) {
        return new Enrichment_Log__c(
            Record_Id__c = recordId,
            Object_API_Name__c = objectApiName,
            Endpoint__c = endpoint,
            Status__c = status,
            Request_Payload__c = truncate(requestPayload, LOG_PAYLOAD_TRUNCATE),
            Response_Payload__c = truncate(responsePayload, 130000),
            Error_Message__c = truncate(errorMessage, LOG_PAYLOAD_TRUNCATE),
            Credits_Used__c = breakdown == null ? null : breakdown.total(),
            Person_Search_Credits__c = breakdown == null ? null : breakdown.personSearch,
            Company_Search_Credits__c = breakdown == null ? null : breakdown.companySearch,
            Email_Reveal_Credits__c = breakdown == null ? null : breakdown.emailReveal,
            Phone_Reveal_Credits__c = breakdown == null ? null : breakdown.phoneReveal,
            Run_Timestamp__c = started == null ? Datetime.now() : started
        );
    }

    @TestVisible
    private static String buildAppliedFieldsHtml(String objectApiName, AmplemarketFieldMapper.FieldMapResult mapRes, Decimal creditsUsed) {
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
        if (creditsUsed != null) {
            html += '<p><em>Amplemarket credits consumed: <strong>' + formatCredits(creditsUsed) + '</strong></em></p>';
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

    /**
     * Per-category credit breakdown for a single enrichment. total() feeds the
     * legacy Credits_Used__c; the four category figures feed the credit dashboard.
     */
    public class CreditBreakdown {
        public Decimal personSearch = 0;
        public Decimal companySearch = 0;
        public Decimal emailReveal = 0;
        public Decimal phoneReveal = 0;
        public Decimal total() {
            return (personSearch == null ? 0 : personSearch)
                 + (companySearch == null ? 0 : companySearch)
                 + (emailReveal == null ? 0 : emailReveal)
                 + (phoneReveal == null ? 0 : phoneReveal);
        }
    }

    /**
     * Estimate credits charged, split by category, based on what was actually sent
     * and what came back. Use the *sent* booleans (queryParams.containsKey('reveal_email')
     * etc.) — not the user-config booleans — because the service may suppress reveal_email
     * when email is already a match input, in which case Amplemarket doesn't bill for it.
     * The 0.5 match credit is attributed to person vs company search by isPerson.
     */
    @TestVisible
    private static CreditBreakdown estimateCredits(Map<String, Object> parsed, Boolean isPerson,
            Boolean sentRevealEmail, Boolean sentRevealPhone) {
        CreditBreakdown b = new CreditBreakdown();
        if (parsed != null && parsed.get('id') != null) {
            if (isPerson) b.personSearch = 0.5; else b.companySearch = 0.5;
        }
        if (sentRevealEmail && parsed != null && parsed.get('email') != null) b.emailReveal = 1;
        if (sentRevealPhone && parsed != null) {
            Object pn = parsed.get('phone_numbers');
            if (pn instanceof List<Object> && !((List<Object>) pn).isEmpty()) b.phoneReveal = 1;
        }
        return b;
    }

    public static Id writeLog(Id recordId, String objectApiName, String endpoint, String status,
            String requestPayload, String responsePayload, String errorMessage,
            CreditBreakdown breakdown, Datetime started) {
        Enrichment_Log__c log = buildLog(recordId, objectApiName, endpoint, status,
            requestPayload, responsePayload, errorMessage, breakdown, started);
        insert log;
        return log.Id;
    }

    private static String truncate(String s, Integer max) {
        if (s == null) return null;
        return s.length() <= max ? s : s.substring(0, max);
    }
}
