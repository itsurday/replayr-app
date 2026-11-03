@IsTest
private with sharing class JobWorkerTest {
    private class StatusMock implements HttpCalloutMock {
        private final Integer code;
        public Integer calls = 0;

        StatusMock(Integer code) {
            this.code = code;
        }

        public HttpResponse respond(HttpRequest request) {
            calls++;
            HttpResponse response = new HttpResponse();
            response.setStatusCode(code);
            response.setStatus(code == 200 ? 'OK' : 'Service Unavailable');
            response.setBody('{"secret":"must-not-be-stored"}');
            return response;
        }
    }

    private class JsonMock implements HttpCalloutMock {
        private final Integer code;
        private final String body;
        public HttpRequest received;
        public Integer calls = 0;

        JsonMock(Integer code, String body) {
            this.code = code;
            this.body = body;
        }

        public HttpResponse respond(HttpRequest request) {
            calls++;
            received = request;
            HttpResponse response = new HttpResponse();
            response.setStatusCode(code);
            response.setStatus(code == 200 ? 'OK' : 'Service Unavailable');
            response.setBody(body);
            return response;
        }
    }

    private class TimeoutMock implements HttpCalloutMock {
        private final String message;

        TimeoutMock(String message) {
            this.message = message;
        }

        public HttpResponse respond(HttpRequest request) {
            throw new CalloutException(message);
        }
    }

    @TestSetup
    static void setup() {
        User runner = ReplayrTestAccess.createRunner();
        System.runAs(runner) {
            Provider__c provider = new Provider__c(
                Name = 'Test',
                Named_Credential__c = 'Test_API'
            );
            insert provider;
            insert new Endpoint__c(Name = 'Get', Provider__c = provider.Id, Method__c = 'GET', Path__c = '/get');
        }
    }

    private static Id endpointId {
        get {
            if (endpointId == null) {
                endpointId = [SELECT Id FROM Endpoint__c LIMIT 1].Id;
            }
            return endpointId;
        }
        set;
    }

    private static Job__c newJob(String status, String path) {
        return new Job__c(
            Endpoint__c = endpointId,
            Status__c = status,
            Method__c = 'GET',
            Path__c = path
        );
    }

    private static Job__c insertJob(String status) {
        Job__c job = newJob(status, '/get');
        insert job;
        return job;
    }

    private static Job__c reload(Id jobId) {
        return [SELECT Id, Status__c, HTTP_Status__c, Result__c FROM Job__c WHERE Id = :jobId];
    }

    private static Job_Log__c onlyLog(Id jobId) {
        List<Job_Log__c> logs = [
            SELECT Outcome__c, HTTP_Status__c, Message__c, Duration_Ms__c
            FROM Job_Log__c
            WHERE Job__c = :jobId
        ];
        Assert.areEqual(1, logs.size(), 'Exactly one log row per attempt');
        return logs[0];
    }

    @IsTest
    static void claimsOneOfTwoHundredQueuedJobs() {
        System.runAs(ReplayrTestAccess.runner()) {
            List<Job__c> jobs = new List<Job__c>();
            for (Integer i = 0; i < 200; i++) {
                jobs.add(newJob('Queued', '/items/' + i));
            }
            insert jobs;

            Test.startTest();
            Job__c claimed = JobWorker.claimNext();
            Test.stopTest();

            Assert.isNotNull(claimed, 'A job is claimed');
            Assert.areEqual('Processing', reload(claimed.Id).Status__c, 'Claimed job is Processing');
            Assert.areEqual(199, [SELECT COUNT() FROM Job__c WHERE Status__c = 'Queued'], 'Others stay Queued');
        }
    }

    @IsTest
    static void claimsTheOldestQueuedJob() {
        System.runAs(ReplayrTestAccess.runner()) {
            List<Job__c> jobs = new List<Job__c>();
            for (Integer i = 0; i < 10; i++) {
                jobs.add(newJob('Queued', '/items/' + i));
            }
            insert jobs;
            Long oldest;
            for (Job__c job : [SELECT Sequence__c FROM Job__c]) {
                Long sequence = Long.valueOf(job.Sequence__c);
                oldest = oldest == null || sequence < oldest ? sequence : oldest;
            }

            Job__c claimed = JobWorker.claimNext();

            Assert.areEqual(oldest, Long.valueOf(claimed.Sequence__c), 'Lowest sequence, compared as a number');
        }
    }

    @IsTest
    static void claimCountsTheAttemptAndRecordsTheStart() {
        System.runAs(ReplayrTestAccess.runner()) {
            Job__c retried = newJob('Queued', '/retried');
            retried.Attempts__c = 2;
            retried.Next_Attempt_At__c = System.now().addMinutes(-1);
            insert retried;
            Datetime before = System.now();

            Job__c claimed = JobWorker.claimNext();

            Job__c saved = [SELECT Attempts__c, Started_At__c, Next_Attempt_At__c FROM Job__c WHERE Id = :claimed.Id];
            Assert.areEqual(3, saved.Attempts__c, 'Earlier attempts kept, this one added');
            Assert.isTrue(saved.Started_At__c >= before.addSeconds(-1) && saved.Started_At__c <= System.now(), 'Start time recorded');
            Assert.isNull(saved.Next_Attempt_At__c, 'A claimed job is no longer waiting');
        }
    }

    @IsTest
    static void claimCountsFromOneWhenAttemptsIsBlank() {
        System.runAs(ReplayrTestAccess.runner()) {
            Job__c job = newJob('Queued', '/blank');
            job.Attempts__c = null;
            insert job;

            JobWorker.claimNext();

            Assert.areEqual(1, [SELECT Attempts__c FROM Job__c WHERE Id = :job.Id].Attempts__c, 'Blank counts as no attempts');
        }
    }

    @IsTest
    static void newJobsStartWithNoAttemptsAndTheRetryStatesSave() {
        System.runAs(ReplayrTestAccess.runner()) {
            Job__c fresh = newJob('Queued', '/fresh');
            Job__c waiting = newJob('Retry_Wait', '/waiting');
            waiting.Next_Attempt_At__c = System.now().addMinutes(1);
            Job__c dead = newJob('Dead', '/dead');
            insert new List<Job__c>{ fresh, waiting, dead };

            Job__c saved = [
                SELECT Attempts__c, Retry_Safe__c, Not_Replayable__c, Idempotency_Key__c
                FROM Job__c
                WHERE Id = :fresh.Id
            ];
            Assert.areEqual(0, saved.Attempts__c, 'No attempts yet');
            Assert.isFalse(saved.Retry_Safe__c, 'Not Retry-safe unless copied from the endpoint');
            Assert.isFalse(saved.Not_Replayable__c, 'Replayable by default');
            Assert.isNull(saved.Idempotency_Key__c, 'No key until one is made');
            Assert.areEqual(2, [SELECT COUNT() FROM Job__c WHERE Status__c IN ('Retry_Wait', 'Dead')], 'New states save');
            Assert.isNotNull([SELECT Next_Attempt_At__c FROM Job__c WHERE Id = :waiting.Id].Next_Attempt_At__c, 'Next attempt saved');
        }
    }

    @IsTest
    static void claimsNothingWhenNoJobIsQueued() {
        System.runAs(ReplayrTestAccess.runner()) {
            insertJob('Succeeded');

            Assert.isNull(JobWorker.claimNext(), 'Nothing to claim');
            Assert.isNull(JobWorker.start(), 'No chain is started');
        }
    }

    @IsTest
    static void successfulCallMarksJobSucceededAndLogsIt() {
        System.runAs(ReplayrTestAccess.runner()) {
            Job__c job = insertJob('Processing');
            Test.setMock(HttpCalloutMock.class, new StatusMock(200));

            Test.startTest();
            System.enqueueJob(new JobWorker(job.Id));
            Test.stopTest();

            Job__c result = reload(job.Id);
            Assert.areEqual('Succeeded', result.Status__c, 'Job status');
            Assert.areEqual(200, result.HTTP_Status__c, 'HTTP status');
            Assert.areEqual('HTTP 200 OK', result.Result__c, 'Short result, no body');
            Job_Log__c log = onlyLog(job.Id);
            Assert.areEqual('Succeeded', log.Outcome__c, 'Log outcome');
            Assert.isNotNull(log.Duration_Ms__c, 'Duration recorded');
            Assert.isFalse(log.Message__c.contains('must-not-be-stored'), 'Response body never stored');
        }
    }

    @IsTest
    static void httpErrorMarksJobFailed() {
        System.runAs(ReplayrTestAccess.runner()) {
            Job__c job = insertJob('Processing');
            Test.setMock(HttpCalloutMock.class, new StatusMock(503));

            Test.startTest();
            System.enqueueJob(new JobWorker(job.Id));
            Test.stopTest();

            Assert.areEqual('Failed', reload(job.Id).Status__c, 'Job status');
            Job_Log__c log = onlyLog(job.Id);
            Assert.areEqual('Failed', log.Outcome__c, 'Log outcome');
            Assert.areEqual(503, log.HTTP_Status__c, 'HTTP status logged');
        }
    }

    @IsTest
    static void invalidEndpointIsLoggedAsNotSentAndNeverCalled() {
        System.runAs(ReplayrTestAccess.runner()) {
            Job__c job = newJob('Processing', '/a/../b');
            insert job;
            StatusMock mock = new StatusMock(200);
            Test.setMock(HttpCalloutMock.class, mock);

            Test.startTest();
            System.enqueueJob(new JobWorker(job.Id));
            Test.stopTest();

            Assert.areEqual(0, mock.calls, 'Nothing was sent');
            Assert.areEqual('Failed', reload(job.Id).Status__c, 'Job status');
            Job_Log__c log = onlyLog(job.Id);
            Assert.areEqual('Not_Sent', log.Outcome__c, 'Log outcome');
            Assert.isNull(log.Duration_Ms__c, 'No duration when nothing was sent');
        }
    }

    @IsTest
    static void calloutExceptionMarksOutcomeUnknown() {
        System.runAs(ReplayrTestAccess.runner()) {
            Job__c job = insertJob('Processing');
            Test.setMock(HttpCalloutMock.class, new TimeoutMock('Read timed out'));

            Test.startTest();
            System.enqueueJob(new JobWorker(job.Id));
            Test.stopTest();

            Job__c result = reload(job.Id);
            Assert.areEqual('Outcome_Unknown', result.Status__c, 'A timeout may have reached the remote system');
            Assert.areEqual('Read timed out', result.Result__c, 'Error kept as the result');
            Assert.areEqual('Outcome_Unknown', onlyLog(job.Id).Outcome__c, 'Log outcome');
        }
    }

    @IsTest
    static void calloutErrorNeverStoresThePathAndIsShortened() {
        System.runAs(ReplayrTestAccess.runner()) {
            String path = '/v1/items?api_key=SECRET123';
            Job__c job = newJob('Processing', path);
            insert job;
            String platformMessage =
                'Unable to reach endpoint = callout:Test_API' + path + ' (query api_key=SECRET123) ' + 'x'.repeat(400);
            Test.setMock(HttpCalloutMock.class, new TimeoutMock(platformMessage));

            Test.startTest();
            System.enqueueJob(new JobWorker(job.Id));
            Test.stopTest();

            Job__c result = reload(job.Id);
            Assert.isFalse(result.Result__c.contains('SECRET123'), 'Job result never holds the path');
            Assert.isTrue(result.Result__c.length() <= JobLogs.TEXT_LIMIT, 'Job result fits the field');
            Assert.isNull(result.HTTP_Status__c, 'No HTTP status without a response');
            Assert.isFalse(onlyLog(job.Id).Message__c.contains('SECRET123'), 'Log never holds the path');
        }
    }

    @IsTest
    static void linkForADeletedJobDoesNothing() {
        System.runAs(ReplayrTestAccess.runner()) {
            Job__c job = insertJob('Processing');
            delete job;
            StatusMock mock = new StatusMock(200);
            Test.setMock(HttpCalloutMock.class, mock);

            Test.startTest();
            System.enqueueJob(new JobWorker(job.Id));
            Test.stopTest();

            Assert.areEqual(0, mock.calls, 'Nothing is sent for a job that no longer exists');
        }
    }

    @IsTest
    static void unclaimedJobIsNeverCalled() {
        System.runAs(ReplayrTestAccess.runner()) {
            Job__c job = insertJob('Queued');
            StatusMock mock = new StatusMock(200);
            Test.setMock(HttpCalloutMock.class, mock);

            Test.startTest();
            System.enqueueJob(new JobWorker(job.Id));
            Test.stopTest();

            Assert.areEqual(0, mock.calls, 'A link only calls a job it claimed');
            Assert.areEqual('Queued', reload(job.Id).Status__c, 'Job untouched');
            Assert.areEqual(0, [SELECT COUNT() FROM Job_Log__c], 'No log row');
        }
    }

    @IsTest
    static void nextLinkFailureNeverLosesTheRecordedResult() {
        System.runAs(ReplayrTestAccess.runner()) {
            Job__c first = insertJob('Processing');
            Job__c second = insertJob('Queued');
            Test.setMock(HttpCalloutMock.class, new StatusMock(200));

            // Tests cannot chain Queueables, so enqueuing the next link fails, as the chain-depth limit does in an org
            Test.startTest();
            System.enqueueJob(new JobWorker(first.Id));
            Test.stopTest();

            Assert.areEqual('Succeeded', reload(first.Id).Status__c, 'Result of the sent call is kept');
            Assert.areEqual(1, [SELECT COUNT() FROM Job_Log__c WHERE Job__c = :first.Id], 'Its log row is kept');
            Assert.areEqual('Queued', reload(second.Id).Status__c, 'Next job is left Queued, never stranded');
        }
    }

    // A second provider, writable by the test user, stands in for the customer's record the job is about
    private static Provider__c insertTarget() {
        Provider__c target = new Provider__c(Name = 'Before', Named_Credential__c = 'Other_API');
        insert target;
        return target;
    }

    private static void insertResponseMapping(String operation, String rules) {
        insert new Mapping__c(
            Endpoint__c = endpointId,
            Direction__c = 'Response',
            Target_Object__c = 'Provider__c',
            Operation__c = operation,
            Rules__c = rules
        );
    }

    private static Job__c runWith(JsonMock mock, String requestBody, Id recordId) {
        Job__c job = newJob('Processing', '/get');
        job.Request_Body__c = requestBody;
        job.Record_Id__c = recordId;
        insert job;
        Test.setMock(HttpCalloutMock.class, mock);
        Test.startTest();
        System.enqueueJob(new JobWorker(job.Id));
        Test.stopTest();
        return reload(job.Id);
    }

    @IsTest
    static void sendsTheStoredBodyAndWritesTheResponseBack() {
        System.runAs(ReplayrTestAccess.runner()) {
            Provider__c target = insertTarget();
            insertResponseMapping('Update', '{"fields": {"Name": "data.name"}}');
            JsonMock mock = new JsonMock(200, '{"data": {"name": "After"}}');

            Job__c result = runWith(mock, '{"order": "A1"}', target.Id);

            Assert.areEqual('{"order": "A1"}', mock.received.getBody(), 'Stored body sent as is');
            Assert.areEqual('application/json', mock.received.getHeader('Content-Type'), 'JSON content type');
            Assert.areEqual('Succeeded', result.Status__c, 'Job status');
            Assert.areEqual('HTTP 200 OK. Response: 1 saved.', result.Result__c, 'Result says what was saved');
            Assert.areEqual('After', [SELECT Name FROM Provider__c WHERE Id = :target.Id].Name, 'Written back to the job\'s record');
            Assert.isTrue(onlyLog(result.Id).Message__c.contains('1 saved'), 'Log says so too');
        }
    }

    @IsTest
    static void aResponseThatCannotBeWrittenLeavesTheJobSucceeded() {
        System.runAs(ReplayrTestAccess.runner()) {
            Provider__c target = insertTarget();
            insertResponseMapping('Update', '{"fields": {"Nope__c": "name"}}');

            Job__c result = runWith(new JsonMock(200, '{"name": "After"}'), null, target.Id);

            Assert.areEqual('Succeeded', result.Status__c, 'The call succeeded, so no resend is invited');
            Assert.isTrue(result.Result__c.startsWith('HTTP 200 OK. Response not saved: Unknown field'), result.Result__c);
            Assert.areEqual('Before', [SELECT Name FROM Provider__c WHERE Id = :target.Id].Name, 'Nothing written');
            Assert.areEqual('Succeeded', onlyLog(result.Id).Outcome__c, 'Log outcome');
        }
    }

    @IsTest
    static void aPartlyWrittenResponseNamesTheFirstProblem() {
        System.runAs(ReplayrTestAccess.runner()) {
            insertResponseMapping('Insert', '{"fields": {"Name": "n", "replayr__Named_Credential__c": "nc", "replayr__Masked_Names__c": "ec"}}');

            Job__c result = runWith(new JsonMock(200, '[{"n": "New", "nc": "New_API", "ec": "New_Auth"}, 42]'), null, null);

            Assert.areEqual('Succeeded', result.Status__c, 'Job status');
            Assert.areEqual('HTTP 200 OK. Response: 1 saved, 1 problems. First: Item 2: not a JSON object', result.Result__c, 'Summary');
            Assert.areEqual(1, [SELECT COUNT() FROM Provider__c WHERE Name = 'New'], 'Good item saved');
        }
    }

    @IsTest
    static void aFailedCallWritesNothing() {
        System.runAs(ReplayrTestAccess.runner()) {
            Provider__c target = insertTarget();
            insertResponseMapping('Update', '{"fields": {"Name": "name"}}');

            Job__c result = runWith(new JsonMock(503, '{"name": "After"}'), null, target.Id);

            Assert.areEqual('Failed', result.Status__c, 'Job status');
            Assert.areEqual('HTTP 503 Service Unavailable', result.Result__c, 'No response note');
            Assert.areEqual('Before', [SELECT Name FROM Provider__c WHERE Id = :target.Id].Name, 'Nothing written');
        }
    }

    @IsTest
    static void twoResponseMappingsStopTheCallBeforeItIsSent() {
        System.runAs(ReplayrTestAccess.runner()) {
            insertResponseMapping('Insert', '{"fields": {"Name": "name"}}');
            insertResponseMapping('Insert', '{"fields": {"Name": "name"}}');
            JsonMock mock = new JsonMock(200, '{}');

            Job__c result = runWith(mock, null, null);

            Assert.areEqual(0, mock.calls, 'Nothing sent');
            Assert.areEqual('Failed', result.Status__c, 'Job status');
            Assert.isTrue(result.Result__c.contains('more than one Response mapping'), result.Result__c);
            Assert.areEqual('Not_Sent', onlyLog(result.Id).Outcome__c, 'Log outcome');
        }
    }

    @IsTest
    static void malformedRecordIdHasNoRecordToWriteBackTo() {
        System.runAs(ReplayrTestAccess.runner()) {
            insertResponseMapping('Update', '{"fields": {"Name": "name"}}');
            Job__c job = newJob('Processing', '/get');
            job.Record_Id__c = 'not-an-id';
            insert job;
            Test.setMock(HttpCalloutMock.class, new JsonMock(200, '{"name": "After"}'));

            Test.startTest();
            System.enqueueJob(new JobWorker(job.Id));
            Test.stopTest();

            Job__c result = reload(job.Id);
            Assert.areEqual('Succeeded', result.Status__c, 'Job status');
            Assert.isTrue(result.Result__c.contains('Response not saved: Update without a Match Field'), result.Result__c);
        }
    }

    @IsTest
    static void anEmptySuccessfulResponseHasNothingToSave() {
        System.runAs(ReplayrTestAccess.runner()) {
            insertResponseMapping('Insert', '{"fields": {"Name": "name"}}');

            Job__c result = runWith(new JsonMock(200, ''), null, null);

            Assert.areEqual('Succeeded', result.Status__c, 'Job status');
            Assert.areEqual('HTTP 200 OK. Response: empty, nothing to save.', result.Result__c, 'Not an error');
        }
    }

    @IsTest
    static void startClaimsAndRunsAChain() {
        System.runAs(ReplayrTestAccess.runner()) {
            Job__c job = insertJob('Queued');
            Test.setMock(HttpCalloutMock.class, new StatusMock(200));

            Test.startTest();
            Id started = JobWorker.start();
            Test.stopTest();

            Assert.areEqual(job.Id, started, 'The queued job was claimed');
            Assert.areEqual('Succeeded', reload(job.Id).Status__c, 'Chain ran it');
        }
    }
}
