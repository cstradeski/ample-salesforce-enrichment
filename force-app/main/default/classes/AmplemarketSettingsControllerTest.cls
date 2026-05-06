@IsTest
private class AmplemarketSettingsControllerTest {

    @IsTest
    static void getCatalogReturnsThreeObjects() {
        List<AmplemarketSettingsController.ObjectCatalog> catalogs = AmplemarketSettingsController.getCatalog();
        System.assertEquals(3, catalogs.size());
        Set<String> names = new Set<String>();
        for (AmplemarketSettingsController.ObjectCatalog c : catalogs) names.add(c.objectApiName);
        System.assert(names.contains('Lead'));
        System.assert(names.contains('Contact'));
        System.assert(names.contains('Account'));
        for (AmplemarketSettingsController.ObjectCatalog c : catalogs) {
            System.assert(c.matchInputKeys.size() > 0);
            System.assert(c.outputFields.size() > 0);
            System.assert(c.sobjectFields.size() > 0);
        }
    }

    @IsTest
    static void getMappingsReturnsEmptyByDefault() {
        List<AmplemarketSettingsController.Mapping> rows = AmplemarketSettingsController.getMappings();
        System.assertEquals(0, rows.size());
    }

    @IsTest
    static void saveMappingsInsertsThenUpdatesThenDeletes() {
        // Insert two rows
        AmplemarketSettingsController.Mapping m1 = new AmplemarketSettingsController.Mapping();
        m1.objectApiName = 'Lead';
        m1.mappingType = 'Match Input';
        m1.amplemarketField = 'email';
        m1.salesforceField = 'Email';
        m1.isActive = true;

        AmplemarketSettingsController.Mapping m2 = new AmplemarketSettingsController.Mapping();
        m2.objectApiName = 'Lead';
        m2.mappingType = 'Output Field';
        m2.amplemarketField = 'title';
        m2.salesforceField = 'Title';
        m2.isActive = true;

        Test.startTest();
        AmplemarketSettingsController.saveMappings(new List<AmplemarketSettingsController.Mapping>{ m1, m2 });
        Test.stopTest();

        List<AmplemarketSettingsController.Mapping> stored = AmplemarketSettingsController.getMappings();
        System.assertEquals(2, stored.size());

        // Update one (change SF field), drop the other
        AmplemarketSettingsController.Mapping keep = stored[0];
        keep.salesforceField = 'FirstName';
        AmplemarketSettingsController.saveMappings(new List<AmplemarketSettingsController.Mapping>{ keep });

        List<AmplemarketSettingsController.Mapping> after = AmplemarketSettingsController.getMappings();
        System.assertEquals(1, after.size());
        System.assertEquals('FirstName', after[0].salesforceField);
    }

    @IsTest
    static void saveMappingsWithNullDeletesAll() {
        insert new Amplemarket_Mapping__c(
            Object_API_Name__c = 'Lead', Mapping_Type__c = 'Output Field',
            Amplemarket_Field__c = 'title', Salesforce_Field__c = 'Title', Is_Active__c = true);

        Test.startTest();
        AmplemarketSettingsController.saveMappings(null);
        Test.stopTest();

        System.assertEquals(0, [SELECT COUNT() FROM Amplemarket_Mapping__c]);
    }
}
