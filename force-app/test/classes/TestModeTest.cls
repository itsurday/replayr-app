@IsTest
private with sharing class TestModeTest {
    private static final String TEMPLATE = '{"name": "{{Name}}"}';
    private static final String OPERATOR = ReplayrTestAccess.username('operator');

    private class EchoMock implements HttpCalloutMock {
        private final Integer code;
        private final String body;
        public Integer calls = 0;
        public HttpRequest received;

        EchoMock(Integer code, String body) {
            this.code = code;
            this.body = body;
        }

        public HttpResponse respond(HttpRequest request) {
            calls++;
            received = request;
            HttpResponse response = new HttpResponse();
            response.setStatusCode(code);
            response.setStatus(code == 200 ? 'OK' : 'Bad Request');
            response.setBody(body);
            return response;
        }
    }

    private class TimeoutMock implements HttpCalloutMock {
        public HttpResponse respond(HttpRequest request) {
            throw new CalloutException('Read timed out');
        }
    }

    @TestSetup
    static void setup() {
        User runner = ReplayrTestAccess.createRunner();
        System.runAs(new User(Id = UserInfo.getUserId())) {
            User operator = ReplayrTestAccess.newUser(ReplayrTestAccess.minimalProfileId(), OPERATOR);
            insert operator;
            insert new PermissionSetAssignment(
                AssigneeId = operator.Id,
                PermissionSetId = [SELECT Id FROM PermissionSet WHERE Name = 'Replayr_Operator'].Id
            );
        }
        System.runAs(runner) {
            Provider__c provider = new Provider__c(Name = 'Acme', Named_Credential__c = 'Test_API');
            insert provider;
            Endpoint__c lookup = new Endpoint__c(
                Name = 'Lookup',
                Provider__c = provider.Id,
                Method__c = 'POST',
                Path__c = '/lookup',
                Side_Effect_Free__c = true,
                Idempotency_Header__c = 'Idempotency-Key'
            );
            Endpoint__c order = new Endpoint__c(Name = 'Order', Provider__c = provider.Id, Method__c = 'POST', Path__c = '/orders');
            Endpoint__c ping = new Endpoint__c(Name = 'Ping', Provider__c = provider.Id, Method__c = 'GET', Path__c = '/ping', Side_Effect_Free__c = true);
            insert new List<Endpoint__c>{ lookup, order, ping };
            insert new List<Mapping__c>{
                new Mapping__c(Endpoint__c = lookup.Id, Direction__c = 'Request', Target_Object__c = 'Provider__c', Rules__c = TEMPLATE),
                new Mapping__c(Endpoint__c = order.Id, Direction__c = 'Request', Target_Object__c = 'Provider__c', Rules__c = TEMPLATE),
                // Would rename the provider if it were ever applied
                new Mapping__c(
                    Endpoint__c = lookup.Id,
                    Direction__c = 'Response',
                    Target_Object__c = 'Provider__c',
                    Operation__c = 'Update',
                    Rules__c = '{"fields": {"Name": "name"}}'
                )
            };
        }
    }

    private static Id endpointNamed(String name) {
        return [SELECT Id FROM Endpoint__c WHERE Name = :name].Id;
    }

    private static Provider__c provider() {
        return [SELECT Id, Name FROM Provider__c LIMIT 1];
    }

    @IsTest
    static void endpointWithSideEffectsIsOnlyPreviewed() {
        System.runAs(ReplayrTestAccess.runner()) {
            EchoMock mock = new EchoMock(200, '{}');
            Test.setMock(HttpCalloutMock.class, mock);

            TestMode.Result result = TestMode.run(endpointNamed('Order'), provider().Id);

            Assert.isFalse(result.sent, 'Not Side-effect-free: never sent');
            Assert.areEqual(0, mock.calls, 'No callout');
            Assert.areEqual('POST', result.method, 'Method');
            Assert.areEqual('callout:Test_API/orders', result.url, 'URL through the Named Credential');
            Assert.areEqual('{"name": "Acme"}', result.body, 'Body built from the record');
            Assert.areEqual('application/json', result.headers.get('Content-Type'), 'Content type');
            Assert.areEqual(0, [SELECT COUNT() FROM Job__c], 'Nothing logged when nothing is sent');
        }
    }

    @IsTest
    static void sideEffectFreeEndpointIsSentShownAndLoggedButNeverWritten() {
        System.runAs(ReplayrTestAccess.runner()) {
            Provider__c record = provider();
            EchoMock mock = new EchoMock(200, '{"name": "Renamed"}');
            Test.setMock(HttpCalloutMock.class, mock);

            Id lookup = endpointNamed('Lookup');
            // In a test the setup inserts are uncommitted work, and a callout must come first in its context
            Test.startTest();
            TestMode.Result result = TestMode.run(lookup, record.Id);
            Test.stopTest();

            Assert.isTrue(result.sent, 'Sent');
            Assert.areEqual(1, mock.calls, 'Once: ' + result.error);
            Assert.areEqual(200, result.statusCode, 'Status shown');
            Assert.areEqual('{"name": "Renamed"}', result.responseBody, 'Response shown');
            Assert.areEqual(mock.received.getHeader('Idempotency-Key'), result.headers.get('Idempotency-Key'), 'Header shown as sent');
            Assert.areEqual('Acme', provider().Name, 'The Response mapping was never applied');

            Job__c job = [SELECT Status__c, Test_Run__c, Record_Id__c, Request_Body__c, Idempotency_Key__c FROM Job__c WHERE Id = :result.jobId];
            Assert.isTrue(job.Test_Run__c, 'Marked as a test run');
            Assert.areEqual('Succeeded', job.Status__c, 'Result recorded');
            Assert.areEqual(record.Id, job.Record_Id__c, 'For this record');
            Assert.areEqual(result.body, job.Request_Body__c, 'What was sent');
            Assert.areEqual(result.headers.get('Idempotency-Key'), job.Idempotency_Key__c, 'Its key');
            Assert.areEqual(1, [SELECT COUNT() FROM Job_Log__c WHERE Job__c = :result.jobId], 'One log row');
        }
    }

    @IsTest
    static void longResponseIsShortenedForDisplay() {
        System.runAs(ReplayrTestAccess.runner()) {
            Test.setMock(HttpCalloutMock.class, new EchoMock(200, 'x'.repeat(TestMode.RESPONSE_LIMIT + 500)));
            Id ping = endpointNamed('Ping');

            Test.startTest();
            TestMode.Result result = TestMode.run(ping, null);
            Test.stopTest();

            Assert.areEqual(TestMode.RESPONSE_LIMIT, result.responseBody.length(), 'Cut for display');
            Assert.isNull(result.body, 'No mapping, no body');
            Assert.areEqual('GET', result.method, 'Method');
        }
    }

    @IsTest
    static void rejectedTestSendIsLoggedAsFailed() {
        System.runAs(ReplayrTestAccess.runner()) {
            Test.setMock(HttpCalloutMock.class, new EchoMock(400, '{"error": "bad"}'));
            Id ping = endpointNamed('Ping');

            Test.startTest();
            TestMode.Result rejected = TestMode.run(ping, null);
            Test.stopTest();

            Assert.areEqual(400, rejected.statusCode, 'Status shown');
            Assert.areEqual('Failed', [SELECT Status__c FROM Job__c WHERE Id = :rejected.jobId].Status__c, 'Logged as failed');
        }
    }

    @IsTest
    static void unansweredTestSendIsLoggedAsFailed() {
        System.runAs(ReplayrTestAccess.runner()) {
            Test.setMock(HttpCalloutMock.class, new TimeoutMock());
            Id ping = endpointNamed('Ping');

            Test.startTest();
            TestMode.Result timedOut = TestMode.run(ping, null);
            Test.stopTest();

            Assert.areEqual('Read timed out', timedOut.error, 'Error shown');
            Assert.areEqual('Failed', [SELECT Status__c FROM Job__c WHERE Id = :timedOut.jobId].Status__c, 'A test job never waits for a person');
            Assert.areEqual('Outcome_Unknown', [SELECT Outcome__c FROM Job_Log__c WHERE Job__c = :timedOut.jobId].Outcome__c, 'The attempt itself is unknown');
        }
    }

    @IsTest
    static void refusesWhatCantBeBuilt() {
        System.runAs(ReplayrTestAccess.runner()) {
            Id order = endpointNamed('Order');
            insert new Mapping__c(Endpoint__c = endpointNamed('Ping'), Direction__c = 'Request', Target_Object__c = 'Provider__c', Rules__c = TEMPLATE);
            insert new Mapping__c(Endpoint__c = endpointNamed('Ping'), Direction__c = 'Request', Target_Object__c = 'Provider__c', Rules__c = TEMPLATE);
            Map<String, List<Id>> cases = new Map<String, List<Id>>{
                'Choose a record' => new List<Id>{ order, null },
                'more than one Request mapping' => new List<Id>{ endpointNamed('Ping'), provider().Id },
                'Endpoint not found' => new List<Id>{ provider().Id, provider().Id }
            };
            for (String expected : cases.keySet()) {
                try {
                    TestMode.run(cases.get(expected)[0], cases.get(expected)[1]);
                    Assert.fail('Refused: ' + expected);
                } catch (TestMode.TestModeException e) {
                    Assert.isTrue(e.getMessage().contains(expected), 'Says why: ' + e.getMessage());
                }
            }
        }
    }

    @IsTest
    static void operatorWhoCantCreateJobsCanTestAndTheSendIsStillLogged() {
        Id lookup = endpointNamed('Lookup');
        Id record = provider().Id;
        EchoMock mock = new EchoMock(200, '{}');
        Test.setMock(HttpCalloutMock.class, mock);

        TestMode.Result result;
        User operator = [SELECT Id FROM User WHERE Username = :OPERATOR];
        System.runAs(operator) {
            Test.startTest();
            result = TestMode.run(lookup, record);
            Test.stopTest();
        }

        Assert.areEqual(1, mock.calls, 'Sent: ' + result.error);
        Job__c job = [SELECT Test_Run__c, OwnerId FROM Job__c WHERE Id = :result.jobId WITH SYSTEM_MODE];
        Assert.isTrue(job.Test_Run__c, 'Logged in system mode although operators can only read jobs');
    }

    @IsTest
    static void recordOfAnotherObjectIsRefused() {
        System.runAs(ReplayrTestAccess.runner()) {
            EchoMock mock = new EchoMock(200, '{}');
            Test.setMock(HttpCalloutMock.class, mock);
            try {
                // The mapping is for providers; an endpoint also has a Name the template could fill
                TestMode.run(endpointNamed('Lookup'), endpointNamed('Order'));
                Assert.fail('Refused');
            } catch (TestMode.TestModeException e) {
                Assert.isTrue(e.getMessage().contains('Request mapping\'s object'), 'Says why: ' + e.getMessage());
            }
            Assert.areEqual(0, mock.calls, 'Nothing sent');
        }
    }

    @IsTest
    static void templateThatCouldReachASecretIsNeverSent() {
        System.runAs(ReplayrTestAccess.runner()) {
            Id ping = endpointNamed('Ping');
            insert new Mapping__c(
                Endpoint__c = ping,
                Direction__c = 'Request',
                Target_Object__c = 'Provider__c',
                Rules__c = '{"key": "{!$Credential.Test_Auth.ApiKey}"}'
            );
            EchoMock mock = new EchoMock(200, '{}');
            Test.setMock(HttpCalloutMock.class, mock);
            try {
                TestMode.run(ping, provider().Id);
                Assert.fail('Refused');
            } catch (TestMode.TestModeException e) {
                Assert.isTrue(e.getMessage().contains('{!'), 'Says why: ' + e.getMessage());
            }
            Assert.areEqual(0, mock.calls, 'Nothing sent');
            Assert.areEqual(0, [SELECT COUNT() FROM Job__c], 'Nothing logged');
        }
    }

    @IsTest
    static void secretsAreMaskedInWhatIsShownButNotInTheLoggedRequest() {
        System.runAs(ReplayrTestAccess.runner()) {
            Provider__c record = provider();
            update new Provider__c(Id = record.Id, Masked_Names__c = 'name');
            update new Endpoint__c(Id = endpointNamed('Lookup'), Path__c = '/lookup?api_key=abc&page=1');
            Test.setMock(HttpCalloutMock.class, new EchoMock(200, '{"access_token": "t-123", "id": 7}'));
            Id lookup = endpointNamed('Lookup');

            Test.startTest();
            TestMode.Result result = TestMode.run(lookup, record.Id);
            Test.stopTest();

            Assert.areEqual('callout:Test_API/lookup?api_key=****&page=1', result.url, 'Query value masked');
            Assert.areEqual('{"name": "****"}', result.body, 'Configured key masked in the request');
            Assert.areEqual('{"access_token": "****", "id": 7}', result.responseBody, 'Built-in key masked in the response');
            Assert.areEqual('{"name": "Acme"}', [SELECT Request_Body__c FROM Job__c WHERE Id = :result.jobId].Request_Body__c, 'Stored intact');
        }
    }

    @IsTest
    static void unsafeEndpointIsReportedNotSent() {
        System.runAs(ReplayrTestAccess.runner()) {
            Id ping = endpointNamed('Ping');
            update new Endpoint__c(Id = ping, Path__c = '/../admin');
            EchoMock mock = new EchoMock(200, '{}');
            Test.setMock(HttpCalloutMock.class, mock);

            TestMode.Result result = TestMode.run(ping, null);

            Assert.isTrue(result.error.contains('path'), 'Says what is wrong: ' + result.error);
            Assert.isFalse(result.sent, 'Not sent');
            Assert.areEqual(0, mock.calls, 'No callout');
        }
    }
}
