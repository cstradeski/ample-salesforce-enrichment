public with sharing class AmplemarketFieldMapper {

    public class FieldMapResult {
        public Integer fieldsApplied = 0;
        public Integer fieldsSkipped = 0;
        public List<String> warnings = new List<String>();
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

            Schema.SObjectField token = fieldMap.get(sfField.toLowerCase());
            if (token == null) {
                result.warnings.add('Unknown SF field: ' + sfField);
                result.fieldsSkipped++;
                continue;
            }
            Schema.DescribeFieldResult dfr = token.getDescribe();
            if (!dfr.isUpdateable()) {
                result.warnings.add('Field not updateable: ' + sfField);
                result.fieldsSkipped++;
                continue;
            }

            if (m.Update_Behavior__c == 'Only if Empty' && existing != null
                    && !isBlank(existing.get(token))) {
                result.fieldsSkipped++;
                continue;
            }

            Object raw = readPath(responseRoot, amField);
            if (raw == null) {
                result.fieldsSkipped++;
                continue;
            }

            try {
                Object coerced = coerce(raw, dfr);
                if (coerced != null) {
                    record.put(token, coerced);
                    result.fieldsApplied++;
                } else {
                    result.fieldsSkipped++;
                }
            } catch (Exception e) {
                result.warnings.add(sfField + ' <- ' + amField + ': ' + e.getMessage());
                result.fieldsSkipped++;
            }
        }
        return result;
    }

    @TestVisible
    private static Boolean isBlank(Object v) {
        if (v == null) return true;
        if (v instanceof String) return String.isBlank((String) v);
        return false;
    }

    /**
     * Walk a JSON tree by dot-path. Supports `a.b.c` and indexed array access `a[0].b`.
     * Returns null if any segment is missing.
     */
    @TestVisible
    private static Object readPath(Object root, String path) {
        if (root == null || String.isBlank(path)) return null;
        Object node = root;
        for (String rawSeg : path.split('\\.')) {
            if (node == null) return null;
            String seg = rawSeg;
            // Handle bracket-index e.g. phone_numbers[0]
            Integer idx = null;
            Integer lb = seg.indexOf('[');
            if (lb >= 0 && seg.endsWith(']')) {
                String idxStr = seg.substring(lb + 1, seg.length() - 1);
                try { idx = Integer.valueOf(idxStr); } catch (Exception e) { return null; }
                seg = seg.substring(0, lb);
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
            }
        }
        return node;
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
