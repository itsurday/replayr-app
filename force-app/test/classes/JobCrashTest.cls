/**
 * Crashes real worker links and lets the platform run the real finalizer. Test.stopTest() re-throws the
 * link's exception, so each test catches it. An uncatchable limit exception would fail the test itself,
 * so limit crashes rely on spike P0.3 (docs/decisions.md), run in a real org.
 */
@IsTest
private with sharing class JobCrashTest {
    private class CrashTestException extends Exception {
    }

    private class CountingMock implements HttpCalloutMock {
        public Integer calls = 0;

        public HttpResponse respond(HttpRequest request) {
            calls++;
            HttpResponse response = new HttpResponse();
            response.setStatusCode(201);
            response.setStatus('Created');
            return response;
        }
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
        User runner = ReplayrTestAccess.createRunner();
        System.runAs(runner) {
            Provider__c provider = new Provider__c(Name = 'P', Named_Credential__c = 'Test_API');
            insert provider;
            insert new Endpoint__c(Name = 'Get', Provider__c = provider.Id, Method__c = 'GET', Path__c = '/get');
        }
    }

    private static Job__c insertJob(String status) {
        Job__c job = new Job__c(
            Endpoint__c = [SELECT Id FROM Endpoint__c LIMIT 1].Id,
            Status__c = status,
            Method__c = 'GET',
            Path__c = '/get'
        );
        insert job;
        return job;
    }

    private static String runAndCatchCrash(JobWorker link) {
        Test.startTest();
        System.enqueueJob(link);
        try {
            Test.stopTest();
        } catch (Exception e) {
            return e.getTypeName();
        }
        return null;
    }

    private static Job__c reload(Id jobId) {
        return [SELECT Status__c, HTTP_Status__c, Result__c FROM Job__c WHERE Id = :jobId];
    }

    private static List<Job_Log__c> logs(Id jobId) {
        return [SELECT Outcome__c, HTTP_Status__c FROM Job_Log__c WHERE Job__c = :jobId];
    }

    @IsTest
    static void deathAfterTheCalloutReturnedIsRecordedFromTheFinalizer() {
        System.runAs(ReplayrTestAccess.runner()) {
            Job__c job = insertJob('Processing');
            CountingMock mock = new CountingMock();
            Test.setMock(HttpCalloutMock.class, mock);
            JobWorker link = new JobWorker(job.Id);
            link.crashAfterCallout = true;

            String crash = runAndCatchCrash(link);

            Assert.isNotNull(crash, 'stopTest re-threw the crash');
            Assert.isTrue(crash.endsWith('SimulatedCrashException'), 'The link really crashed: ' + crash);
            Assert.areEqual(1, mock.calls, 'Sent once, never resent');
            Job__c result = reload(job.Id);
            Assert.areEqual('Succeeded', result.Status__c, 'Real result from the finalizer, not Outcome unknown');
            Assert.areEqual(201, result.HTTP_Status__c, 'Real HTTP status survived the crash');
            Assert.isTrue(result.Result__c.startsWith('(Recorded after the worker crashed'), 'Marked: ' + result.Result__c);
            List<Job_Log__c> rows = logs(job.Id);
            Assert.areEqual(1, rows.size(), 'Exactly one log row');
            Assert.areEqual('Succeeded', rows[0].Outcome__c, 'Log outcome');
        }
    }

    @IsTest
    static void deathDuringTheCalloutLeavesOutcomeUnknownAndNeverResends() {
        System.runAs(ReplayrTestAccess.runner()) {
            Job__c job = insertJob('Processing');
            CrashingMock mock = new CrashingMock();
            Test.setMock(HttpCalloutMock.class, mock);

            String crash = runAndCatchCrash(new JobWorker(job.Id));

            Assert.isNotNull(crash, 'stopTest re-threw the crash');
            Assert.isTrue(crash.endsWith('CrashTestException'), 'The link really crashed: ' + crash);
            Assert.areEqual(1, mock.calls, 'Never resent');
            Job__c result = reload(job.Id);
            Assert.areEqual('Outcome_Unknown', result.Status__c, 'Non-Retry-safe job left in Outcome unknown');
            Assert.isNull(result.HTTP_Status__c, 'No response');
            Assert.areEqual('Outcome_Unknown', logs(job.Id)[0].Outcome__c, 'Log outcome');
        }
    }

    @IsTest
    static void afterACrashExactlyOneChainContinues() {
        System.runAs(ReplayrTestAccess.runner()) {
            Job__c crashed = insertJob('Processing');
            insertJob('Queued');
            insertJob('Queued');
            Test.setMock(HttpCalloutMock.class, new CountingMock());
            JobWorker link = new JobWorker(crashed.Id);
            link.crashAfterCallout = true;

            String crash = runAndCatchCrash(link);

            Assert.isNotNull(crash, 'The link really crashed, so the finalizer did the restart');
            Assert.isTrue(reload(crashed.Id).Result__c.startsWith('(Recorded after the worker crashed'), 'Finalizer ran');
            // Tests run one level of async work, so the restarted link is enqueued but does not run here
            Assert.areEqual(
                1,
                [SELECT COUNT() FROM Job__c WHERE Status__c = 'Processing'],
                'Exactly one next job claimed, so exactly one chain continues'
            );
            Assert.areEqual(1, [SELECT COUNT() FROM Job__c WHERE Status__c = 'Queued'], 'The other job is left Queued');
        }
    }
}
