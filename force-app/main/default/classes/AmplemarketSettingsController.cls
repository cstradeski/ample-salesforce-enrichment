public with sharing class AmplemarketSettingsController {

    /**
     * Catalog returned to the LWC: per-object lists of (a) supported match-input keys
     * and (b) supported Amplemarket output fields, plus the SObject's writeable fields.
     */
    public class ObjectCatalog {
        @AuraEnabled public String objectApiName;
        @AuraEnabled public List<Map<String, String>> matchInputKeys;
        @AuraEnabled public List<Map<String, String>> outputFields;
        @AuraEnabled public List<Map<String, String>> sobjectFields;
    }

    public class Mapping {
        @AuraEnabled public String developerName;
        @AuraEnabled public String objectApiName;
        @AuraEnabled public String mappingType;
        @AuraEnabled public String amplemarketField;
        @AuraEnabled public String salesforceField;
        @AuraEnabled public Boolean revealEmail;
        @AuraEnabled public Boolean revealPhone;
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
        for (Amplemarket_Enrichment_Mapping__mdt m : [
            SELECT DeveloperName, Object_API_Name__c, Mapping_Type__c,
                   Amplemarket_Field__c, Salesforce_Field__c,
                   Reveal_Email__c, Reveal_Phone__c, Is_Active__c
            FROM Amplemarket_Enrichment_Mapping__mdt
            ORDER BY Object_API_Name__c, Mapping_Type__c, Amplemarket_Field__c
        ]) {
            Mapping mp = new Mapping();
            mp.developerName = m.DeveloperName;
            mp.objectApiName = m.Object_API_Name__c;
            mp.mappingType = m.Mapping_Type__c;
            mp.amplemarketField = m.Amplemarket_Field__c;
            mp.salesforceField = m.Salesforce_Field__c;
            mp.revealEmail = m.Reveal_Email__c;
            mp.revealPhone = m.Reveal_Phone__c;
            mp.isActive = m.Is_Active__c;
            out.add(mp);
        }
        return out;
    }

    @AuraEnabled
    public static Id saveMappings(List<Mapping> mappings) {
        if (!FeatureManagement.checkPermission('Manage_Amplemarket_Settings') && !isAdmin()) {
            throw new AuraHandledException('You do not have permission to manage Amplemarket settings.');
        }
        if (mappings == null || mappings.isEmpty()) {
            throw new AuraHandledException('No mappings supplied.');
        }
        List<AmplemarketMetadataDeployer.Row> rows = new List<AmplemarketMetadataDeployer.Row>();
        Set<String> seen = new Set<String>();
        for (Mapping m : mappings) {
            AmplemarketMetadataDeployer.Row r = new AmplemarketMetadataDeployer.Row();
            r.developerName = String.isNotBlank(m.developerName) ? m.developerName : buildDevName(m, seen);
            r.label = m.objectApiName + ' / ' + m.mappingType + ' / ' + m.amplemarketField;
            if (r.label.length() > 40) r.label = r.label.substring(0, 40);
            r.objectApiName = m.objectApiName;
            r.mappingType = m.mappingType;
            r.amplemarketField = m.amplemarketField;
            r.salesforceField = m.salesforceField;
            r.revealEmail = m.revealEmail;
            r.revealPhone = m.revealPhone;
            r.isActive = m.isActive == null ? true : m.isActive;
            rows.add(r);
        }
        return AmplemarketMetadataDeployer.deployRows(rows);
    }

    @AuraEnabled
    public static String getDeploymentStatus(Id jobId) {
        if (jobId == null) return 'Unknown';
        // Tooling API would be the canonical way; admins can check Setup → Deployment Status.
        // We return a hint for the LWC to poll the standard Async Apex job table for context.
        List<AsyncApexJob> jobs = [
            SELECT Id, Status, ExtendedStatus
            FROM AsyncApexJob
            WHERE Id = :jobId
            LIMIT 1
        ];
        return jobs.isEmpty() ? 'Pending' : jobs[0].Status;
    }

    private static String buildDevName(Mapping m, Set<String> seen) {
        String base = (m.objectApiName + '_' + m.mappingType + '_' + m.amplemarketField)
            .replaceAll('[^A-Za-z0-9_]', '_')
            .replaceAll('_+', '_');
        if (base.length() > 35) base = base.substring(0, 35);
        String name = base;
        Integer i = 1;
        while (seen.contains(name)) {
            name = base + '_' + i++;
        }
        seen.add(name);
        return name;
    }

    private static Boolean isAdmin() {
        return [SELECT Id FROM PermissionSetAssignment
                WHERE AssigneeId = :UserInfo.getUserId()
                  AND PermissionSet.Name = 'Amplemarket_Admin'
                LIMIT 1].size() > 0;
    }
}
