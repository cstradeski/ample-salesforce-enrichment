public with sharing class AmplemarketHttpClient {

    public static final String NAMED_CREDENTIAL = 'callout:Amplemarket_API';
    public static final Integer DEFAULT_TIMEOUT_MS = 60000;

    public class CalloutException extends Exception {}

    public class Result {
        public Integer statusCode;
        public String status;
        public String body;
        public Map<String, String> headers;
        public Boolean isSuccess() {
            return statusCode != null && statusCode >= 200 && statusCode < 300;
        }
    }

    public Result get(String path, Map<String, String> queryParams) {
        return send('GET', path, queryParams, null);
    }

    public Result post(String path, Object body) {
        return send('POST', path, null, body);
    }

    public Result del(String path) {
        return send('DELETE', path, null, null);
    }

    private Result send(String method, String path, Map<String, String> queryParams, Object body) {
        HttpRequest req = new HttpRequest();
        req.setEndpoint(NAMED_CREDENTIAL + path + buildQuery(queryParams));
        req.setMethod(method);
        req.setTimeout(DEFAULT_TIMEOUT_MS);
        req.setHeader('Accept', 'application/json');
        if (body != null) {
            req.setHeader('Content-Type', 'application/json');
            req.setBody(JSON.serialize(body, true));
        }

        HttpResponse res;
        try {
            res = new Http().send(req);
        } catch (System.CalloutException ce) {
            throw new CalloutException('Amplemarket callout failed: ' + ce.getMessage(), ce);
        }

        Result r = new Result();
        r.statusCode = res.getStatusCode();
        r.status = res.getStatus();
        r.body = res.getBody();
        r.headers = new Map<String, String>();
        for (String h : res.getHeaderKeys()) {
            r.headers.put(h, res.getHeader(h));
        }
        return r;
    }

    @TestVisible
    private static String buildQuery(Map<String, String> params) {
        if (params == null || params.isEmpty()) {
            return '';
        }
        List<String> parts = new List<String>();
        for (String key : params.keySet()) {
            String v = params.get(key);
            if (String.isBlank(v)) continue;
            parts.add(EncodingUtil.urlEncode(key, 'UTF-8') + '=' + EncodingUtil.urlEncode(v, 'UTF-8'));
        }
        return parts.isEmpty() ? '' : '?' + String.join(parts, '&');
    }
}
