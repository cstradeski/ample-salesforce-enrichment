@IsTest
private class AmplemarketDTOTest {
    @IsTest
    static void categorisesObjectsAndCatalogs() {
        System.assert(AmplemarketDTO.isPersonObject('Lead'));
        System.assert(AmplemarketDTO.isPersonObject('Contact'));
        System.assert(!AmplemarketDTO.isPersonObject('Account'));
        System.assert(AmplemarketDTO.isCompanyObject('Account'));

        System.assert(AmplemarketDTO.matchKeysFor('Lead').contains('email'));
        System.assert(AmplemarketDTO.matchKeysFor('Account').contains('domain'));
        System.assert(AmplemarketDTO.matchKeysFor('Opportunity').isEmpty());

        System.assert(AmplemarketDTO.outputCatalogFor('Lead').containsKey('title'));
        System.assert(AmplemarketDTO.outputCatalogFor('Account').containsKey('founded_year'));
        System.assert(AmplemarketDTO.outputCatalogFor('Other').isEmpty());
    }
}
