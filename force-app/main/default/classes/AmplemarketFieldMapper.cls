public with sharing class AmplemarketFieldMapper {

    public static final String STATUS_APPLIED = 'Applied';
    public static final String STATUS_SKIPPED_POPULATED = 'Skipped - Already Populated';
    public static final String STATUS_SKIPPED_NO_VALUE = 'Skipped - No Value';
    public static final String STATUS_ERROR = 'Error';

    public class FieldOutcome {
        public String salesforceField;
        public String salesforceLabel;
        public String amplemarketField;
        public String oldValue;
        public String newValue;
        public String status;
        public String errorDetail;
    }

    public class FieldMapResult {
        public Integer fieldsApplied = 0;
        public Integer fieldsSkipped = 0;
        public List<String> warnings = new List<String>();
        public List<FieldOutcome> outcomes = new List<FieldOutcome>();
    }

    /**
     * Apply Amplemarket response data to an SObject in-memory.
     * @param record         SObject to populate (caller does the DML).
     * @param existing       The currently-stored SObject, used to decide whether to skip
     *                       under "Only if Empty" update behavior. May be null to skip the check.
     * @param objectApiName  e.g. "Lead" — used to describe target field types.
     * @param responseRoot   Parsed JSON map from Amplemarket.
     * @param outputMappings rows from Amplemarket_Mapping__c where Mapping_Type__c='Output Field'.
     */
    public static FieldMapResult applyOutputs(
        SObject record,
        SObject existing,
        String objectApiName,
        Map<String, Object> responseRoot,
        List<Amplemarket_Mapping__c> outputMappings
    ) {
        FieldMapResult result = new FieldMapResult();
        if (record == null || responseRoot == null || outputMappings == null) {
            return result;
        }

        Map<String, Schema.SObjectField> fieldMap = Schema.getGlobalDescribe()
            .get(objectApiName).getDescribe().fields.getMap();

        for (Amplemarket_Mapping__c m : outputMappings) {
            if (m.Is_Active__c != true) continue;
            String sfField = m.Salesforce_Field__c;
            String amField = m.Amplemarket_Field__c;
            if (String.isBlank(sfField) || String.isBlank(amField)) continue;

            FieldOutcome outcome = new FieldOutcome();
            outcome.salesforceField = sfField;
            outcome.amplemarketField = amField;

            Schema.SObjectField token = fieldMap.get(sfField.toLowerCase());
            if (token == null) {
                outcome.status = STATUS_ERROR;
                outcome.errorDetail = 'Unknown SF field: ' + sfField;
                result.warnings.add(outcome.errorDetail);
                result.fieldsSkipped++;
                result.outcomes.add(outcome);
                continue;
            }
            Schema.DescribeFieldResult dfr = token.getDescribe();
            outcome.salesforceLabel = dfr.getLabel();
            if (!dfr.isUpdateable()) {
                outcome.status = STATUS_ERROR;
                outcome.errorDetail = 'Field not updateable: ' + sfField;
                result.warnings.add(outcome.errorDetail);
                result.fieldsSkipped++;
                result.outcomes.add(outcome);
                continue;
            }

            Object existingVal = existing == null ? null : existing.get(token);
            outcome.oldValue = stringifyValue(existingVal);

            if (m.Update_Behavior__c == 'Only if Empty' && !isBlank(existingVal)) {
                outcome.status = STATUS_SKIPPED_POPULATED;
                result.fieldsSkipped++;
                result.outcomes.add(outcome);
                continue;
            }

            Object raw = readPath(responseRoot, amField);
            if (raw == null) {
                outcome.status = STATUS_SKIPPED_NO_VALUE;
                result.fieldsSkipped++;
                result.outcomes.add(outcome);
                continue;
            }

            try {
                Object coerced = coerce(raw, dfr);
                if (coerced != null) {
                    record.put(token, coerced);
                    outcome.newValue = stringifyValue(coerced);
                    outcome.status = STATUS_APPLIED;
                    result.fieldsApplied++;
                } else {
                    outcome.status = STATUS_SKIPPED_NO_VALUE;
                    result.fieldsSkipped++;
                }
            } catch (Exception e) {
                outcome.status = STATUS_ERROR;
                outcome.errorDetail = e.getMessage();
                outcome.newValue = stringifyValue(raw);
                result.warnings.add(sfField + ' <- ' + amField + ': ' + e.getMessage());
                result.fieldsSkipped++;
            }
            result.outcomes.add(outcome);
        }
        return result;
    }

    @TestVisible
    private static Boolean isBlank(Object v) {
        if (v == null) return true;
        if (v instanceof String) return String.isBlank((String) v);
        return false;
    }

    @TestVisible
    private static String stringifyValue(Object v) {
        if (v == null) return null;
        String s = String.valueOf(v);
        if (s != null && s.length() > 2048) s = s.substring(0, 2048);
        return s;
    }

    /**
     * Walk a JSON tree by dot-path. Supports:
     *   - nested keys:            `a.b.c`
     *   - fixed array index:      `a[0].b`
     *   - predicate array select: `a[key=value].b` — the first element of the `a`
     *     array whose `key` stringifies (case-insensitively) to `value`; if no
     *     element matches, falls back to the first element of the array. Used to
     *     pick a company's primary location: `locations[is_primary=true].address`.
     * Returns null if any segment is missing.
     */
    @TestVisible
    private static Object readPath(Object root, String path) {
        if (root == null || String.isBlank(path)) return null;
        Object node = root;
        for (String rawSeg : path.split('\\.')) {
            if (node == null) return null;
            String seg = rawSeg;
            // Handle bracket selector e.g. phone_numbers[0] or locations[is_primary=true]
            Integer idx = null;
            String predKey = null;
            String predVal = null;
            Integer lb = seg.indexOf('[');
            if (lb >= 0 && seg.endsWith(']')) {
                String sel = seg.substring(lb + 1, seg.length() - 1);
                seg = seg.substring(0, lb);
                Integer eq = sel.indexOf('=');
                if (eq >= 0) {
                    predKey = sel.substring(0, eq).trim();
                    predVal = sel.substring(eq + 1).trim();
                } else {
                    try { idx = Integer.valueOf(sel); } catch (Exception e) { return null; }
                }
            }
            if (node instanceof Map<String, Object>) {
                node = ((Map<String, Object>) node).get(seg);
            } else {
                return null;
            }
            if (idx != null) {
                if (node instanceof List<Object>) {
                    List<Object> arr = (List<Object>) node;
                    node = (idx >= 0 && idx < arr.size()) ? arr[idx] : null;
                } else {
                    return null;
                }
            } else if (predKey != null) {
                if (node instanceof List<Object>) {
                    node = selectByPredicate((List<Object>) node, predKey, predVal);
                } else {
                    return null;
                }
            }
        }
        return node;
    }

    /**
     * First array element whose `key` matches `value` (case-insensitive on the
     * stringified value, so `is_primary=true` matches a JSON boolean true). Falls
     * back to the first element when nothing matches; returns null for an empty list.
     */
    @TestVisible
    private static Object selectByPredicate(List<Object> arr, String key, String value) {
        if (arr == null || arr.isEmpty()) return null;
        for (Object el : arr) {
            if (el instanceof Map<String, Object>) {
                Object cand = ((Map<String, Object>) el).get(key);
                if (cand != null && String.valueOf(cand).equalsIgnoreCase(value)) {
                    return el;
                }
            }
        }
        return arr[0];
    }

    @TestVisible
    private static Object coerce(Object raw, Schema.DescribeFieldResult dfr) {
        if (raw == null) return null;
        Schema.DisplayType t = dfr.getType();

        if (t == Schema.DisplayType.STRING || t == Schema.DisplayType.TEXTAREA
                || t == Schema.DisplayType.URL || t == Schema.DisplayType.EMAIL
                || t == Schema.DisplayType.PHONE) {
            String s = String.valueOf(raw);
            Integer max = dfr.getLength();
            if (max != null && max > 0 && s != null && s.length() > max) {
                s = s.substring(0, max);
            }
            return s;
        }
        if (t == Schema.DisplayType.PICKLIST || t == Schema.DisplayType.MULTIPICKLIST) {
            String s = String.valueOf(raw);
            if (dfr.isRestrictedPicklist()) {
                Set<String> valid = new Set<String>();
                for (Schema.PicklistEntry pe : dfr.getPicklistValues()) {
                    if (pe.isActive()) valid.add(pe.getValue());
                }
                if (!valid.contains(s)) {
                    throw new HandledException('Value "' + s + '" not in restricted picklist');
                }
            }
            return s;
        }
        if (t == Schema.DisplayType.BOOLEAN) {
            if (raw instanceof Boolean) return (Boolean) raw;
            String s = String.valueOf(raw).toLowerCase();
            return s == 'true' || s == '1' || s == 'yes';
        }
        if (t == Schema.DisplayType.INTEGER) {
            return Integer.valueOf(String.valueOf(raw));
        }
        if (t == Schema.DisplayType.DOUBLE || t == Schema.DisplayType.CURRENCY
                || t == Schema.DisplayType.PERCENT) {
            return Double.valueOf(String.valueOf(raw));
        }
        if (t == Schema.DisplayType.DATE) {
            return Date.valueOf(String.valueOf(raw));
        }
        if (t == Schema.DisplayType.DATETIME) {
            // Accept ISO-8601 from Amplemarket
            return (Datetime) JSON.deserialize('"' + String.valueOf(raw) + '"', Datetime.class);
        }
        // Default: stringify
        return String.valueOf(raw);
    }

    public class HandledException extends Exception {}
}
