@IsTest
private class AmplemarketRevealDefaultsTest {

    @IsTest
    static void returnsSettingsDefaultsPerRequest() {
        Lead l = new Lead(LastName = 'A', Company = 'C');
        insert l;
        insert new Amplemarket_Mapping__c(
            Object_API_Name__c = 'Lead', Mapping_Type__c = 'Match Input',
            Amplemarket_Field__c = 'linkedin_url', Salesforce_Field__c = 'Website',
            Reveal_Email__c = true, Reveal_Phone__c = false, Is_Active__c = true);

        AmplemarketRevealDefaults.Request r = new AmplemarketRevealDefaults.Request();
        r.recordId = l.Id;
        r.objectApiName = 'Lead';

        List<AmplemarketRevealDefaults.Response> out = AmplemarketRevealDefaults.getDefaults(
            new List<AmplemarketRevealDefaults.Request>{ r });

        System.assertEquals(1, out.size());
        System.assertEquals(true, out[0].isPerson);
        System.assertEquals(true, out[0].revealEmailDefault);
        System.assertEquals(false, out[0].revealPhoneDefault);
    }

    @IsTest
    static void companyObjectReportsNoReveals() {
        Account a = new Account(Name = 'Acme');
        insert a;
        AmplemarketRevealDefaults.Request r = new AmplemarketRevealDefaults.Request();
        r.recordId = a.Id;
        r.objectApiName = 'Account';

        List<AmplemarketRevealDefaults.Response> out = AmplemarketRevealDefaults.getDefaults(
            new List<AmplemarketRevealDefaults.Request>{ r });

        System.assertEquals(false, out[0].isPerson);
        System.assertEquals(false, out[0].revealEmailDefault);
        System.assertEquals(false, out[0].revealPhoneDefault);
    }

    @IsTest
    static void emptyInputReturnsEmpty() {
        System.assertEquals(0, AmplemarketRevealDefaults.getDefaults(null).size());
    }
}
