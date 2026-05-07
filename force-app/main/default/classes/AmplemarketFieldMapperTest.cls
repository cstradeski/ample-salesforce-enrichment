@IsTest
private class AmplemarketFieldMapperTest {

    @IsTest
    static void readPathHandlesNestedAndArrayAccess() {
        Map<String, Object> root = (Map<String, Object>) JSON.deserializeUntyped(
            '{"company":{"industry":"SaaS"},"phone_numbers":[{"number":"+15551234"}]}'
        );
        System.assertEquals('SaaS', AmplemarketFieldMapper.readPath(root, 'company.industry'));
        System.assertEquals('+15551234', AmplemarketFieldMapper.readPath(root, 'phone_numbers[0].number'));
        System.assertEquals(null, AmplemarketFieldMapper.readPath(root, 'company.unknown'));
        System.assertEquals(null, AmplemarketFieldMapper.readPath(root, 'phone_numbers[5].number'));
    }

    @IsTest
    static void applyOutputsWritesMappedFields() {
        Lead lead = new Lead(LastName = 'Smith', Company = 'Acme', Email = 'a@b.com');
        insert lead;

        Map<String, Object> response = (Map<String, Object>) JSON.deserializeUntyped(
            '{"title":"VP of Engineering","first_name":"Anna","company":{"industry":"SaaS"}}'
        );
        List<Amplemarket_Mapping__c> mappings = new List<Amplemarket_Mapping__c>{
            new Amplemarket_Mapping__c(
                Object_API_Name__c = 'Lead', Mapping_Type__c = 'Output Field',
                Amplemarket_Field__c = 'title', Salesforce_Field__c = 'Title', Is_Active__c = true),
            new Amplemarket_Mapping__c(
                Object_API_Name__c = 'Lead', Mapping_Type__c = 'Output Field',
                Amplemarket_Field__c = 'first_name', Salesforce_Field__c = 'FirstName', Is_Active__c = true),
            new Amplemarket_Mapping__c(
                Object_API_Name__c = 'Lead', Mapping_Type__c = 'Output Field',
                Amplemarket_Field__c = 'company.industry', Salesforce_Field__c = 'Industry', Is_Active__c = true),
            new Amplemarket_Mapping__c(
                Object_API_Name__c = 'Lead', Mapping_Type__c = 'Output Field',
                Amplemarket_Field__c = 'unknown_path', Salesforce_Field__c = 'Title', Is_Active__c = true)
        };

        Lead toUpdate = new Lead(Id = lead.Id);
        AmplemarketFieldMapper.FieldMapResult res = AmplemarketFieldMapper.applyOutputs(
            toUpdate, lead, 'Lead', response, mappings
        );
        System.assertEquals('VP of Engineering', toUpdate.Title);
        System.assertEquals('Anna', toUpdate.FirstName);
        System.assertEquals('SaaS', toUpdate.Industry);
        System.assertEquals(3, res.fieldsApplied);
    }

    @IsTest
    static void applyOutputsSkipsInactiveMappings() {
        Lead lead = new Lead(LastName = 'X', Company = 'Y');
        insert lead;
        Map<String, Object> response = new Map<String, Object>{ 'title' => 'CTO' };
        List<Amplemarket_Mapping__c> mappings = new List<Amplemarket_Mapping__c>{
            new Amplemarket_Mapping__c(
                Object_API_Name__c = 'Lead', Mapping_Type__c = 'Output Field',
                Amplemarket_Field__c = 'title', Salesforce_Field__c = 'Title', Is_Active__c = false)
        };
        Lead toUpdate = new Lead(Id = lead.Id);
        AmplemarketFieldMapper.FieldMapResult res = AmplemarketFieldMapper.applyOutputs(
            toUpdate, lead, 'Lead', response, mappings
        );
        System.assertEquals(0, res.fieldsApplied);
        System.assertEquals(null, toUpdate.Title);
    }

    @IsTest
    static void onlyIfEmptySkipsNonBlankAndWritesBlank() {
        Lead populated = new Lead(LastName = 'X', Company = 'Y', Title = 'Existing Title', Industry = null);
        insert populated;

        Map<String, Object> response = (Map<String, Object>) JSON.deserializeUntyped(
            '{"title":"New Title","company":{"industry":"SaaS"}}'
        );
        List<Amplemarket_Mapping__c> mappings = new List<Amplemarket_Mapping__c>{
            new Amplemarket_Mapping__c(
                Object_API_Name__c = 'Lead', Mapping_Type__c = 'Output Field',
                Amplemarket_Field__c = 'title', Salesforce_Field__c = 'Title',
                Update_Behavior__c = 'Only if Empty', Is_Active__c = true),
            new Amplemarket_Mapping__c(
                Object_API_Name__c = 'Lead', Mapping_Type__c = 'Output Field',
                Amplemarket_Field__c = 'company.industry', Salesforce_Field__c = 'Industry',
                Update_Behavior__c = 'Only if Empty', Is_Active__c = true)
        };

        Lead toUpdate = new Lead(Id = populated.Id);
        Lead existing = [SELECT Id, Title, Industry FROM Lead WHERE Id = :populated.Id];
        AmplemarketFieldMapper.FieldMapResult res = AmplemarketFieldMapper.applyOutputs(
            toUpdate, existing, 'Lead', response, mappings
        );

        System.assertEquals(null, toUpdate.Title, 'Title was non-blank — should be skipped');
        System.assertEquals('SaaS', toUpdate.Industry, 'Industry was blank — should be written');
        System.assertEquals(1, res.fieldsApplied);
        System.assertEquals(1, res.fieldsSkipped);
    }

    @IsTest
    static void alwaysOverwritesEvenWhenPopulated() {
        Lead populated = new Lead(LastName = 'X', Company = 'Y', Title = 'Existing Title');
        insert populated;
        Map<String, Object> response = new Map<String, Object>{ 'title' => 'New Title' };
        List<Amplemarket_Mapping__c> mappings = new List<Amplemarket_Mapping__c>{
            new Amplemarket_Mapping__c(
                Object_API_Name__c = 'Lead', Mapping_Type__c = 'Output Field',
                Amplemarket_Field__c = 'title', Salesforce_Field__c = 'Title',
                Update_Behavior__c = 'Always', Is_Active__c = true)
        };
        Lead toUpdate = new Lead(Id = populated.Id);
        AmplemarketFieldMapper.applyOutputs(toUpdate, populated, 'Lead', response, mappings);
        System.assertEquals('New Title', toUpdate.Title);
    }

    @IsTest
    static void outcomesCaptureAppliedSkippedAndNoValue() {
        Lead populated = new Lead(LastName = 'X', Company = 'Y', Title = 'Existing', Industry = null);
        insert populated;
        Map<String, Object> response = (Map<String, Object>) JSON.deserializeUntyped(
            '{"title":"New","company":{"industry":"SaaS"}}'
        );
        List<Amplemarket_Mapping__c> mappings = new List<Amplemarket_Mapping__c>{
            new Amplemarket_Mapping__c(
                Object_API_Name__c = 'Lead', Mapping_Type__c = 'Output Field',
                Amplemarket_Field__c = 'title', Salesforce_Field__c = 'Title',
                Update_Behavior__c = 'Only if Empty', Is_Active__c = true),
            new Amplemarket_Mapping__c(
                Object_API_Name__c = 'Lead', Mapping_Type__c = 'Output Field',
                Amplemarket_Field__c = 'company.industry', Salesforce_Field__c = 'Industry',
                Update_Behavior__c = 'Always', Is_Active__c = true),
            new Amplemarket_Mapping__c(
                Object_API_Name__c = 'Lead', Mapping_Type__c = 'Output Field',
                Amplemarket_Field__c = 'unknown_path', Salesforce_Field__c = 'FirstName',
                Update_Behavior__c = 'Always', Is_Active__c = true)
        };
        Lead toUpdate = new Lead(Id = populated.Id);
        AmplemarketFieldMapper.FieldMapResult res = AmplemarketFieldMapper.applyOutputs(
            toUpdate, populated, 'Lead', response, mappings
        );

        System.assertEquals(3, res.outcomes.size());
        Map<String, AmplemarketFieldMapper.FieldOutcome> byField = new Map<String, AmplemarketFieldMapper.FieldOutcome>();
        for (AmplemarketFieldMapper.FieldOutcome o : res.outcomes) byField.put(o.salesforceField, o);

        System.assertEquals('Skipped - Already Populated', byField.get('Title').status);
        System.assertEquals('Existing', byField.get('Title').oldValue);

        System.assertEquals('Applied', byField.get('Industry').status);
        System.assertEquals('SaaS', byField.get('Industry').newValue);

        System.assertEquals('Skipped - No Value', byField.get('FirstName').status);
    }

    @IsTest
    static void coerceTruncatesLongStrings() {
        Schema.DescribeFieldResult dfr = Lead.Title.getDescribe();
        String longVal = '';
        for (Integer i = 0; i < dfr.getLength() + 50; i++) longVal += 'a';
        Object out = AmplemarketFieldMapper.coerce(longVal, dfr);
        System.assertEquals(dfr.getLength(), ((String) out).length());
    }
}
