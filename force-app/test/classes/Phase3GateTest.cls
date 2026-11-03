/**
 * The phase 3 gate: governor-limit and replay tests pass, and a worker that dies after its
 * callout never causes a second send. End to end, where the step tests check one piece at a time.
 */
@IsTest
private with sharing class Phase3GateTest {
    private static final Integer BATCH = 200;
    private static final String KEY = '3f2b9c1e-0000-4000-8000-0000000000aa';

    // Answers with a set status and remembers every call and the idempotency key it carried
    private class CountingMock implements HttpCalloutMock {
        private final Integer code;
        public Integer calls = 0;
        public List<String> keys = new List<String>();

        CountingMock(Integer code) {
            this.code = code;
        }

        public HttpResponse respond(HttpRequest request) {
            calls++;
            keys.add(request.getHeader('Idempotency-Key'));
            HttpResponse response = new HttpResponse();
            response.setStatusCode(code);
            response.setStatus('Status ' + code);
            return response;
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
            Provider__c provider = new Provider__c(Name = 'Shop', Named_Credential__c = 'Shop_API', Key__c = 'shop');
            insert provider;
            insert new Endpoint__c(
                Name = 'Orders',
                Provider__c = provider.Id,
                Method__c = 'POST',
                Path__c = '/orders',
                Idempotency_Header__c = 'Idempotency-Key',
                Key__c = 'shop-orders'
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
            Method__c = 'POST',
            Path__c = '/orders',
            Request_Body__c = '{"order": 1}',
            Retry_Safe__c = retrySafe,
            Attempts__c = attempts,
            Idempotency_Key__c = KEY
        );
    }

    // A job whose link started two hours ago: if nothing recorded its result, the watchdog would settle it
    private static Job__c inFlight(Boolean retrySafe) {
        Job__c job = newJob('Processing', retrySafe, 1);
        job.Started_At__c = System.now().addHours(-2);
        insert job;
        return job;
    }

    private static List<Job__c> jobs(String status, Integer count) {
        List<Job__c> made = new List<Job__c>();
        for (Integer i = 0; i < count; i++) {
            made.add(newJob(status, false, 1));
        }
        return made;
    }

    private static Job__c reload(Id jobId) {
        return [SELECT Status__c, Attempts__c, Idempotency_Key__c, HTTP_Status__c, Next_Attempt_At__c FROM Job__c WHERE Id = :jobId];
    }

    private static List<String> logOutcomes(Id jobId) {
        List<String> outcomes = new List<String>();
        for (Job_Log__c log : [SELECT Outcome__c FROM Job_Log__c WHERE Job__c = :jobId ORDER BY CreatedDate, Id]) {
            outcomes.add(log.Outcome__c);
        }
        return outcomes;
    }

    // Afterwards nothing picks the job up: the watchdog has nothing to settle and no chain claims anything
    private static void assertNothingResendsIt() {
        Assert.areEqual(0, JobWatchdog.run(), 'The watchdog finds nothing to settle: the result was recorded');
        Assert.isNull(JobWorker.start(), 'No chain claims it again');
    }

    private static String runLinkThatDies(JobWorker link) {
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
    static void onePollUnderLoadStaysWellInsideTheLimits() {
        System.runAs(ReplayrTestAccess.runner()) {
            List<Job__c> load = new List<Job__c>();
            for (Job__c job : jobs('Processing', BATCH)) {
                job.Started_At__c = System.now().addHours(-2);
                load.add(job);
            }
            load.addAll(jobs('Queued', BATCH));
            for (Job__c job : jobs('Retry_Wait', BATCH)) {
                job.Next_Attempt_At__c = System.now().addMinutes(-5);
                load.add(job);
            }
            load.addAll(jobs('Succeeded', BATCH));
            insert load;
            CountingMock mock = new CountingMock(200);
            Test.setMock(HttpCalloutMock.class, mock);

            Test.startTest();
            new JobPoller().execute(null);
            Integer queries = Limits.getQueries();
            Integer dmlRows = Limits.getDmlRows();
            Integer cpu = Limits.getCpuTime();
            Test.stopTest();

            Assert.isTrue(queries <= 25, 'Queries: ' + queries + ' of ' + Limits.getLimitQueries());
            Assert.isTrue(dmlRows <= 1000, 'DML rows: ' + dmlRows + ' of ' + Limits.getLimitDmlRows());
            Assert.isTrue(cpu <= 5000, 'CPU ms: ' + cpu + ' of ' + Limits.getLimitCpuTime());
            Assert.areEqual(BATCH, [SELECT COUNT() FROM Job__c WHERE Status__c = 'Outcome_Unknown'], 'The watchdog settled every stuck job');
            Assert.areEqual(1, mock.calls, 'The chain the poll started sent one job');
            Assert.areEqual(
                2 * BATCH - 1,
                [SELECT COUNT() FROM Job__c WHERE Status__c IN ('Queued', 'Retry_Wait')],
                'Exactly one queued job or due retry was taken'
            );
            Assert.isNotNull(Replayr_Settings__c.getOrgDefaults().Poller_Last_Run__c, 'Every part of the poll ran: heartbeat written');
            Assert.isNotNull(Replayr_Settings__c.getOrgDefaults().Last_Purge_Started__c, 'The daily purge was started');
        }
    }

    @IsTest
    static void aPurgeBatchOfTwoHundredJobsWithTheirLogsStaysInsideTheRowBudget() {
        System.runAs(ReplayrTestAccess.runner()) {
            List<Job__c> finished = jobs('Failed', BATCH);
            insert finished;
            insert logsFor(finished, 10);

            Integer rowsBefore = Limits.getDmlRows();
            new JobPurge(System.now().addMinutes(1)).execute(null, finished);
            Integer rows = Limits.getDmlRows() - rowsBefore;

            Assert.areEqual(0, [SELECT COUNT() FROM Job__c], 'All jobs purged');
            Assert.areEqual(0, [SELECT COUNT() FROM Job_Log__c], 'And their 2,000 log rows');
            Assert.isTrue(rows <= 2 * (BATCH + 10 * BATCH), 'Deleted and emptied from the bin, nothing more: ' + rows);
        }
    }

    @IsTest
    static void aPurgeBatchWhoseLogsExceedTheBudgetDeletesFewerJobsAndStaysInside() {
        System.runAs(ReplayrTestAccess.runner()) {
            List<Job__c> finished = jobs('Failed', BATCH);
            insert finished;
            insert logsFor(finished, 10);
            // Room for half the jobs and their logs (11 rows each)
            JobPurge.rowBudget = 11 * BATCH / 2;

            new JobPurge(System.now().addMinutes(1)).execute(null, finished);

            Assert.areEqual(BATCH / 2, [SELECT COUNT() FROM Job__c], 'The other half waits for the next purge');
        }
    }

    private static List<Job_Log__c> logsFor(List<Job__c> jobs, Integer each) {
        List<Job_Log__c> logs = new List<Job_Log__c>();
        for (Job__c job : jobs) {
            for (Integer attempt = 0; attempt < each; attempt++) {
                logs.add(JobLogs.newLog(job.Id, JobWorker.FAILED, 503, 'HTTP 503', 10));
            }
        }
        return logs;
    }

    @IsTest
    static void twoHundredReplaysAreOneUpdateAndOneLogInsertAndKeepTheirKeys() {
        System.runAs(ReplayrTestAccess.runner()) {
            List<Job__c> dead = new List<Job__c>();
            for (Integer i = 0; i < BATCH; i++) {
                Job__c job = newJob('Dead', true, 5);
                job.Idempotency_Key__c = 'key-' + i;
                dead.add(job);
            }
            insert dead;

            Integer dmlBefore = Limits.getDmlStatements();
            Integer queriesBefore = Limits.getQueries();
            List<JobActions.Result> results = JobActions.replay(new List<Id>(new Map<Id, Job__c>(dead).keySet()), false);
            Integer dml = Limits.getDmlStatements() - dmlBefore;
            Integer queries = Limits.getQueries() - queriesBefore;

            for (JobActions.Result result : results) {
                Assert.isTrue(result.done, 'Replayed: ' + result.message);
            }
            // Publishing the work-waiting event counts as a DML statement
            Assert.areEqual(3, dml, 'One update, one log insert, one event');
            Assert.areEqual(1, queries, 'One query');
            Map<Id, Job__c> before = new Map<Id, Job__c>(dead);
            for (Job__c saved : [SELECT Status__c, Attempts__c, Idempotency_Key__c FROM Job__c]) {
                Assert.areEqual('Queued', saved.Status__c, 'Queued');
                Assert.areEqual(before.get(saved.Id).Idempotency_Key__c, saved.Idempotency_Key__c, 'Its own key kept');
                Assert.areEqual(5, saved.Attempts__c, 'History kept');
            }
            Assert.areEqual(BATCH, [SELECT COUNT() FROM Job_Log__c WHERE Outcome__c = 'Replay_Requested'], 'One log row each');
            Job__c claimed = JobWorker.claimNext();
            Assert.areEqual(before.get(claimed.Id).Idempotency_Key__c, reload(claimed.Id).Idempotency_Key__c, 'Claimed with its own key');
            Assert.areEqual(6, reload(claimed.Id).Attempts__c, 'The replay is one more attempt');
        }
    }

    @IsTest
    static void aFailedCallIsReplayedAndSentAgainWithTheSameKey() {
        System.runAs(ReplayrTestAccess.runner()) {
            Job__c job = newJob('Queued', false, 0);
            job.Idempotency_Key__c = null;
            insert job;
            // Attempt 1 through the claim (which makes the key) and record(), the worker's own path: a test may
            // run only one link, so the replayed attempt is the one actually sent
            JobWorker.claimNext();
            String firstKey = reload(job.Id).Idempotency_Key__c;
            JobWorker.record(job.Id, new JobWorker.Attempt('Failed', 'Failed', 400, 'HTTP 400 Bad Request', 20));
            Assert.areEqual('Failed', reload(job.Id).Status__c, 'Final: not Retry-safe, and a 400');

            JobActions.Result replay = JobActions.replay(new List<Id>{ job.Id }, true)[0];
            CountingMock mock = new CountingMock(201);
            Test.setMock(HttpCalloutMock.class, mock);
            Test.startTest();
            JobWorker.start();
            Test.stopTest();

            Assert.isTrue(replay.done, 'Replayed once the duplicate risk was confirmed');
            Assert.areEqual(1, mock.calls, 'Sent once');
            Assert.areEqual(new List<String>{ firstKey }, mock.keys, 'With the key attempt 1 had');
            Job__c saved = reload(job.Id);
            Assert.areEqual('Succeeded', saved.Status__c, 'Attempt 2 went through');
            Assert.areEqual(2, saved.Attempts__c, 'Two attempts');
            Assert.areEqual(new List<String>{ 'Failed', 'Replay_Requested', 'Succeeded' }, logOutcomes(job.Id), 'The whole story in the log');
        }
    }

    @IsTest
    static void aWorkerDyingAfterASuccessfulRetrySafeCallNeverResendsIt() {
        assertDeathAfterTheCallout(201, true, 'Succeeded');
    }

    @IsTest
    static void aWorkerDyingAfterASuccessfulCallNeverResendsIt() {
        assertDeathAfterTheCallout(201, false, 'Succeeded');
    }

    @IsTest
    static void aWorkerDyingAfterAFailedCallThatIsNotRetrySafeNeverResendsIt() {
        assertDeathAfterTheCallout(503, false, 'Failed');
    }

    @IsTest
    static void aWorkerDyingAfterAFailedRetrySafeCallWaitsForAPlannedRetry() {
        assertDeathAfterTheCallout(503, true, 'Retry_Wait');
    }

    private static void assertDeathAfterTheCallout(Integer code, Boolean retrySafe, String expected) {
        System.runAs(ReplayrTestAccess.runner()) {
            Job__c job = inFlight(retrySafe);
            CountingMock mock = new CountingMock(code);
            Test.setMock(HttpCalloutMock.class, mock);
            JobWorker link = new JobWorker(job.Id, 1);
            link.crashAfterCallout = true;

            String crash = runLinkThatDies(link);

            Assert.isTrue(crash?.endsWith('SimulatedCrashException'), 'The link really died after its callout: ' + crash);
            Job__c saved = reload(job.Id);
            Assert.areEqual(expected, saved.Status__c, 'The real result, recorded by the finalizer');
            Assert.areEqual(code, saved.HTTP_Status__c, 'The status that came back');
            if (expected == 'Retry_Wait') {
                Assert.isTrue(saved.Next_Attempt_At__c > System.now(), 'Retried later, on purpose: a response arrived and the job is Retry-safe');
            }
            assertNothingResendsIt();
            Assert.areEqual(1, mock.calls, 'Sent exactly once');
        }
    }

    @IsTest
    static void aWorkerDyingDuringANonRetrySafeCallLeavesItForAPerson() {
        System.runAs(ReplayrTestAccess.runner()) {
            Job__c job = inFlight(false);
            CrashingMock mock = new CrashingMock();
            Test.setMock(HttpCalloutMock.class, mock);

            String crash = runLinkThatDies(new JobWorker(job.Id, 1));

            Assert.isTrue(crash?.endsWith('CrashTestException'), 'The link really died during its callout: ' + crash);
            Assert.areEqual('Outcome_Unknown', reload(job.Id).Status__c, 'Only a person clears it');
            assertNothingResendsIt();
            Assert.areEqual(1, mock.calls, 'Never sent again');
        }
    }

    @IsTest
    static void aWorkerDyingDuringARetrySafeCallWaitsForARetry() {
        System.runAs(ReplayrTestAccess.runner()) {
            Job__c job = inFlight(true);
            CrashingMock mock = new CrashingMock();
            Test.setMock(HttpCalloutMock.class, mock);

            String crash = runLinkThatDies(new JobWorker(job.Id, 1));

            Assert.isTrue(crash?.endsWith('CrashTestException'), 'The link really died during its callout: ' + crash);
            Job__c saved = reload(job.Id);
            Assert.areEqual('Retry_Wait', saved.Status__c, 'Resending is harmless, so it is retried later');
            Assert.isTrue(saved.Next_Attempt_At__c > System.now(), 'At a planned time, not at once');
            assertNothingResendsIt();
            Assert.areEqual(1, mock.calls, 'Not sent again now');
        }
    }
}
