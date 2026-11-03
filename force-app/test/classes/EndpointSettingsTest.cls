@IsTest
private with sharing class EndpointSettingsTest {
    private static final Integer ENDPOINT_COUNT = 200;

    @TestSetup
    static void setup() {
        System.runAs(ReplayrTestAccess.createRunner()) {
            insert new Provider__c(Name = 'P', Named_Credential__c = 'N');
        }
    }

    private static Endpoint__c newEndpoint() {
        return new Endpoint__c(Name = 'E', Provider__c = [SELECT Id FROM Provider__c LIMIT 1].Id, Method__c = 'POST');
    }

    @IsTest
    static void newEndpointsGetTheSafeDefaults() {
        System.runAs(ReplayrTestAccess.runner()) {
            Endpoint__c template = newEndpoint();
            List<Endpoint__c> endpoints = new List<Endpoint__c>();
            for (Integer i = 0; i < ENDPOINT_COUNT; i++) {
                endpoints.add(template.clone());
            }
            insert endpoints;

            for (Endpoint__c saved : [
                SELECT Retry_Safe__c, Side_Effect_Free__c, Max_Attempts__c, Idempotency_Header__c
                FROM Endpoint__c
            ]) {
                Assert.isFalse(saved.Retry_Safe__c, 'Retry-safe off by default');
                Assert.isFalse(saved.Side_Effect_Free__c, 'Side-effect-free off by default');
                Assert.areEqual(5, saved.Max_Attempts__c, 'Five attempts by default');
                Assert.isNull(saved.Idempotency_Header__c, 'No idempotency header by default');
            }
            Assert.areEqual(ENDPOINT_COUNT, [SELECT COUNT() FROM Endpoint__c], 'All saved');
        }
    }

    @IsTest
    static void acceptsAttemptsFromOneToTen() {
        System.runAs(ReplayrTestAccess.runner()) {
            Endpoint__c once = newEndpoint();
            once.Max_Attempts__c = 1;
            Endpoint__c most = newEndpoint();
            most.Max_Attempts__c = 10;
            insert new List<Endpoint__c>{ once, most };
            Assert.areEqual(2, [SELECT COUNT() FROM Endpoint__c], 'Both limits accepted');
        }
    }

    @IsTest
    static void rejectsAttemptsOutsideOneToTen() {
        System.runAs(ReplayrTestAccess.runner()) {
            List<Endpoint__c> endpoints = new List<Endpoint__c>();
            for (Decimal attempts : new List<Decimal>{ 0, 11, -1, null }) {
                Endpoint__c endpoint = newEndpoint();
                endpoint.Max_Attempts__c = attempts;
                endpoints.add(endpoint);
            }
            List<Database.SaveResult> results = Database.insert(endpoints, false);
            for (Integer i = 0; i < results.size(); i++) {
                // A blank is caught by the field being required, the others by the range rule
                StatusCode expected = endpoints[i].Max_Attempts__c == null
                    ? StatusCode.REQUIRED_FIELD_MISSING
                    : StatusCode.FIELD_CUSTOM_VALIDATION_EXCEPTION;
                assertRejectedWith(results[i], expected, 'Attempts ' + endpoints[i].Max_Attempts__c);
            }
        }
    }

    @IsTest
    static void acceptsValidHeaderNames() {
        System.runAs(ReplayrTestAccess.runner()) {
            List<Endpoint__c> endpoints = new List<Endpoint__c>();
            for (String header : new List<String>{ 'Idempotency-Key', 'X-Request-Id', 'idempotency_key', 'Authorization-Key', 'x.key~1' }) {
                Endpoint__c endpoint = newEndpoint();
                endpoint.Idempotency_Header__c = header;
                endpoints.add(endpoint);
            }
            insert endpoints;
            Assert.areEqual(endpoints.size(), [SELECT COUNT() FROM Endpoint__c], 'All accepted');
        }
    }

    @IsTest
    static void rejectsInvalidOrReservedHeaderNames() {
        System.runAs(ReplayrTestAccess.runner()) {
            List<String> headers = new List<String>{
                'Idempotency Key',
                'Key:Value',
                'Key\nInjected',
                'Key\r\nX-Injected: 1',
                'Key"Quoted"',
                'Key(1)',
                'Key,Other',
                'Authorization',
                'content-type',
                'Content-Length',
                'HOST',
                'Transfer-Encoding',
                'cookie'
            };
            List<Endpoint__c> endpoints = new List<Endpoint__c>();
            for (String header : headers) {
                Endpoint__c endpoint = newEndpoint();
                endpoint.Idempotency_Header__c = header;
                endpoints.add(endpoint);
            }
            List<Database.SaveResult> results = Database.insert(endpoints, false);
            for (Integer i = 0; i < results.size(); i++) {
                assertRejectedWith(results[i], StatusCode.FIELD_CUSTOM_VALIDATION_EXCEPTION, 'Header ' + headers[i]);
            }
        }
    }

    @IsTest
    static void rulesAlsoApplyOnUpdate() {
        System.runAs(ReplayrTestAccess.runner()) {
            Endpoint__c created = newEndpoint();
            insert created;
            // Only the edited fields: the master-detail Provider__c can't be written on update
            Endpoint__c endpoint = new Endpoint__c(Id = created.Id);

            endpoint.Max_Attempts__c = 11;
            assertRejectedWith(Database.update(endpoint, false), StatusCode.FIELD_CUSTOM_VALIDATION_EXCEPTION, 'Attempts 11 on update');
            endpoint.Max_Attempts__c = 3;
            endpoint.Idempotency_Header__c = 'Host';
            assertRejectedWith(Database.update(endpoint, false), StatusCode.FIELD_CUSTOM_VALIDATION_EXCEPTION, 'Header Host on update');

            endpoint.Idempotency_Header__c = 'Idempotency-Key';
            endpoint.Retry_Safe__c = true;
            update endpoint;
            Endpoint__c saved = [SELECT Max_Attempts__c, Idempotency_Header__c, Retry_Safe__c FROM Endpoint__c WHERE Id = :endpoint.Id];
            Assert.areEqual(3, saved.Max_Attempts__c, 'Valid attempts saved');
            Assert.areEqual('Idempotency-Key', saved.Idempotency_Header__c, 'Valid header saved');
            Assert.isTrue(saved.Retry_Safe__c, 'Retry-safe saved');
        }
    }

    private static void assertRejectedWith(Database.SaveResult result, StatusCode expected, String label) {
        Assert.isFalse(result.isSuccess(), label + ' rejected');
        Database.Error error = result.getErrors()[0];
        Assert.areEqual(expected, error.getStatusCode(), label + ' rejected by the right check: ' + error.getMessage());
    }
}
