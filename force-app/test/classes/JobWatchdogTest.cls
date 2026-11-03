@IsTest
private with sharing class JobWatchdogTest {
    private static final Integer MAX_ATTEMPTS = 3;

    private class OkMock implements HttpCalloutMock {
        public Integer calls = 0;

        public HttpResponse respond(HttpRequest request) {
            calls++;
            HttpResponse response = new HttpResponse();
            response.setStatusCode(200);
            response.setStatus('OK');
            return response;
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

    private static Job__c newJob(String status, Integer minutesAgo, Boolean retrySafe, Integer attempts) {
        return new Job__c(
            Endpoint__c = endpointId,
            Status__c = status,
            Method__c = 'PUT',
            Path__c = '/items',
            Started_At__c = System.now().addMinutes(-minutesAgo),
            Retry_Safe__c = retrySafe,
            Attempts__c = attempts
        );
    }

    private static Job__c insertJob(String status, Integer minutesAgo, Boolean retrySafe, Integer attempts) {
        Job__c job = newJob(status, minutesAgo, retrySafe, attempts);
        insert job;
        return job;
    }

    private static Job__c reload(Id jobId) {
        return [SELECT Status__c, Result__c, Next_Attempt_At__c FROM Job__c WHERE Id = :jobId];
    }

    @IsTest
    static void stuckJobThatIsNotRetrySafeIsOutcomeUnknown() {
        System.runAs(ReplayrTestAccess.runner()) {
            Job__c job = insertJob('Processing', 90, false, 1);

            Assert.areEqual(1, JobWatchdog.run(), 'One job settled');

            Job__c result = reload(job.Id);
            Assert.areEqual('Outcome_Unknown', result.Status__c, 'A person decides; never resent');
            Assert.areEqual(JobWatchdog.MESSAGE, result.Result__c, 'Says what happened');
            Assert.isNull(result.Next_Attempt_At__c, 'No retry planned');
            Job_Log__c log = [SELECT Outcome__c, Message__c FROM Job_Log__c WHERE Job__c = :job.Id];
            Assert.areEqual('Outcome_Unknown', log.Outcome__c, 'Logged as unknown');
        }
    }

    @IsTest
    static void stuckRetrySafeJobWaitsForAnotherAttempt() {
        System.runAs(ReplayrTestAccess.runner()) {
            Job__c job = insertJob('Processing', 90, true, 1);

            JobWatchdog.run();

            Job__c result = reload(job.Id);
            Assert.areEqual('Retry_Wait', result.Status__c, 'Resending is harmless');
            Assert.isNotNull(result.Next_Attempt_At__c, 'Retry planned');
            Assert.isTrue(result.Result__c.startsWith(JobWatchdog.MESSAGE), 'Says why: ' + result.Result__c);
        }
    }

    @IsTest
    static void stuckRetrySafeJobOnItsLastAttemptHasNoneLeft() {
        System.runAs(ReplayrTestAccess.runner()) {
            Job__c job = insertJob('Processing', 90, true, MAX_ATTEMPTS);

            JobWatchdog.run();

            Assert.areEqual('Dead', reload(job.Id).Status__c, 'Retries used up');
        }
    }

    @IsTest
    static void leavesRecentAndFinishedJobsAlone() {
        System.runAs(ReplayrTestAccess.runner()) {
            List<Job__c> jobs = new List<Job__c>{
                newJob('Processing', 10, false, 1),
                newJob('Processing', JobWatchdog.STUCK_MINUTES - 1, true, 1),
                newJob('Succeeded', 600, false, 1),
                newJob('Queued', 600, false, 0)
            };
            // Started at blank and just changed: not stuck (the fallback uses when it last changed). The positive
            // case can't be tested: a test can't set LastModifiedDate
            Job__c noStart = newJob('Processing', 0, false, 1);
            noStart.Started_At__c = null;
            jobs.add(noStart);
            insert jobs;

            Assert.areEqual(0, JobWatchdog.run(), 'Nothing settled');
            Assert.areEqual(0, [SELECT COUNT() FROM Job_Log__c], 'Nothing logged');
        }
    }

    @IsTest
    static void settlesTwoHundredStuckJobsInOneUpdateAndLeavesTheRestForNextHour() {
        System.runAs(ReplayrTestAccess.runner()) {
            List<Job__c> jobs = new List<Job__c>();
            for (Integer i = 0; i <= JobWatchdog.BATCH_SIZE; i++) {
                jobs.add(newJob('Processing', 120, Math.mod(i, 2) == 0, 1));
            }
            insert jobs;

            Integer dmlBefore = Limits.getDmlStatements();
            Integer queriesBefore = Limits.getQueries();
            Integer settled = JobWatchdog.run();

            Assert.areEqual(JobWatchdog.BATCH_SIZE, settled, 'One batch settled');
            Assert.areEqual(2, Limits.getDmlStatements() - dmlBefore, 'One update and one insert');
            Assert.areEqual(1, Limits.getQueries() - queriesBefore, 'One query');
            Assert.areEqual(1, [SELECT COUNT() FROM Job__c WHERE Status__c = 'Processing'], 'The rest waits for the next hour');
            Assert.areEqual(JobWatchdog.BATCH_SIZE, [SELECT COUNT() FROM Job_Log__c], 'One log row each');
            for (Job__c job : [SELECT Status__c, Retry_Safe__c FROM Job__c WHERE Status__c != 'Processing']) {
                Assert.areEqual(job.Retry_Safe__c ? 'Retry_Wait' : 'Outcome_Unknown', job.Status__c, 'Each settled by its own Retry-safe copy');
            }
        }
    }

    @IsTest
    static void pollRunsTheWatchdogAndRecordsTheHeartbeat() {
        System.runAs(ReplayrTestAccess.runner()) {
            Job__c job = insertJob('Processing', 90, false, 1);

            Test.startTest();
            new JobPoller().execute(null);
            Test.stopTest();

            Assert.areEqual('Outcome_Unknown', reload(job.Id).Status__c, 'Watchdog ran in the poll');
        }
        Assert.isNotNull(Replayr_Settings__c.getOrgDefaults().Poller_Last_Run__c, 'Heartbeat: poller and watchdog ran');
    }

    @IsTest
    static void lateLinkForAnEarlierAttemptNeverCallsTheJob() {
        System.runAs(ReplayrTestAccess.runner()) {
            // Moved on by the watchdog and claimed again: now on attempt 2
            Job__c job = insertJob('Processing', 0, true, 2);
            OkMock mock = new OkMock();
            Test.setMock(HttpCalloutMock.class, mock);

            Test.startTest();
            System.enqueueJob(new JobWorker(job.Id, 1));
            Test.stopTest();

            Assert.areEqual(0, mock.calls, 'The attempt-1 link stops');
            Assert.areEqual('Processing', reload(job.Id).Status__c, 'Left to the attempt-2 link');
        }
    }

    @IsTest
    static void lateFinalizerNeverRecordsOverALaterAttempt() {
        System.runAs(ReplayrTestAccess.runner()) {
            Job__c job = insertJob('Processing', 0, true, 2);

            new JobFinalizer(job.Id, 1).execute(new CrashedContext());

            Assert.areEqual('Processing', reload(job.Id).Status__c, 'Attempt 2 keeps the job');
            Assert.areEqual(0, [SELECT COUNT() FROM Job_Log__c], 'Nothing recorded for attempt 1');
        }
    }

    private class CrashedContext implements FinalizerContext {
        public Id getAsyncApexJobId() {
            return null;
        }

        public Exception getException() {
            return new DmlException('Simulated crash');
        }

        public ParentJobResult getResult() {
            return ParentJobResult.UNHANDLED_EXCEPTION;
        }

        public String getRequestId() {
            return null;
        }
    }

    // Stands in for the watchdog settling the job while this slow call is in flight
    private class SettledMeanwhileMock implements HttpCalloutMock {
        private final Id jobId;

        SettledMeanwhileMock(Id jobId) {
            this.jobId = jobId;
        }

        public HttpResponse respond(HttpRequest request) {
            update new Job__c(Id = jobId, Status__c = 'Outcome_Unknown', Result__c = JobWatchdog.MESSAGE);
            HttpResponse response = new HttpResponse();
            response.setStatusCode(200);
            response.setStatus('OK');
            return response;
        }
    }

    @IsTest
    static void lateResultIsLoggedButNeverOverwritesTheNewerState() {
        System.runAs(ReplayrTestAccess.runner()) {
            Job__c job = insertJob('Processing', 0, false, 1);
            Test.setMock(HttpCalloutMock.class, new SettledMeanwhileMock(job.Id));

            Test.startTest();
            System.enqueueJob(new JobWorker(job.Id, 1));
            Test.stopTest();

            Job__c result = reload(job.Id);
            Assert.areEqual('Outcome_Unknown', result.Status__c, 'The newer state stands');
            Assert.areEqual(JobWatchdog.MESSAGE, result.Result__c, 'Not overwritten');
            Job_Log__c log = [SELECT Outcome__c, Message__c FROM Job_Log__c WHERE Job__c = :job.Id];
            Assert.areEqual('Succeeded', log.Outcome__c, 'What really happened is still logged');
            Assert.isTrue(log.Message__c.startsWith('(Arrived after the job moved on'), 'Marked as late: ' + log.Message__c);
        }
    }

    @IsTest
    static void linkForTheCurrentAttemptCallsTheJob() {
        System.runAs(ReplayrTestAccess.runner()) {
            Job__c job = insertJob('Processing', 0, true, 2);
            OkMock mock = new OkMock();
            Test.setMock(HttpCalloutMock.class, mock);

            Test.startTest();
            System.enqueueJob(new JobWorker(job.Id, 2));
            Test.stopTest();

            Assert.areEqual(1, mock.calls, 'Sent once');
            Assert.areEqual('Succeeded', reload(job.Id).Status__c, 'Recorded');
        }
    }
}
