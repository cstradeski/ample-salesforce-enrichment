public with sharing class AmplemarketMetadataDeployer {

    private static final String CMDT_TYPE = 'Amplemarket_Enrichment_Mapping__mdt';

    public class Row {
        public String developerName;
        public String label;
        public String objectApiName;
        public String mappingType;
        public String amplemarketField;
        public String salesforceField;
        public Boolean revealEmail;
        public Boolean revealPhone;
        public Boolean isActive;
    }

    /**
     * Upsert the supplied rows as records of Amplemarket_Enrichment_Mapping__mdt
     * via the Apex Metadata API. Returns a deployment job id the LWC can poll.
     */
    public static Id deployRows(List<Row> rows) {
        if (rows == null || rows.isEmpty()) return null;

        Metadata.DeployContainer container = new Metadata.DeployContainer();
        for (Row r : rows) {
            container.addMetadata(toCustomMetadata(r));
        }

        AmplemarketDeployCallback cb = new AmplemarketDeployCallback();
        if (Test.isRunningTest()) {
            // Don't actually enqueue during tests
            return null;
        }
        return Metadata.Operations.enqueueDeployment(container, cb);
    }

    private static Metadata.CustomMetadata toCustomMetadata(Row r) {
        Metadata.CustomMetadata md = new Metadata.CustomMetadata();
        md.fullName = CMDT_TYPE + '.' + r.developerName;
        md.label = String.isBlank(r.label) ? r.developerName : r.label;

        md.values.add(makeValue('Object_API_Name__c', r.objectApiName));
        md.values.add(makeValue('Mapping_Type__c', r.mappingType));
        md.values.add(makeValue('Amplemarket_Field__c', r.amplemarketField));
        md.values.add(makeValue('Salesforce_Field__c', r.salesforceField));
        md.values.add(makeValue('Reveal_Email__c', r.revealEmail == true));
        md.values.add(makeValue('Reveal_Phone__c', r.revealPhone == true));
        md.values.add(makeValue('Is_Active__c', r.isActive == null ? true : r.isActive));
        return md;
    }

    private static Metadata.CustomMetadataValue makeValue(String field, Object val) {
        Metadata.CustomMetadataValue v = new Metadata.CustomMetadataValue();
        v.field = field;
        v.value = val;
        return v;
    }

    public class AmplemarketDeployCallback implements Metadata.DeployCallback {
        public void handleResult(Metadata.DeployResult result, Metadata.DeployCallbackContext ctx) {
            // Nothing to do — the LWC polls via getDeploymentStatus.
        }
    }
}
