/**
 * The phase 4a gate: a 200-record flow runs with no limit errors. A flow's async path hands
 * the Send with Replayr action all 200 records in one call, so that call, and the hand-off it starts, must stay
 * well inside the limits with the heaviest work Replayr allows: bodies near the 131,072-character maximum, and
 * an endpoint that writes its reply back (one more access check per record). The real flow is run once in
 * replayr-dev (dev/); this test is the part CI repeats.
 */
@IsTest
private with sharing class Phase4aGateTest {
    private static final String SENDER = ReplayrTestAccess.username('sender');
    private static final Integer BATCH = 200;
    // Four merges of a 32,000-character description: 128,002-character bodies
    private static final String BIG_TEMPLATE = '"{{Description}}{{Description}}{{Description}}{{Description}}"';

    private class OkMock implements HttpCalloutMock {
        public HttpResponse respond(HttpRequest request) {
            HttpResponse response = new HttpResponse();
            response.setStatusCode(200);
            response.setStatus('OK');
            return response;
        }
    }

    @TestSetup
    static void setup() {
        User runner = ReplayrTestAccess.createRunner();
        User sender = ReplayrTestAccess.newUser(ReplayrTestAccess.minimalProfileId(), SENDER);
        System.runAs(new User(Id = UserInfo.getUserId())) {
            insert sender;
            // A sales user: may send, reads and edits accounts, and reads Description
            PermissionSet accounts = new PermissionSet(Name = 'Replayr_Test_Account_Edit', Label = 'Replayr Test Account Edit');
            insert accounts;
            insert new ObjectPermissions(ParentId = accounts.Id, SobjectType = 'Account', PermissionsRead = true, PermissionsEdit = true);
            insert new FieldPermissions(ParentId = accounts.Id, SobjectType = 'Account', Field = 'Account.Description', PermissionsRead = true);
            insert new List<PermissionSetAssignment>{
                new PermissionSetAssignment(AssigneeId = sender.Id, PermissionSetId = [SELECT Id FROM PermissionSet WHERE Name = 'Replayr_Sender'].Id),
                new PermissionSetAssignment(AssigneeId = sender.Id, PermissionSetId = accounts.Id)
            };
        }
        System.runAs(runner) {
            Provider__c provider = new Provider__c(Name = 'Acme', Named_Credential__c = 'Test_API');
            insert provider;
            Endpoint__c big = endpoint(provider.Id, 'big');
            Endpoint__c writeBack = endpoint(provider.Id, 'writeback');
            insert new List<Endpoint__c>{ big, writeBack };
            insert new List<Mapping__c>{
                request(big.Id, BIG_TEMPLATE),
                request(writeBack.Id, '{"name": "{{Name}}"}'),
                new Mapping__c(
                    Endpoint__c = writeBack.Id,
                    Direction__c = 'Response',
                    Target_Object__c = 'Account',
                    Operation__c = 'Update',
                    Rules__c = '{"fields": {"Description": "about"}}'
                )
            };
        }
        List<Account> accounts = new List<Account>();
        String description = 'x'.repeat(32000);
        for (Integer i = 0; i < BATCH; i++) {
            accounts.add(new Account(Name = 'Gate ' + String.valueOf(i).leftPad(3, '0'), Description = description, OwnerId = sender.Id));
        }
        insert accounts;
    }

    private static Endpoint__c endpoint(Id providerId, String key) {
        return new Endpoint__c(Name = key, Key__c = key, Provider__c = providerId, Method__c = 'POST', Path__c = '/' + key, Allow_Sending__c = true);
    }

    private static Mapping__c request(Id endpointId, String template) {
        return new Mapping__c(Endpoint__c = endpointId, Direction__c = 'Request', Target_Object__c = 'Account', Rules__c = template);
    }

    private static List<SendWithReplayr.Request> requests(String key) {
        List<SendWithReplayr.Request> requests = new List<SendWithReplayr.Request>();
        for (Account account : [SELECT Id FROM Account ORDER BY Name]) {
            SendWithReplayr.Request request = new SendWithReplayr.Request();
            request.endpointKey = key;
            request.recordId = account.Id;
            requests.add(request);
        }
        return requests;
    }

    private static User sender() {
        return [SELECT Id FROM User WHERE Username = :SENDER];
    }

    private static void assertAllSent(List<SendWithReplayr.Result> results) {
        Assert.areEqual(BATCH, results.size(), 'One result per record');
        for (SendWithReplayr.Result result : results) {
            Assert.isNull(result.error, 'No error expected: ' + result.error);
            Assert.isNotNull(result.jobId, 'A job for every record');
        }
    }

    @IsTest
    static void twoHundredRecordsWithMaximumBodiesStayWithinLimits() {
        List<SendWithReplayr.Request> requests = requests('big');
        System.runAs(sender()) {
            Test.startTest();
            List<SendWithReplayr.Result> results = SendWithReplayr.send(requests);
            Integer queries = Limits.getQueries();
            Integer dml = Limits.getDmlStatements();
            Integer dmlRows = Limits.getDmlRows();
            Integer cpu = Limits.getCpuTime();
            Test.stopTest();

            assertAllSent(results);
            // One endpoint lookup and one query per 20 records; the bodies saved 20 at a time, plus the event
            Assert.isTrue(queries <= 15, 'Queries: ' + queries + ' of ' + Limits.getLimitQueries());
            Assert.isTrue(dml <= 12, 'DML statements: ' + dml + ' of ' + Limits.getLimitDmlStatements());
            Assert.isTrue(dmlRows <= BATCH + 1, 'DML rows: ' + dmlRows + ' of ' + Limits.getLimitDmlRows());
            Assert.isTrue(cpu <= 5000, 'CPU ms: ' + cpu + ' of ' + Limits.getLimitCpuTime());
        }
    }

    @IsTest
    static void twoHundredRecordsWithWriteBackStayWithinLimits() {
        List<SendWithReplayr.Request> requests = requests('writeback');
        System.runAs(sender()) {
            Test.startTest();
            List<SendWithReplayr.Result> results = SendWithReplayr.send(requests);
            Integer queries = Limits.getQueries();
            Integer dml = Limits.getDmlStatements();
            Integer cpu = Limits.getCpuTime();
            Test.stopTest();

            assertAllSent(results);
            // Per 20 records, the body query and the edit-access check
            Assert.isTrue(queries <= 25, 'Queries: ' + queries + ' of ' + Limits.getLimitQueries());
            Assert.isTrue(dml <= 3, 'DML statements: ' + dml + ' of ' + Limits.getLimitDmlStatements());
            Assert.isTrue(cpu <= 5000, 'CPU ms: ' + cpu + ' of ' + Limits.getLimitCpuTime());
        }
    }

    @IsTest
    static void theHandOffAfterTwoHundredRecordsStaysWithinLimits() {
        List<SendWithReplayr.Request> requests = requests('writeback');
        System.runAs(sender()) {
            assertAllSent(SendWithReplayr.send(requests));
        }
        System.runAs(ReplayrTestAccess.runner()) {
            Test.setMock(HttpCalloutMock.class, new OkMock());
            Test.startTest();
            WorkWaiting.handle();
            Integer queries = Limits.getQueries();
            Integer dml = Limits.getDmlStatements();
            Integer queueables = Limits.getQueueableJobs();

            Assert.areEqual(1, [SELECT COUNT() FROM Job__c WHERE Status__c = 'Processing'], 'One chain started, holding one job');
            Assert.areEqual(BATCH - 1, [SELECT COUNT() FROM Job__c WHERE Status__c = 'Queued'], 'The rest wait for that chain');
            Assert.areEqual(1, queueables, 'One link enqueued');
            Assert.isTrue(queries <= 10, 'Queries: ' + queries + ' of ' + Limits.getLimitQueries());
            Assert.isTrue(dml <= 5, 'DML statements: ' + dml + ' of ' + Limits.getLimitDmlStatements());
            Test.stopTest();
        }
        Assert.areEqual(1, [SELECT COUNT() FROM CronTrigger WHERE CronJobDetail.Name = :JobPoller.JOB_NAME], 'The poller is scheduled');
    }
}
