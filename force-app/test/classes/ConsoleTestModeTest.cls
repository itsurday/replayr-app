@IsTest
private with sharing class ConsoleTestModeTest {
    private static final String OPERATOR = ReplayrTestAccess.username('operator');
    // A provider's own masked name, so masking is proven on what is shown
    private static final String MASKED_NAME = 'acme_ref';
    private static final String MASKED_VALUE = '7712';

    private class EchoMock implements HttpCalloutMock {
        final String body;
        Integer calls = 0;

        EchoMock(String body) {
            this.body = body;
        }

        public HttpResponse respond(HttpRequest request) {
            calls++;
            HttpResponse response = new HttpResponse();
            response.setStatusCode(200);
            response.setStatus('OK');
            response.setBody(body);
            return response;
        }
    }

    @TestSetup
    static void setup() {
        ReplayrTestAccess.createRunner();
        System.runAs(new User(Id = UserInfo.getUserId())) {
            User operator = ReplayrTestAccess.newUser(ReplayrTestAccess.minimalProfileId(), OPERATOR);
            insert operator;
            insert new PermissionSetAssignment(AssigneeId = operator.Id, PermissionSetId = [SELECT Id FROM PermissionSet WHERE Name = 'Replayr_Operator'].Id);
        }
        System.runAs(ReplayrTestAccess.runner()) {
            Provider__c provider = new Provider__c(Name = 'Acme', Named_Credential__c = 'Test_API', Masked_Names__c = MASKED_NAME);
            insert provider;
            Endpoint__c lookup = new Endpoint__c(Name = 'Lookup', Provider__c = provider.Id, Method__c = 'POST', Path__c = '/lookup', Side_Effect_Free__c = true);
            Endpoint__c order = new Endpoint__c(Name = 'Order', Provider__c = provider.Id, Method__c = 'POST', Path__c = '/orders');
            insert new List<Endpoint__c>{ lookup, order };
            String template = '{"name": "{{Name}}", "' + MASKED_NAME + '": "' + MASKED_VALUE + '"}';
            insert new List<Mapping__c>{
                new Mapping__c(Endpoint__c = lookup.Id, Direction__c = 'Request', Target_Object__c = 'Provider__c', Rules__c = template),
                new Mapping__c(Endpoint__c = order.Id, Direction__c = 'Request', Target_Object__c = 'Provider__c', Rules__c = template)
            };
        }
    }

    private static Id endpointNamed(String name) {
        return [SELECT Id FROM Endpoint__c WHERE Name = :name].Id;
    }

    private static Id providerId() {
        return [SELECT Id FROM Provider__c LIMIT 1].Id;
    }

    private static String refusal(Id endpointId, Id recordId, Boolean send) {
        try {
            ConsoleTestMode.run(endpointId, recordId, send);
            Assert.fail('Expected AuraHandledException');
        } catch (AuraHandledException e) {
            return e.getMessage();
        }
        return null;
    }

    @IsTest
    static void previewsWithoutSendingEvenWhenTheEndpointCouldBeSent() {
        Id lookup = endpointNamed('Lookup');
        Id record = providerId();
        EchoMock mock = new EchoMock('{}');
        ConsoleTestMode.Outcome outcome;
        System.runAs(ReplayrTestAccess.runner()) {
            Test.setMock(HttpCalloutMock.class, mock);
            outcome = ConsoleTestMode.run(lookup, record, false);
        }

        Assert.areEqual(0, mock.calls, 'A preview never calls out');
        Assert.isFalse(outcome.sent, 'Not sent');
        Assert.isTrue(outcome.sideEffectFree, 'But it could be: the Send button is offered');
        Assert.areEqual('POST', outcome.method, 'Method');
        Assert.isTrue(outcome.body.contains('"name": "Acme"'), 'The body built from the record: ' + outcome.body);
        Assert.isFalse(JSON.serialize(outcome).contains(MASKED_VALUE), 'Masked: ' + JSON.serialize(outcome));
        Assert.isFalse(outcome.headers.isEmpty(), 'The headers Replayr sets');
        Assert.areEqual(0, [SELECT COUNT() FROM Job__c], 'No test job for a preview');
    }

    @IsTest
    static void sendsASideEffectFreeEndpointAndMasksTheReply() {
        Id lookup = endpointNamed('Lookup');
        Id record = providerId();
        ConsoleTestMode.Outcome outcome;
        System.runAs(ReplayrTestAccess.runner()) {
            Test.setMock(HttpCalloutMock.class, new EchoMock('{"' + MASKED_NAME + '": "' + MASKED_VALUE + '", "ok": true}'));
            Test.startTest();
            outcome = ConsoleTestMode.run(lookup, record, true);
            Test.stopTest();
        }

        Assert.isTrue(outcome.sent, 'Sent');
        Assert.areEqual(200, outcome.statusCode, 'Its status');
        Assert.isTrue(outcome.responseBody.contains('"ok": true'), 'The reply shown: ' + outcome.responseBody);
        Assert.isFalse(JSON.serialize(outcome).contains(MASKED_VALUE), 'Masked everywhere');
        Assert.isNotNull(outcome.jobId, 'Logged as a test job');
    }

    @IsTest
    static void neverSendsAnEndpointWithSideEffects() {
        Id order = endpointNamed('Order');
        Id record = providerId();
        EchoMock mock = new EchoMock('{}');
        ConsoleTestMode.Outcome outcome;
        System.runAs(ReplayrTestAccess.runner()) {
            Test.setMock(HttpCalloutMock.class, mock);
            outcome = ConsoleTestMode.run(order, record, true);
        }

        Assert.areEqual(0, mock.calls, 'Not Side-effect-free: never sent, even when asked');
        Assert.isFalse(outcome.sideEffectFree, 'No Send button');
    }

    @IsTest
    static void withholdsAReplyItCantMask() {
        Id lookup = endpointNamed('Lookup');
        Id record = providerId();
        ConsoleTestMode.Outcome outcome;
        System.runAs(ReplayrTestAccess.runner()) {
            Test.setMock(HttpCalloutMock.class, new EchoMock('<reply><' + MASKED_NAME + '>' + MASKED_VALUE + '</' + MASKED_NAME + '></reply>'));
            Test.startTest();
            outcome = ConsoleTestMode.run(lookup, record, true);
            Test.stopTest();
        }

        Assert.areEqual(200, outcome.statusCode, 'The status is still shown');
        Assert.isNull(outcome.responseBody, 'The XML reply withheld');
        Assert.areEqual(ConsoleTestMode.WITHHELD, outcome.responseWithheld, 'With the reason');
        Assert.isFalse(JSON.serialize(outcome).contains(MASKED_VALUE), 'Nowhere');
    }

    @IsTest
    static void saysWhyARequestCantBeBuilt() {
        Id order = endpointNamed('Order');
        Id record = providerId();
        System.runAs(ReplayrTestAccess.runner()) {
            // A path the callout layer refuses before any call
            update new Endpoint__c(Id = order, Path__c = '/a/../b');
            Assert.isTrue(refusal(order, record, false).startsWith('The request can\'t be built: '), 'The reason, not an empty preview');
        }
    }

    @IsTest
    static void withholdsAReplyCutAtTheLimit() {
        Id lookup = endpointNamed('Lookup');
        Id record = providerId();
        ConsoleTestMode.Outcome outcome;
        System.runAs(ReplayrTestAccess.runner()) {
            Test.setMock(HttpCalloutMock.class, new EchoMock('{"text": "' + 'x'.repeat(TestMode.RESPONSE_LIMIT) + '"}'));
            Test.startTest();
            outcome = ConsoleTestMode.run(lookup, record, true);
            Test.stopTest();
        }

        // Cut mid-JSON it can't be checked for secrets, so it isn't shown
        Assert.isNull(outcome.responseBody, 'Withheld');
        Assert.isNotNull(outcome.responseWithheld, 'With the reason');
        Assert.areEqual(200, outcome.statusCode, 'The status still shown');
    }

    @IsTest
    static void passesOnTestModesReasonsAndIsForReplayrAdminsOnly() {
        Id lookup = endpointNamed('Lookup');
        Id record = providerId();
        System.runAs(ReplayrTestAccess.runner()) {
            Assert.isTrue(refusal(lookup, null, false).contains('Choose a record'), 'A record is needed for the body');
        }
        User operator = [SELECT Id FROM User WHERE Username = :OPERATOR];
        System.runAs(operator) {
            Assert.isTrue(refusal(lookup, record, false).contains('Replayr Admin'), 'Operators may not test');
        }
    }
}
