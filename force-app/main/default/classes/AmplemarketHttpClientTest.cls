@IsTest
private class AmplemarketHttpClientTest {

    private class StubMock implements HttpCalloutMock {
        Integer status;
        String body;
        public StubMock(Integer s, String b) { status = s; body = b; }
        public HttpResponse respond(HttpRequest req) {
            HttpResponse res = new HttpResponse();
            res.setStatusCode(status);
            res.setStatus('OK');
            res.setBody(body);
            res.setHeader('Content-Type', 'application/json');
            return res;
        }
    }

    @IsTest
    static void buildQueryEncodesAndJoins() {
        Map<String, String> p = new Map<String, String>{
            'email' => 'a@b.com',
            'name' => 'John Doe',
            'empty' => null
        };
        String q = AmplemarketHttpClient.buildQuery(p);
        System.assert(q.startsWith('?'), 'Expected leading ?: ' + q);
        System.assert(q.contains('email=a%40b.com'), 'Email not encoded: ' + q);
        System.assert(q.contains('name=John+Doe') || q.contains('name=John%20Doe'), 'Name not encoded: ' + q);
        System.assert(!q.contains('empty='), 'Blank values should be skipped');
    }

    @IsTest
    static void getReturnsParsedResult() {
        Test.setMock(HttpCalloutMock.class, new StubMock(200, '{"id":"abc"}'));
        Test.startTest();
        AmplemarketHttpClient.Result r = new AmplemarketHttpClient().get('/people/find', new Map<String, String>{ 'email' => 'a@b.com' });
        Test.stopTest();
        System.assertEquals(200, r.statusCode);
        System.assert(r.isSuccess());
        System.assertEquals('{"id":"abc"}', r.body);
    }

    @IsTest
    static void postSerializesBody() {
        Test.setMock(HttpCalloutMock.class, new StubMock(202, '{"ok":true}'));
        Test.startTest();
        AmplemarketHttpClient.Result r = new AmplemarketHttpClient().post('/x', new Map<String, Object>{ 'a' => 1 });
        Test.stopTest();
        System.assertEquals(202, r.statusCode);
    }

    @IsTest
    static void delReturnsResult() {
        Test.setMock(HttpCalloutMock.class, new StubMock(204, ''));
        Test.startTest();
        AmplemarketHttpClient.Result r = new AmplemarketHttpClient().del('/x');
        Test.stopTest();
        System.assertEquals(204, r.statusCode);
    }
}
