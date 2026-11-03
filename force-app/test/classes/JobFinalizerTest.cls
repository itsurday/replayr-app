@IsTest
private with sharing class JobFinalizerTest {
    private class FakeContext implements FinalizerContext {
        private final ParentJobResult result;
        private final Exception crash;

        FakeContext(ParentJobResult result, Exception crash) {
            this.result = result;
            this.crash = crash;
        }

        public Id getAsyncApexJobId() {
            return null;
        }

        public Exception getException() {
            return crash;
        }

        public ParentJobResult getResult() {
            return result;
        }

        public String getRequestId() {
            return null;
        }
    }

    private class OkMock implements HttpCalloutMock {
        public HttpResponse respond(HttpRequest request) {
            HttpResponse response = new HttpResponse();
            response.setStatusCode(200);
            return response;
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

    private static FakeContext crashed() {
        return new FakeContext(ParentJobResult.UNHANDLED_EXCEPTION, new QueryException('Apex CPU time limit exceeded'));
    }

    private static Job__c reload(Id jobId) {
        return [SELECT Status__c, HTTP_Status__c, Result__c FROM Job__c WHERE Id = :jobId];
    }

    private static List<Job_Log__c> logs(Id jobId) {
        return [SELECT Outcome__c, HTTP_Status__c, Message__c FROM Job_Log__c WHERE Job__c = :jobId];
    }

    @IsTest
    static void doesNothingWhenTheLinkSucceeded() {
        System.runAs(ReplayrTestAccess.runner()) {
            Job__c job = insertJob('Processing');

            new JobFinalizer(job.Id).execute(new FakeContext(ParentJobResult.SUCCESS, null));

            Assert.areEqual('Processing', reload(job.Id).Status__c, 'Untouched');
            Assert.areEqual(0, logs(job.Id).size(), 'No log row');
        }
    }

    @IsTest
    static void doesNothingWhenTheOutcomeIsAlreadyRecorded() {
        System.runAs(ReplayrTestAccess.runner()) {
            Job__c job = insertJob('Succeeded');

            new JobFinalizer(job.Id).execute(crashed());

            Assert.areEqual('Succeeded', reload(job.Id).Status__c, 'Untouched');
            Assert.areEqual(0, logs(job.Id).size(), 'No second log row');
        }
    }

    @IsTest
    static void runningTwiceRecordsTheJobOnce() {
        System.runAs(ReplayrTestAccess.runner()) {
            Job__c job = insertJob('Processing');
            JobFinalizer finalizer = new JobFinalizer(job.Id);

            finalizer.execute(crashed());
            finalizer.execute(crashed());

            Assert.areEqual(1, logs(job.Id).size(), 'One log row');
        }
    }

    @IsTest
    static void crashBeforeTheCalloutIsFailedAndNotSent() {
        System.runAs(ReplayrTestAccess.runner()) {
            Job__c job = insertJob('Processing');

            new JobFinalizer(job.Id).execute(crashed());

            Job__c result = reload(job.Id);
            Assert.areEqual('Failed', result.Status__c, 'Not requeued, so a link that always crashes cannot loop');
            Assert.isTrue(result.Result__c.contains('nothing was sent'), 'Says nothing was sent: ' + result.Result__c);
            Assert.areEqual('Not_Sent', logs(job.Id)[0].Outcome__c, 'Log outcome');
        }
    }

    @IsTest
    static void crashBeforeTheCalloutIsNotRetriedEvenWhenRetrySafe() {
        System.runAs(ReplayrTestAccess.runner()) {
            Job__c job = insertJob('Processing');
            update new Job__c(Id = job.Id, Retry_Safe__c = true, Attempts__c = 1);

            new JobFinalizer(job.Id).execute(crashed());

            Job__c result = [SELECT Status__c, Next_Attempt_At__c FROM Job__c WHERE Id = :job.Id];
            Assert.areEqual('Failed', result.Status__c, 'Owner decision: such crashes are rarely temporary');
            Assert.isNull(result.Next_Attempt_At__c, 'No retry planned');
        }
    }

    @IsTest
    static void crashDuringTheCalloutIsOutcomeUnknown() {
        System.runAs(ReplayrTestAccess.runner()) {
            Job__c job = insertJob('Processing');
            JobFinalizer finalizer = new JobFinalizer(job.Id);
            finalizer.calling();

            finalizer.execute(crashed());

            Assert.areEqual('Outcome_Unknown', reload(job.Id).Status__c, 'May have arrived, so never resent');
            Assert.areEqual('Outcome_Unknown', logs(job.Id)[0].Outcome__c, 'Log outcome');
        }
    }

    @IsTest
    static void crashWhileWritingTheResponseKeepsTheResultAndSaysNothingWasSaved() {
        System.runAs(ReplayrTestAccess.runner()) {
            Job__c job = insertJob('Processing');
            JobFinalizer finalizer = new JobFinalizer(job.Id);
            finalizer.calling();
            // What the worker hands over just before it writes the response
            JobWorker.Attempt returned = new JobWorker.Attempt('Succeeded', 'Succeeded', 200, 'HTTP 200 OK', 50);
            finalizer.returned(returned.withNote('Response not saved: the worker stopped while writing it.'));

            finalizer.execute(crashed());

            Job__c result = reload(job.Id);
            Assert.areEqual('Succeeded', result.Status__c, 'The call succeeded, so it is never resent');
            Assert.isTrue(
                logs(job.Id)[0].Message__c.endsWith('HTTP 200 OK. Response not saved: the worker stopped while writing it.'),
                'Says the response was not saved'
            );
        }
    }

    @IsTest
    static void crashAfterTheCalloutRecordsTheRealResult() {
        System.runAs(ReplayrTestAccess.runner()) {
            Job__c job = insertJob('Processing');
            JobFinalizer finalizer = new JobFinalizer(job.Id);
            finalizer.calling();
            finalizer.returned(new JobWorker.Attempt('Succeeded', 'Succeeded', 201, 'HTTP 201 Created', 120));

            finalizer.execute(crashed());

            Job__c result = reload(job.Id);
            Assert.areEqual('Succeeded', result.Status__c, 'Real result, not Outcome unknown');
            Assert.areEqual(201, result.HTTP_Status__c, 'Real HTTP status');
            List<Job_Log__c> rows = logs(job.Id);
            Assert.areEqual(1, rows.size(), 'One log row');
            Assert.isTrue(rows[0].Message__c.startsWith('(Recorded after the worker crashed'), 'Marked first');
            Assert.isTrue(rows[0].Message__c.endsWith('HTTP 201 Created'), 'Real message kept: ' + rows[0].Message__c);
        }
    }

    @IsTest
    static void fallsBackToTheStatusWhenTheFullRecordFails() {
        System.runAs(ReplayrTestAccess.runner()) {
            Job__c job = insertJob('Processing');
            JobFinalizer finalizer = new JobFinalizer(job.Id);
            // A missing log outcome makes the log insert fail, as missing access to the log would
            finalizer.returned(new JobWorker.Attempt('Succeeded', null, 200, 'HTTP 200 OK', 10));

            finalizer.execute(crashed());

            Assert.areEqual('Succeeded', reload(job.Id).Status__c, 'Job still leaves Processing');
            Assert.areEqual(0, logs(job.Id).size(), 'The failed log row was not kept');
        }
    }

    @IsTest
    static void crashTextIsNeverStoredForOrdinaryExceptions() {
        System.runAs(ReplayrTestAccess.runner()) {
            Job__c job = insertJob('Processing');
            JobFinalizer finalizer = new JobFinalizer(job.Id);
            finalizer.calling();
            Exception leaky = new JSONException('Unexpected token at /v1?api_key=SECRET123');

            finalizer.execute(new FakeContext(ParentJobResult.UNHANDLED_EXCEPTION, leaky));

            String result = reload(job.Id).Result__c;
            Assert.isFalse(result.contains('SECRET123'), 'Exception message not stored: ' + result);
            Assert.isTrue(result.contains('System.JSONException'), 'Exception type kept: ' + result);
        }
    }

    @IsTest
    static void crashWithoutAnExceptionIsStillRecorded() {
        System.runAs(ReplayrTestAccess.runner()) {
            Job__c job = insertJob('Processing');

            new JobFinalizer(job.Id).execute(new FakeContext(ParentJobResult.UNHANDLED_EXCEPTION, null));

            Assert.isTrue(reload(job.Id).Result__c.contains('unknown error'), 'Recorded without an exception');
        }
    }

    @IsTest
    static void restartsTheChainEvenWhenTheJobWasAlreadyRecorded() {
        System.runAs(ReplayrTestAccess.runner()) {
            Job__c recorded = insertJob('Succeeded');
            Job__c next = insertJob('Queued');
            Test.setMock(HttpCalloutMock.class, new OkMock());

            Test.startTest();
            new JobFinalizer(recorded.Id).execute(crashed());
            Test.stopTest();

            Assert.areEqual(0, logs(recorded.Id).size(), 'Recorded job untouched');
            Assert.areEqual('Succeeded', reload(next.Id).Status__c, 'Chain restarted so the queue never stalls');
        }
    }

    @IsTest
    static void restartsTheChainForTheNextQueuedJob() {
        System.runAs(ReplayrTestAccess.runner()) {
            Job__c crashedJob = insertJob('Processing');
            Job__c next = insertJob('Queued');
            Test.setMock(HttpCalloutMock.class, new OkMock());

            Test.startTest();
            new JobFinalizer(crashedJob.Id).execute(crashed());
            Test.stopTest();

            Assert.areEqual('Failed', reload(crashedJob.Id).Status__c, 'Crashed job recorded');
            Assert.areEqual('Succeeded', reload(next.Id).Status__c, 'Chain restarted and ran the next job');
        }
    }
}
