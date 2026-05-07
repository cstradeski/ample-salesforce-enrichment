public with sharing class AmplemarketSettingsController {

    public class ObjectCatalog {
        @AuraEnabled public String objectApiName;
        @AuraEnabled public List<Map<String, String>> matchInputKeys;
        @AuraEnabled public List<Map<String, String>> outputFields;
        @AuraEnabled public List<Map<String, String>> sobjectFields;
    }

    @AuraEnabled(cacheable=true)
    public static List<ObjectCatalog> getCatalog() {
        List<ObjectCatalog> catalogs = new List<ObjectCatalog>();
        for (String obj : new List<String>{ AmplemarketDTO.OBJECT_LEAD,
                                            AmplemarketDTO.OBJECT_CONTACT,
                                            AmplemarketDTO.OBJECT_ACCOUNT }) {
            catalogs.add(buildCatalog(obj));
        }
        return catalogs;
    }

    private static ObjectCatalog buildCatalog(String objApi) {
        ObjectCatalog c = new ObjectCatalog();
        c.objectApiName = objApi;

        c.matchInputKeys = new List<Map<String, String>>();
        for (String k : AmplemarketDTO.matchKeysFor(objApi)) {
            c.matchInputKeys.add(new Map<String, String>{ 'value' => k, 'label' => k });
        }

        c.outputFields = new List<Map<String, String>>();
        Map<String, String> outs = AmplemarketDTO.outputCatalogFor(objApi);
        for (String key : outs.keySet()) {
            c.outputFields.add(new Map<String, String>{
                'value' => key,
                'label' => outs.get(key) + ' (' + key + ')'
            });
        }

        c.sobjectFields = new List<Map<String, String>>();
        Schema.SObjectType t = Schema.getGlobalDescribe().get(objApi);
        if (t != null) {
            for (Schema.SObjectField f : t.getDescribe().fields.getMap().values()) {
                Schema.DescribeFieldResult dfr = f.getDescribe();
                if (!dfr.isUpdateable()) continue;
                c.sobjectFields.add(new Map<String, String>{
                    'value' => dfr.getName(),
                    'label' => dfr.getLabel() + ' (' + dfr.getName() + ')'
                });
            }
        }
        return c;
    }

    @AuraEnabled(cacheable=false)
    public static List<AmplemarketMapping> getMappings() {
        List<AmplemarketMapping> out = new List<AmplemarketMapping>();
        for (Amplemarket_Mapping__c m : [
            SELECT Id, Object_API_Name__c, Mapping_Type__c,
                   Amplemarket_Field__c, Salesforce_Field__c,
                   Reveal_Email__c, Reveal_Phone__c,
                   Update_Behavior__c, Is_Active__c
            FROM Amplemarket_Mapping__c
            ORDER BY Object_API_Name__c, Mapping_Type__c, Amplemarket_Field__c
        ]) {
            AmplemarketMapping mp = new AmplemarketMapping();
            mp.id = m.Id;
            mp.objectApiName = m.Object_API_Name__c;
            mp.mappingType = m.Mapping_Type__c;
            mp.amplemarketField = m.Amplemarket_Field__c;
            mp.salesforceField = m.Salesforce_Field__c;
            mp.revealEmail = m.Reveal_Email__c;
            mp.revealPhone = m.Reveal_Phone__c;
            mp.updateBehavior = m.Update_Behavior__c;
            mp.isActive = m.Is_Active__c;
            out.add(mp);
        }
        return out;
    }

    @AuraEnabled
    public static AmplemarketSaveResult saveMappings(String mappingsJson) {
        if (!Schema.SObjectType.Amplemarket_Mapping__c.isUpdateable()) {
            throw new AuraHandledException('You do not have edit access to Amplemarket Mappings.');
        }
        List<AmplemarketMapping> mappings;
        if (String.isBlank(mappingsJson)) {
            mappings = new List<AmplemarketMapping>();
        } else {
            try {
                mappings = (List<AmplemarketMapping>) JSON.deserialize(
                    mappingsJson, List<AmplemarketMapping>.class
                );
            } catch (Exception e) {
                throw new AuraHandledException('Could not parse mappings JSON: ' + e.getMessage());
            }
        }

        Map<Id, Amplemarket_Mapping__c> existing = new Map<Id, Amplemarket_Mapping__c>(
            [SELECT Id FROM Amplemarket_Mapping__c]
        );

        List<Amplemarket_Mapping__c> toUpsert = new List<Amplemarket_Mapping__c>();
        Set<Id> keepIds = new Set<Id>();
        AmplemarketSaveResult result = new AmplemarketSaveResult();
        result.skippedReasons = new List<String>();

        for (Integer i = 0; i < mappings.size(); i++) {
            AmplemarketMapping m = mappings[i];
            List<String> missing = new List<String>();
            if (String.isBlank(m.objectApiName)) missing.add('objectApiName');
            if (String.isBlank(m.mappingType)) missing.add('mappingType');
            if (String.isBlank(m.amplemarketField)) missing.add('amplemarketField');
            if (String.isBlank(m.salesforceField)) missing.add('salesforceField');

            if (!missing.isEmpty()) {
                result.skippedReasons.add('row[' + i + '] '
                    + (m.objectApiName == null ? '?' : m.objectApiName) + '/'
                    + (m.mappingType == null ? '?' : m.mappingType) + '/'
                    + (m.amplemarketField == null ? '?' : m.amplemarketField) + '/'
                    + (m.salesforceField == null ? '?' : m.salesforceField)
                    + ' missing: ' + String.join(missing, ','));
                continue;
            }
            Amplemarket_Mapping__c row = new Amplemarket_Mapping__c(
                Object_API_Name__c = m.objectApiName,
                Mapping_Type__c = m.mappingType,
                Amplemarket_Field__c = m.amplemarketField,
                Salesforce_Field__c = m.salesforceField,
                Reveal_Email__c = m.revealEmail == true,
                Reveal_Phone__c = m.revealPhone == true,
                Update_Behavior__c = String.isBlank(m.updateBehavior) ? 'Always' : m.updateBehavior,
                Is_Active__c = m.isActive == null ? true : m.isActive
            );
            if (m.id != null) {
                row.Id = m.id;
                keepIds.add(m.id);
            }
            toUpsert.add(row);
        }

        List<Amplemarket_Mapping__c> toDelete = new List<Amplemarket_Mapping__c>();
        for (Id existingId : existing.keySet()) {
            if (!keepIds.contains(existingId)) toDelete.add(existing.get(existingId));
        }

        Savepoint sp = Database.setSavepoint();
        try {
            if (!toUpsert.isEmpty()) upsert toUpsert;
            if (!toDelete.isEmpty()) delete toDelete;
        } catch (DmlException de) {
            Database.rollback(sp);
            throw new AuraHandledException('Could not save mappings: ' + de.getDmlMessage(0));
        }
        result.saved = toUpsert.size();
        return result;
    }
}
