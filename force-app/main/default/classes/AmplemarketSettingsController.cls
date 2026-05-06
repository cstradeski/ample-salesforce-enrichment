public with sharing class AmplemarketSettingsController {

    public class ObjectCatalog {
        @AuraEnabled public String objectApiName;
        @AuraEnabled public List<Map<String, String>> matchInputKeys;
        @AuraEnabled public List<Map<String, String>> outputFields;
        @AuraEnabled public List<Map<String, String>> sobjectFields;
    }

    public class Mapping {
        @AuraEnabled public Id id;
        @AuraEnabled public String objectApiName;
        @AuraEnabled public String mappingType;
        @AuraEnabled public String amplemarketField;
        @AuraEnabled public String salesforceField;
        @AuraEnabled public Boolean revealEmail;
        @AuraEnabled public Boolean revealPhone;
        @AuraEnabled public String updateBehavior;
        @AuraEnabled public Boolean isActive;
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
    public static List<Mapping> getMappings() {
        List<Mapping> out = new List<Mapping>();
        for (Amplemarket_Mapping__c m : [
            SELECT Id, Object_API_Name__c, Mapping_Type__c,
                   Amplemarket_Field__c, Salesforce_Field__c,
                   Reveal_Email__c, Reveal_Phone__c,
                   Update_Behavior__c, Is_Active__c
            FROM Amplemarket_Mapping__c
            ORDER BY Object_API_Name__c, Mapping_Type__c, Amplemarket_Field__c
        ]) {
            Mapping mp = new Mapping();
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

    /**
     * Replaces all stored mappings with the supplied list. Inserts new rows,
     * updates existing rows by Id, and deletes any pre-existing rows the caller
     * did not include.
     */
    @AuraEnabled
    public static void saveMappings(List<Mapping> mappings) {
        if (!Schema.SObjectType.Amplemarket_Mapping__c.isUpdateable()) {
            throw new AuraHandledException('You do not have edit access to Amplemarket Mappings.');
        }
        if (mappings == null) mappings = new List<Mapping>();

        Map<Id, Amplemarket_Mapping__c> existing = new Map<Id, Amplemarket_Mapping__c>(
            [SELECT Id FROM Amplemarket_Mapping__c]
        );

        List<Amplemarket_Mapping__c> toUpsert = new List<Amplemarket_Mapping__c>();
        Set<Id> keepIds = new Set<Id>();

        for (Mapping m : mappings) {
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
    }
}
