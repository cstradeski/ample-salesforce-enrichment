@IsTest
private class AmplemarketCreditPreviewTest {

    @IsTest
    static void invocableReturnsResponseForEachRequest() {
        Lead l1 = new Lead(LastName = 'A', Company = 'X', Email = 'a@x.com');
        Lead l2 = new Lead(LastName = 'B', Company = 'Y', Email = 'b@y.com');
        insert new List<Lead>{ l1, l2 };
        insert new Amplemarket_Mapping__c(
            Object_API_Name__c = 'Lead', Mapping_Type__c = 'Match Input',
            Amplemarket_Field__c = 'email', Salesforce_Field__c = 'Email',
            Reveal_Email__c = false, Reveal_Phone__c = true, Is_Active__c = true);

        AmplemarketCreditPreview.Request r1 = new AmplemarketCreditPreview.Request();
        r1.recordId = l1.Id; r1.objectApiName = 'Lead';
        AmplemarketCreditPreview.Request r2 = new AmplemarketCreditPreview.Request();
        r2.recordId = l2.Id; r2.objectApiName = 'Lead';

        List<AmplemarketCreditPreview.Response> out = AmplemarketCreditPreview.previewCredits(
            new List<AmplemarketCreditPreview.Request>{ r1, r2 });

        System.assertEquals(2, out.size());
        for (AmplemarketCreditPreview.Response resp : out) {
            System.assertEquals(true, resp.hasMappings);
            // email match + reveal_phone -> 0.5 + 1.0 = 1.5
            System.assertEquals(1.5, resp.worstCase);
            System.assert(resp.summaryHtml.contains('credits'), resp.summaryHtml);
        }
    }

    @IsTest
    static void invocableHandlesEmptyRequestList() {
        List<AmplemarketCreditPreview.Response> out = AmplemarketCreditPreview.previewCredits(null);
        System.assertEquals(0, out.size());
    }
}
