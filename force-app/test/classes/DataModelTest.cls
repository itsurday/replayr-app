/**
 * Rules of the frozen data model (decisions.md, ADR-017): stable keys for providers and endpoints, and a job's
 * request body that can't change once set.
 */
@IsTest
private with sharing class DataModelTest {
    @TestSetup
    static void setup() {
        System.runAs(ReplayrTestAccess.createRunner()) {
            Provider__c provider = new Provider__c(Name = 'P', Named_Credential__c = 'Test_API', Key__c = 'shop');
            insert provider;
            insert new Endpoint__c(Name = 'Orders', Provider__c = provider.Id, Method__c = 'POST', Key__c = 'shop-orders');
        }
    }

    @IsTest
    static void keysAreUniqueIgnoringCase() {
        System.runAs(ReplayrTestAccess.runner()) {
            Id providerId = [SELECT Id FROM Provider__c].Id;
            Database.SaveResult provider = Database.insert(new Provider__c(Name = 'Q', Named_Credential__c = 'Q_API', Key__c = 'SHOP'), false);
            Database.SaveResult endpoint = Database.insert(
                new Endpoint__c(Name = 'Again', Provider__c = providerId, Method__c = 'GET', Key__c = 'Shop-Orders'),
                false
            );
            Database.SaveResult blank = Database.insert(new Endpoint__c(Name = 'No key', Provider__c = providerId, Method__c = 'GET'), false);

            Assert.areEqual(StatusCode.DUPLICATE_VALUE, provider.getErrors()[0].getStatusCode(), 'Provider key taken');
            Assert.areEqual(StatusCode.DUPLICATE_VALUE, endpoint.getErrors()[0].getStatusCode(), 'Endpoint key taken, case ignored');
            Assert.isTrue(blank.isSuccess(), 'A key is optional');
        }
    }

    @IsTest
    static void keysUseOnlySafeCharacters() {
        System.runAs(ReplayrTestAccess.runner()) {
            Id providerId = [SELECT Id FROM Provider__c].Id;
            List<Endpoint__c> endpoints = new List<Endpoint__c>();
            List<String> keys = new List<String>{ 'shop orders', '"quoted"', 'a/b', '-leading', 'ok.v2_final-1' };
            for (String key : keys) {
                endpoints.add(new Endpoint__c(Name = key, Provider__c = providerId, Method__c = 'GET', Key__c = key));
            }
            List<Database.SaveResult> results = Database.insert(endpoints, false);
            Database.SaveResult provider = Database.insert(new Provider__c(Name = 'R', Named_Credential__c = 'R_API', Key__c = 'r api'), false);

            for (Integer i = 0; i < 4; i++) {
                Assert.areEqual(StatusCode.FIELD_CUSTOM_VALIDATION_EXCEPTION, results[i].getErrors()[0].getStatusCode(), 'Refused: ' + keys[i]);
            }
            Assert.isTrue(results[4].isSuccess(), 'Letters, digits, dot, underscore and hyphen allowed');
            Assert.areEqual(StatusCode.FIELD_CUSTOM_VALIDATION_EXCEPTION, provider.getErrors()[0].getStatusCode(), 'Same rule for providers');
        }
    }

    @IsTest
    static void endpointsAreFoundByKey() {
        System.runAs(ReplayrTestAccess.runner()) {
            Endpoint__c found = [SELECT Name FROM Endpoint__c WHERE Key__c = 'SHOP-ORDERS'];
            Assert.areEqual('Orders', found.Name, 'Found by its key, case ignored');
        }
    }

    @IsTest
    static void aRequestBodyCannotChangeOnceSet() {
        System.runAs(ReplayrTestAccess.runner()) {
            Job__c job = new Job__c(Endpoint__c = [SELECT Id FROM Endpoint__c].Id, Method__c = 'POST', Request_Body__c = '{"a": 1}');
            Job__c empty = new Job__c(Endpoint__c = job.Endpoint__c, Method__c = 'POST');
            insert new List<Job__c>{ job, empty };

            Database.SaveResult changed = Database.update(new Job__c(Id = job.Id, Request_Body__c = '{"a": 2}'), false);
            Database.SaveResult cleared = Database.update(new Job__c(Id = job.Id, Request_Body__c = null), false);
            Database.SaveResult firstSet = Database.update(new Job__c(Id = empty.Id, Request_Body__c = '{"b": 1}'), false);
            Database.SaveResult statusOnly = Database.update(new Job__c(Id = job.Id, Status__c = 'Processing'), false);

            Assert.areEqual(StatusCode.FIELD_CUSTOM_VALIDATION_EXCEPTION, changed.getErrors()[0].getStatusCode(), 'Changing it refused');
            Assert.isFalse(cleared.isSuccess(), 'Clearing it refused');
            Assert.isTrue(firstSet.isSuccess(), 'Setting it the first time allowed');
            Assert.isTrue(statusOnly.isSuccess(), 'Other fields still change');
            Assert.areEqual('{"a": 1}', [SELECT Request_Body__c FROM Job__c WHERE Id = :job.Id].Request_Body__c, 'Unchanged');
        }
    }
}
