/**
 * Retry in the worker: a Retry-safe job whose error may pass waits for another attempt, or has used them all
 * up; a job that isn't Retry-safe is never resent. Due retries are claimed again, and an idle chain wakes up
 * for retries due within ten minutes.
 */
@IsTest
private with sharing class JobRetryTest {
    private static final Integer MAX_ATTEMPTS = 3;

    private class StatusMock implements HttpCalloutMock {
        private final Integer code;
        private final String retryAfter;
        public Integer calls = 0;
        public HttpRequest received;

        StatusMock(Integer code, String retryAfter) {
            this.code = code;
            this.retryAfter = retryAfter;
        }

        public HttpResponse respond(HttpRequest request) {
            calls++;
            received = request;
            HttpResponse response = new HttpResponse();
            response.setStatusCode(code);
            response.setStatus('Status ' + code);
            if (retryAfter != null) {
                response.setHeader('Retry-After', retryAfter);
            }
            return response;
        }
    }

    private class TimeoutMock implements HttpCalloutMock {
        public HttpResponse respond(HttpRequest request) {
            throw new CalloutException('Read timed out');
        }
    }

    private class CrashTestException extends Exception {
    }

    // Stands in for the link dying while the request is in flight
    private class CrashingMock implements HttpCalloutMock {
        public Integer calls = 0;

        public HttpResponse respond(HttpRequest request) {
            calls++;
            throw new CrashTestException('Worker died during the callout');
        }
    }

    @TestSetup
    static void setup() {
        System.runAs(ReplayrTestAccess.createRunner()) {
            Provider__c provider = new Provider__c(Name = 'P', Named_Credential__c = 'Test_API');
            insert provider;
            insert new Endpoint__c(
                Name = 'Put',
                Provider__c = provider.Id,
                Method__c = 'PUT',
                Path__c = '/items',
                Retry_Safe__c = true,
                Max_Attempts__c = MAX_ATTEMPTS
            );
        }
    }

    private static Id endpointId {
        get {
            endpointId = endpointId ?? [SELECT Id FROM Endpoint__c LIMIT 1].Id;
            return endpointId;
        }
        set;
    }

    private static Job__c newJob(String status, Boolean retrySafe, Integer attempts) {
        return new Job__c(
            Endpoint__c = endpointId,
            Status__c = status,
            Method__c = 'PUT',
            Path__c = '/items',
            Retry_Safe__c = retrySafe,
            Attempts__c = attempts
        );
    }

    private static Job__c processing(Boolean retrySafe, Integer attempts) {
        Job__c job = newJob('Processing', retrySafe, attempts);
        insert job;
        return job;
    }

    private static void runLink(Id jobId) {
        Test.startTest();
        System.enqueueJob(new JobWorker(jobId));
        Test.stopTest();
    }

    private static Job__c reload(Id jobId) {
        return [SELECT Status__c, HTTP_Status__c, Result__c, Next_Attempt_At__c FROM Job__c WHERE Id = :jobId];
    }

    private static Long secondsUntil(Datetime due, Datetime since) {
        return (due.getTime() - since.getTime()) / 1000;
    }

    @IsTest
    static void retrySafeTemporaryErrorWaitsForTheNextAttempt() {
        System.runAs(ReplayrTestAccess.runner()) {
            Job__c job = processing(true, 1);
            Test.setMock(HttpCalloutMock.class, new StatusMock(503, null));
            Datetime before = System.now();

            runLink(job.Id);

            Job__c result = reload(job.Id);
            Assert.areEqual('Retry_Wait', result.Status__c, 'Waiting to retry');
            Long wait = secondsUntil(result.Next_Attempt_At__c, before);
            Assert.isTrue(wait >= 47 && wait <= 73, 'About a minute after attempt 1, spread by 20%: ' + wait);
            Assert.isTrue(result.Result__c.contains('Retrying at'), 'Says what happens next: ' + result.Result__c);
            Job_Log__c log = [SELECT Outcome__c, HTTP_Status__c, Message__c FROM Job_Log__c WHERE Job__c = :job.Id];
            Assert.areEqual('Failed', log.Outcome__c, 'The attempt itself failed');
            Assert.areEqual(503, log.HTTP_Status__c, 'HTTP status logged');
            Assert.isTrue(log.Message__c.contains('Retrying at'), 'Log says it too');
        }
    }

    @IsTest
    static void honoursTheResponseRetryAfter() {
        System.runAs(ReplayrTestAccess.runner()) {
            Job__c job = processing(true, 1);
            Test.setMock(HttpCalloutMock.class, new StatusMock(429, '300'));
            Datetime before = System.now();

            runLink(job.Id);

            Job__c result = reload(job.Id);
            Assert.areEqual('Retry_Wait', result.Status__c, 'Waiting to retry');
            Long wait = secondsUntil(result.Next_Attempt_At__c, before);
            Assert.isTrue(wait >= 299 && wait <= 305, 'Five minutes, as the API asked: ' + wait);
        }
    }

    @IsTest
    static void retrySafeTimeoutWaitsForTheNextAttempt() {
        System.runAs(ReplayrTestAccess.runner()) {
            Job__c job = processing(true, 1);
            Test.setMock(HttpCalloutMock.class, new TimeoutMock());

            runLink(job.Id);

            Assert.areEqual('Retry_Wait', reload(job.Id).Status__c, 'A Retry-safe job may be resent after a timeout');
            Assert.areEqual('Outcome_Unknown', [SELECT Outcome__c FROM Job_Log__c WHERE Job__c = :job.Id].Outcome__c, 'Attempt logged as unknown');
        }
    }

    @IsTest
    static void lastAttemptHasNoneLeft() {
        System.runAs(ReplayrTestAccess.runner()) {
            Job__c job = processing(true, MAX_ATTEMPTS);
            Test.setMock(HttpCalloutMock.class, new StatusMock(503, null));

            runLink(job.Id);

            Job__c result = reload(job.Id);
            Assert.areEqual('Dead', result.Status__c, 'Retries used up');
            Assert.isNull(result.Next_Attempt_At__c, 'Nothing more is planned');
            Assert.isTrue(result.Result__c.endsWith('No attempts left'), 'Says so: ' + result.Result__c);
        }
    }

    @IsTest
    static void finalErrorIsNeverRetried() {
        System.runAs(ReplayrTestAccess.runner()) {
            Job__c job = processing(true, 1);
            Test.setMock(HttpCalloutMock.class, new StatusMock(400, '60'));

            runLink(job.Id);

            Job__c result = reload(job.Id);
            Assert.areEqual('Failed', result.Status__c, 'A 400 will not pass by retrying');
            Assert.isNull(result.Next_Attempt_At__c, 'No retry planned');
        }
    }

    @IsTest
    static void httpErrorOfAJobThatIsNotRetrySafeIsFinal() {
        System.runAs(ReplayrTestAccess.runner()) {
            Job__c job = processing(false, 1);
            Test.setMock(HttpCalloutMock.class, new StatusMock(503, null));

            runLink(job.Id);

            Job__c result = reload(job.Id);
            Assert.areEqual('Failed', result.Status__c, 'The job copy says not Retry-safe, though the endpoint is');
            Assert.isNull(result.Next_Attempt_At__c, 'No retry planned');
        }
    }

    @IsTest
    static void timeoutOfAJobThatIsNotRetrySafeIsNeverResent() {
        System.runAs(ReplayrTestAccess.runner()) {
            Job__c job = processing(false, 1);
            Test.setMock(HttpCalloutMock.class, new TimeoutMock());

            runLink(job.Id);

            Job__c result = reload(job.Id);
            Assert.areEqual('Outcome_Unknown', result.Status__c, 'Only a person clears it');
            Assert.isNull(result.Next_Attempt_At__c, 'No retry planned');
        }
    }

    @IsTest
    static void deathDuringTheCalloutOfARetrySafeJobWaitsForRetry() {
        System.runAs(ReplayrTestAccess.runner()) {
            Job__c job = processing(true, 1);
            CrashingMock mock = new CrashingMock();
            Test.setMock(HttpCalloutMock.class, mock);

            Test.startTest();
            System.enqueueJob(new JobWorker(job.Id));
            String crash;
            try {
                Test.stopTest();
            } catch (Exception e) {
                crash = e.getTypeName();
            }

            Assert.isTrue(crash?.endsWith('CrashTestException'), 'The link really crashed: ' + crash);
            Assert.areEqual(1, mock.calls, 'Sent once by this link');
            Job__c result = reload(job.Id);
            Assert.areEqual('Retry_Wait', result.Status__c, 'The finalizer applied the same retry rule');
            Assert.isNotNull(result.Next_Attempt_At__c, 'Retry planned');
        }
    }

    private static String crashAfterCallout(Id jobId) {
        JobWorker link = new JobWorker(jobId);
        link.crashAfterCallout = true;
        Test.startTest();
        System.enqueueJob(link);
        try {
            Test.stopTest();
        } catch (Exception e) {
            return e.getTypeName();
        }
        return null;
    }

    @IsTest
    static void deathAfterARetryableResponseKeepsTheRetryAfter() {
        System.runAs(ReplayrTestAccess.runner()) {
            Job__c job = processing(true, 1);
            StatusMock mock = new StatusMock(429, '300');
            Test.setMock(HttpCalloutMock.class, mock);
            Datetime before = System.now();

            String crash = crashAfterCallout(job.Id);

            Assert.isTrue(crash?.endsWith('SimulatedCrashException'), 'The link really crashed: ' + crash);
            Assert.areEqual(1, mock.calls, 'Sent once');
            Job__c result = reload(job.Id);
            Assert.areEqual('Retry_Wait', result.Status__c, 'Recorded from the finalizer with the retry rule');
            Long wait = secondsUntil(result.Next_Attempt_At__c, before);
            Assert.isTrue(wait >= 299 && wait <= 305, 'Retry-After survived the crash: ' + wait);
        }
    }

    @IsTest
    static void deathAfterARetryableResponseOfAJobThatIsNotRetrySafeIsFinal() {
        System.runAs(ReplayrTestAccess.runner()) {
            Job__c job = processing(false, 1);
            Test.setMock(HttpCalloutMock.class, new StatusMock(503, null));

            crashAfterCallout(job.Id);

            Job__c result = reload(job.Id);
            Assert.areEqual('Failed', result.Status__c, 'Never resent');
            Assert.areEqual(503, result.HTTP_Status__c, 'Real result from the finalizer');
        }
    }

    @IsTest
    static void attemptBelowTheLimitStillRetries() {
        System.runAs(ReplayrTestAccess.runner()) {
            Job__c job = processing(true, MAX_ATTEMPTS - 1);
            Test.setMock(HttpCalloutMock.class, new StatusMock(500, null));

            runLink(job.Id);

            Assert.areEqual('Retry_Wait', reload(job.Id).Status__c, 'One attempt left');
        }
    }

    @IsTest
    static void claimTakesTheOldestOfQueuedAndDueRetries() {
        System.runAs(ReplayrTestAccess.runner()) {
            Job__c retry = newJob('Retry_Wait', true, 1);
            retry.Next_Attempt_At__c = System.now().addMinutes(-1);
            insert retry;
            insert newJob('Queued', true, 0);

            Assert.areEqual(retry.Id, JobWorker.claimNext().Id, 'The older job first, whether queued or retrying');
        }
    }

    @IsTest
    static void wakesUpForRetriesDueWithinTenMinutesOnly() {
        System.runAs(ReplayrTestAccess.runner()) {
            Job__c job = newJob('Retry_Wait', true, 1);
            job.Next_Attempt_At__c = System.now().addMinutes(10);
            insert job;

            Test.startTest();
            JobWorker.start();
            Integer atTen = Limits.getQueueableJobs();
            update new Job__c(Id = job.Id, Next_Attempt_At__c = System.now().addSeconds(630));
            JobWorker.start();
            Integer afterTenAndAHalf = Limits.getQueueableJobs() - atTen;
            Test.stopTest();

            Assert.areEqual(1, atTen, 'Ten minutes is the longest delay');
            Assert.areEqual(0, afterTenAndAHalf, 'Rounded up to eleven: left to the poller');
        }
    }

    private static void setIdempotencyHeader(String header) {
        update new Endpoint__c(Id = endpointId, Idempotency_Header__c = header);
    }

    @IsTest
    static void claimMakesTheIdempotencyKeyOnceAndKeepsIt() {
        System.runAs(ReplayrTestAccess.runner()) {
            insert newJob('Queued', true, 0);

            Id jobId = JobWorker.claimNext().Id;
            String first = [SELECT Idempotency_Key__c FROM Job__c WHERE Id = :jobId].Idempotency_Key__c;
            update new Job__c(Id = jobId, Status__c = 'Retry_Wait', Next_Attempt_At__c = System.now().addMinutes(-1));
            JobWorker.claimNext();
            String second = [SELECT Idempotency_Key__c FROM Job__c WHERE Id = :jobId].Idempotency_Key__c;

            Assert.areEqual(36, first?.length(), 'A UUID: ' + first);
            Assert.areEqual(first, second, 'The retry keeps the key');
        }
    }

    @IsTest
    static void sendsTheJobKeyInTheEndpointHeader() {
        System.runAs(ReplayrTestAccess.runner()) {
            setIdempotencyHeader('Idempotency-Key');
            Job__c job = newJob('Processing', true, 1);
            job.Idempotency_Key__c = '3f2b9c1e-0000-4000-8000-000000000001';
            insert job;
            StatusMock mock = new StatusMock(201, null);
            Test.setMock(HttpCalloutMock.class, mock);

            runLink(job.Id);

            Assert.areEqual(job.Idempotency_Key__c, mock.received.getHeader('Idempotency-Key'), 'The job key, unchanged');
            Assert.areEqual('Succeeded', reload(job.Id).Status__c, 'Sent');
        }
    }

    @IsTest
    static void sendsNoKeyWhenTheEndpointNamesNoHeader() {
        System.runAs(ReplayrTestAccess.runner()) {
            Job__c job = newJob('Processing', true, 1);
            job.Idempotency_Key__c = '3f2b9c1e-0000-4000-8000-000000000002';
            insert job;
            StatusMock mock = new StatusMock(201, null);
            Test.setMock(HttpCalloutMock.class, mock);

            runLink(job.Id);

            Assert.isNull(mock.received.getHeader('Idempotency-Key'), 'No header configured, none sent');
        }
    }

    @IsTest
    static void neverSendsWithoutTheKeyTheEndpointAsksFor() {
        System.runAs(ReplayrTestAccess.runner()) {
            setIdempotencyHeader('Idempotency-Key');
            Job__c job = processing(true, 1);
            StatusMock mock = new StatusMock(201, null);
            Test.setMock(HttpCalloutMock.class, mock);

            runLink(job.Id);

            Assert.areEqual(0, mock.calls, 'Not sent');
            Job__c result = reload(job.Id);
            Assert.areEqual('Failed', result.Status__c, 'Final, not retried, though the job is Retry-safe');
            Assert.isNull(result.Next_Attempt_At__c, 'No retry planned');
            Assert.isTrue(result.Result__c.contains('no valid idempotency key'), 'Says why: ' + result.Result__c);
            Assert.areEqual('Not_Sent', [SELECT Outcome__c FROM Job_Log__c WHERE Job__c = :job.Id].Outcome__c, 'Logged as not sent');
        }
    }

    @IsTest
    static void claimTakesDueRetriesButNotFutureOnes() {
        System.runAs(ReplayrTestAccess.runner()) {
            List<Job__c> jobs = new List<Job__c>();
            for (Integer i = 0; i < 200; i++) {
                Job__c job = newJob('Retry_Wait', true, 1);
                job.Next_Attempt_At__c = System.now().addMinutes(i < 100 ? -1 : 30);
                jobs.add(job);
            }
            insert jobs;

            Job__c claimed = JobWorker.claimNext();

            Job__c saved = [SELECT Status__c, Attempts__c, Next_Attempt_At__c FROM Job__c WHERE Id = :claimed.Id];
            Assert.areEqual('Processing', saved.Status__c, 'A due retry is claimed');
            Assert.areEqual(2, saved.Attempts__c, 'Counted as the second attempt');
            Assert.isNull(saved.Next_Attempt_At__c, 'No longer waiting');
            Assert.areEqual(
                100,
                [SELECT COUNT() FROM Job__c WHERE Status__c = 'Retry_Wait' AND Next_Attempt_At__c > :System.now()],
                'Future retries untouched'
            );
        }
    }

    @IsTest
    static void idleChainWakesUpForARetryDueSoon() {
        System.runAs(ReplayrTestAccess.runner()) {
            Job__c job = newJob('Retry_Wait', true, 1);
            job.Next_Attempt_At__c = System.now().addMinutes(3);
            insert job;

            Test.startTest();
            Id started = JobWorker.start();
            Integer enqueued = Limits.getQueueableJobs();
            Test.stopTest();

            Assert.isNull(started, 'Nothing is due yet');
            Assert.areEqual(1, enqueued, 'One delayed link to wake up');
        }
    }

    @IsTest
    static void idleChainLeavesLongWaitsToThePoller() {
        System.runAs(ReplayrTestAccess.runner()) {
            Job__c job = newJob('Retry_Wait', true, 4);
            job.Next_Attempt_At__c = System.now().addMinutes(30);
            insert job;

            Test.startTest();
            JobWorker.start();
            Integer enqueued = Limits.getQueueableJobs();
            Test.stopTest();

            Assert.areEqual(0, enqueued, 'Over ten minutes: no delayed link');
        }
    }

    @IsTest
    static void nothingWaitingMeansNoWakeUp() {
        System.runAs(ReplayrTestAccess.runner()) {
            Test.startTest();
            JobWorker.start();
            Integer enqueued = Limits.getQueueableJobs();
            Test.stopTest();

            Assert.areEqual(0, enqueued, 'Nothing to wake up for');
        }
    }

    @IsTest
    static void wakeUpLinkContinuesTheChain() {
        System.runAs(ReplayrTestAccess.runner()) {
            Job__c job = newJob('Retry_Wait', true, 1);
            job.Next_Attempt_At__c = System.now().addMinutes(-1);
            insert job;

            // Run directly: inside a test a Queueable can't enqueue the next link, so the chain would roll
            // its claim back. A link without a job attaches no finalizer, so this is allowed
            StatusMock mock = new StatusMock(200, null);
            Test.setMock(HttpCalloutMock.class, mock);
            Test.startTest();
            new JobWorker(null).execute(null);
            Assert.areEqual('Processing', reload(job.Id).Status__c, 'The due retry was claimed');
            Test.stopTest();

            Assert.areEqual(1, mock.calls, 'Its link sent it once');
            Assert.areEqual('Succeeded', reload(job.Id).Status__c, 'The retry went through');
        }
    }
}
