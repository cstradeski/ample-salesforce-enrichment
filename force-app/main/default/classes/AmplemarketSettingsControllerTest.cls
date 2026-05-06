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
            System.assert(c.matchInputKeys.size() > 0, c.objectApiName + ' should have match keys');
            System.assert(c.outputFields.size() > 0, c.objectApiName + ' should have output fields');
            System.assert(c.sobjectFields.size() > 0, c.objectApiName + ' should have describable fields');
        }
    }

    @IsTest
    static void getMappingsReturnsEmptyByDefault() {
        // No CMDT records seeded — should return empty without throwing.
        List<AmplemarketSettingsController.Mapping> rows = AmplemarketSettingsController.getMappings();
        System.assertNotEquals(null, rows);
    }

    @IsTest
    static void saveMappingsRequiresPayload() {
        Boolean threw = false;
        try {
            AmplemarketSettingsController.saveMappings(new List<AmplemarketSettingsController.Mapping>());
        } catch (AuraHandledException e) {
            threw = true;
        }
        System.assert(threw, 'Empty list should error');
    }

    @IsTest
    static void getDeploymentStatusHandlesUnknownJob() {
        System.assertEquals('Unknown', AmplemarketSettingsController.getDeploymentStatus(null));
    }
}
