@IsTest
private class AmplemarketMetadataDeployerTest {

    @IsTest
    static void deployRowsBuildsContainerWithoutEnqueueingInTests() {
        AmplemarketMetadataDeployer.Row r = new AmplemarketMetadataDeployer.Row();
        r.developerName = 'Test_Row';
        r.objectApiName = 'Lead';
        r.mappingType = 'Match Input';
        r.amplemarketField = 'email';
        r.salesforceField = 'Email';
        r.revealEmail = true;
        r.revealPhone = false;
        r.isActive = true;

        Test.startTest();
        Id jobId = AmplemarketMetadataDeployer.deployRows(new List<AmplemarketMetadataDeployer.Row>{ r });
        Test.stopTest();

        // Test guard short-circuits enqueueDeployment, so jobId is null but no exception thrown.
        System.assertEquals(null, jobId);
    }

    @IsTest
    static void deployRowsHandlesEmptyInput() {
        System.assertEquals(null, AmplemarketMetadataDeployer.deployRows(null));
        System.assertEquals(null, AmplemarketMetadataDeployer.deployRows(new List<AmplemarketMetadataDeployer.Row>()));
    }

    @IsTest
    static void callbackHandleResultIsCallable() {
        AmplemarketMetadataDeployer.AmplemarketDeployCallback cb = new AmplemarketMetadataDeployer.AmplemarketDeployCallback();
        cb.handleResult(null, null);
    }
}
