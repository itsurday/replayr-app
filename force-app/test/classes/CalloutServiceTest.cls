@IsTest
private with sharing class CalloutServiceTest {
    private static final String CREDENTIAL_ERROR = 'Named Credential name';
    private static final String METHOD_ERROR = 'method must be';
    private static final String PATH_ERROR = 'path must start';

    private class EchoMock implements HttpCalloutMock {
        public HttpRequest received;

        public HttpResponse respond(HttpRequest request) {
            received = request;
            HttpResponse response = new HttpResponse();
            response.setStatusCode(200);
            response.setBody('{"ok":true}');
            return response;
        }
    }

    private static Endpoint__c endpoint(String credential, String method, String path) {
        return new Endpoint__c(
            Method__c = method,
            Path__c = path,
            Provider__r = new Provider__c(Named_Credential__c = credential)
        );
    }

    private static String rejectionMessage(Endpoint__c endpoint) {
        try {
            CalloutService.buildRequest(endpoint, null);
        } catch (CalloutService.InvalidEndpointException e) {
            return e.getMessage();
        }
        return null;
    }

    private static void assertAllRejected(List<Endpoint__c> endpoints, String expectedFragment) {
        for (Endpoint__c e : endpoints) {
            String message = rejectionMessage(e);
            Assert.isNotNull(message, 'Expected rejection for ' + e);
            Assert.isTrue(message.contains(expectedFragment), 'Unexpected message for ' + e + ': ' + message);
        }
    }

    private static String urlFor(String path) {
        return CalloutService.buildRequest(endpoint('Httpbin_API', 'GET', path), null).getEndpoint();
    }

    @IsTest
    static void buildsCalloutUrlFromNamedCredentialAndPath() {
        HttpRequest request = CalloutService.buildRequest(endpoint('Httpbin_API', 'GET', '/get'), null);

        Assert.areEqual('callout:Httpbin_API/get', request.getEndpoint(), 'Endpoint URL');
        Assert.areEqual('GET', request.getMethod(), 'Method');
        Assert.areEqual('', request.getBody(), 'No body when none given');
        Assert.isNull(request.getHeader('Content-Type'), 'No content type without a body');
    }

    private static Endpoint__c withHeader(String header) {
        Endpoint__c e = endpoint('Httpbin_API', 'POST', '/x');
        e.Idempotency_Header__c = header;
        return e;
    }

    private static String keyRejection(Endpoint__c endpoint, String key) {
        try {
            CalloutService.buildRequest(endpoint, null, key);
        } catch (CalloutService.InvalidEndpointException e) {
            return e.getMessage();
        }
        return null;
    }

    @IsTest
    static void addsTheIdempotencyHeaderOnlyWhenNamed() {
        String key = '3f2b9c1e-0000-4000-8000-000000000001';
        HttpRequest named = CalloutService.buildRequest(withHeader('X-Idempotency-Key'), '{}', key);
        HttpRequest unnamed = CalloutService.buildRequest(withHeader(null), '{}', key);

        Assert.areEqual(key, named.getHeader('X-Idempotency-Key'), 'Key in the named header');
        Assert.isNull(unnamed.getHeader('X-Idempotency-Key'), 'No header named, no key sent');
        Assert.isNull(keyRejection(withHeader(' '), null), 'A blank header name sends nothing and needs no key');
        Assert.isNull(keyRejection(withHeader('x'.repeat(80)), 'k'.repeat(36)), 'Longest header name and key accepted');
        Assert.isNull(keyRejection(withHeader('Authorization-Key'), key), 'A name that only starts like a reserved one is fine');
    }

    @IsTest
    static void rejectsUnsafeHeaderNamesAndKeys() {
        // The validation rule stops these on save; Apex checks again in case data bypassed it
        String key = '3f2b9c1e-0000-4000-8000-000000000001';
        for (String header : new List<String>{ 'Key\r\nX-Evil: 1', 'Key:1', 'Two Words', 'Authorization', 'HOST', 'x'.repeat(81) }) {
            String message = keyRejection(withHeader(header), key);
            Assert.isTrue(message?.contains('idempotency header'), 'Header rejected: ' + header.escapeJava());
        }
        for (String badKey : new List<String>{ null, '', 'a\r\nX-Evil: 1', 'x'.repeat(37), 'key with spaces' }) {
            String message = keyRejection(withHeader('Idempotency-Key'), badKey);
            Assert.isTrue(message?.contains('idempotency key'), 'Key rejected: ' + String.valueOf(badKey)?.escapeJava());
        }
    }

    @IsTest
    static void acceptsEmptyRootAndEncodedPaths() {
        Assert.areEqual('callout:Httpbin_API', urlFor(null), 'Null path calls the base URL');
        Assert.areEqual('callout:Httpbin_API', urlFor(''), 'Empty path calls the base URL');
        Assert.areEqual('callout:Httpbin_API/', urlFor('/'), 'Root path');
        Assert.areEqual('callout:Httpbin_API/%2Fx', urlFor('/%2Fx'), 'Encoded slash stays on the host');
        Assert.areEqual(
            'callout:Httpbin_API/search?q=a+b&tag=%20x',
            urlFor('/search?q=a+b&tag=%20x'),
            'Query kept as given'
        );
    }

    @IsTest
    static void acceptsEverySupportedMethodAndSetsBody() {
        for (String method : new List<String>{ 'GET', 'POST', 'PUT', 'PATCH', 'DELETE' }) {
            HttpRequest request = CalloutService.buildRequest(endpoint('Httpbin_API', method, '/x'), '{"a":1}');
            Assert.areEqual(method, request.getMethod(), 'Method ' + method);
            Assert.areEqual('{"a":1}', request.getBody(), 'Body for ' + method);
            Assert.areEqual('application/json', request.getHeader('Content-Type'), 'JSON content type for ' + method);
        }
    }

    @IsTest
    static void rejectsUnsafeCredentialNames() {
        List<Endpoint__c> endpoints = new List<Endpoint__c>{ new Endpoint__c(Method__c = 'GET', Path__c = '/get') };
        for (String name : new List<String>{ null, '', 'bad/name', 'callout:X', 'a b', '1abc', 'host.com', 'u@h', 'abc\n', 'a-b' }) {
            endpoints.add(endpoint(name, 'GET', '/get'));
        }
        assertAllRejected(endpoints, CREDENTIAL_ERROR);
    }

    @IsTest
    static void rejectsUnsupportedMethods() {
        List<Endpoint__c> endpoints = new List<Endpoint__c>();
        for (String method : new List<String>{ null, 'TRACE', 'get', 'CONNECT' }) {
            endpoints.add(endpoint('Httpbin_API', method, '/get'));
        }
        assertAllRejected(endpoints, METHOD_ERROR);
    }

    @IsTest
    static void rejectsPathsThatCouldEscapeOrInject() {
        List<String> unsafePaths = new List<String>{
            'get',
            '//evil.example.com/x',
            '/a/../b',
            '/a/%2e%2e/b',
            '/a/%2E%2E/b',
            '/a/%252e%252e/b',
            '/user@evil.example.com',
            '/a%40b',
            '/a%2540b',
            '/a\\b',
            '/a%5cb',
            '/a b',
            '/a%0d%0aX-Injected: 1',
            '/a%0Ab',
            '/a\nb',
            '/a\r',
            '/a%00b',
            '/a%09b',
            '/x#/../y',
            '/a%zz',
            '/a%'
        };
        List<Endpoint__c> endpoints = new List<Endpoint__c>();
        for (String path : unsafePaths) {
            endpoints.add(endpoint('Httpbin_API', 'GET', path));
        }
        assertAllRejected(endpoints, PATH_ERROR);
    }

    @IsTest
    static void invalidUtf8DecodesWithoutThrowingAndIsSentEncoded() {
        for (String path : new List<String>{ '/a%C3', '/a%FF' }) {
            Assert.areEqual('callout:Httpbin_API' + path, urlFor(path), 'Kept encoded as given');
        }
    }

    @IsTest
    static void rejectionMessageNeverEchoesThePath() {
        String message = rejectionMessage(endpoint('Httpbin_API', 'GET', '/a/../b?api_key=SECRET123'));

        Assert.isNotNull(message, 'Path is rejected');
        Assert.isFalse(message.contains('SECRET123'), 'Message must not contain the path: ' + message);
    }

    @IsTest
    static void sendsThroughTheNamedCredential() {
        EchoMock mock = new EchoMock();
        Test.setMock(HttpCalloutMock.class, mock);

        Test.startTest();
        HttpResponse response = CalloutService.send(endpoint('Httpbin_API', 'PUT', '/put'), '{"x":1}');
        Test.stopTest();

        Assert.areEqual(200, response.getStatusCode(), 'Mock status returned');
        Assert.areEqual('callout:Httpbin_API/put', mock.received.getEndpoint(), 'Sent to the credential URL');
        Assert.areEqual('PUT', mock.received.getMethod(), 'Sent with the endpoint method');
        Assert.areEqual('{"x":1}', mock.received.getBody(), 'Sent with the body');
    }

    @IsTest
    static void invalidEndpointIsNeverSent() {
        EchoMock mock = new EchoMock();
        Test.setMock(HttpCalloutMock.class, mock);
        List<Endpoint__c> invalid = new List<Endpoint__c>{
            endpoint('bad/name', 'GET', '/get'),
            endpoint('Httpbin_API', 'TRACE', '/get'),
            endpoint('Httpbin_API', 'GET', '/a/../b')
        };

        Integer rejected = 0;
        for (Endpoint__c e : invalid) {
            try {
                CalloutService.send(e, null);
            } catch (CalloutService.InvalidEndpointException ex) {
                rejected++;
            }
        }

        Assert.areEqual(invalid.size(), rejected, 'Every invalid endpoint is rejected');
        Assert.isNull(mock.received, 'Nothing reached the mock');
    }

    @IsTest
    static void buildsRequestsForTwoHundredEndpoints() {
        List<HttpRequest> requests = new List<HttpRequest>();

        Test.startTest();
        for (Integer i = 0; i < 200; i++) {
            requests.add(CalloutService.buildRequest(endpoint('Provider_' + i, 'GET', '/items/' + i), null));
        }
        Test.stopTest();

        Assert.areEqual(200, requests.size(), 'One request per endpoint');
        Assert.areEqual('callout:Provider_199/items/199', requests[199].getEndpoint(), 'Last request URL');
    }
}
