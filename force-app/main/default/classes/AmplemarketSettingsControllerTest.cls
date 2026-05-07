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
        List<AmplemarketMapping> rows = AmplemarketSettingsController.getMappings();
        System.assertEquals(0, rows.size());
    }

    @IsTest
    static void saveMappingsInsertsThenUpdatesThenDeletes() {
        AmplemarketMapping m1 = new AmplemarketMapping();
        m1.objectApiName = 'Lead';
        m1.mappingType = 'Match Input';
        m1.amplemarketField = 'email';
        m1.salesforceField = 'Email';
        m1.isActive = true;

        AmplemarketMapping m2 = new AmplemarketMapping();
        m2.objectApiName = 'Lead';
        m2.mappingType = 'Output Field';
        m2.amplemarketField = 'title';
        m2.salesforceField = 'Title';
        m2.isActive = true;

        Test.startTest();
        AmplemarketSaveResult res = AmplemarketSettingsController.saveMappings(JSON.serialize(new List<AmplemarketMapping>{ m1, m2 }));
        Test.stopTest();

        System.assertEquals(2, res.saved);
        System.assertEquals(0, res.skippedReasons.size());

        List<AmplemarketMapping> stored = AmplemarketSettingsController.getMappings();
        System.assertEquals(2, stored.size());

        AmplemarketMapping keep = stored[0];
        keep.salesforceField = 'FirstName';
        AmplemarketSaveResult res2 = AmplemarketSettingsController.saveMappings(JSON.serialize(new List<AmplemarketMapping>{ keep }));
        System.assertEquals(1, res2.saved);

        List<AmplemarketMapping> after = AmplemarketSettingsController.getMappings();
        System.assertEquals(1, after.size());
        System.assertEquals('FirstName', after[0].salesforceField);
    }

    @IsTest
    static void saveMappingsSkipsRowsWithBlankRequiredFields() {
        AmplemarketMapping good = new AmplemarketMapping();
        good.objectApiName = 'Lead';
        good.mappingType = 'Output Field';
        good.amplemarketField = 'title';
        good.salesforceField = 'Title';
        good.isActive = true;

        AmplemarketMapping bad = new AmplemarketMapping();
        bad.objectApiName = 'Lead';
        bad.mappingType = 'Output Field';
        bad.amplemarketField = '';
        bad.salesforceField = 'Title';
        bad.isActive = true;

        Test.startTest();
        AmplemarketSaveResult res = AmplemarketSettingsController.saveMappings(
            JSON.serialize(new List<AmplemarketMapping>{ good, bad })
        );
        Test.stopTest();

        System.assertEquals(1, res.saved);
        System.assertEquals(1, res.skippedReasons.size());
        System.assert(res.skippedReasons[0].contains('amplemarketField'));
        System.assertEquals(1, [SELECT COUNT() FROM Amplemarket_Mapping__c]);
    }

    @IsTest
    static void saveMappingsWithNullDeletesAll() {
        insert new Amplemarket_Mapping__c(
            Object_API_Name__c = 'Lead', Mapping_Type__c = 'Output Field',
            Amplemarket_Field__c = 'title', Salesforce_Field__c = 'Title', Is_Active__c = true);

        Test.startTest();
        AmplemarketSettingsController.saveMappings('[]');
        Test.stopTest();

        System.assertEquals(0, [SELECT COUNT() FROM Amplemarket_Mapping__c]);
    }
}
