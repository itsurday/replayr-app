@IsTest
private with sharing class JobPollerTest {
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
            insert new Endpoint__c(Name = 'Get', Provider__c = provider.Id, Method__c = 'GET', Path__c = '/get');
        }
    }

    private static Job__c insertJob(String status, Datetime nextAttempt) {
        Job__c job = new Job__c(
            Endpoint__c = [SELECT Id FROM Endpoint__c LIMIT 1].Id,
            Status__c = status,
            Method__c = 'GET',
            Path__c = '/get',
            Next_Attempt_At__c = nextAttempt
        );
        insert job;
        return job;
    }

    private static Datetime lastRun() {
        return Replayr_Settings__c.getOrgDefaults().Poller_Last_Run__c;
    }

    private static String statusOf(Id jobId) {
        return [SELECT Status__c FROM Job__c WHERE Id = :jobId].Status__c;
    }

    @IsTest
    static void pollStartsAChainForQueuedWorkAndRecordsTheHeartbeat() {
        System.runAs(ReplayrTestAccess.runner()) {
            Job__c job = insertJob('Queued', null);
            OkMock mock = new OkMock();
            Test.setMock(HttpCalloutMock.class, mock);
            Datetime before = System.now();

            Test.startTest();
            new JobPoller().execute(null);
            Test.stopTest();

            Assert.areEqual(1, mock.calls, 'The chain sent the queued job');
            Assert.areEqual('Succeeded', statusOf(job.Id), 'Chain ran it');
            Assert.isTrue(lastRun() >= before.addSeconds(-1), 'Heartbeat recorded: ' + lastRun());
        }
    }

    @IsTest
    static void pollPicksUpARetryDueAfterALongWait() {
        System.runAs(ReplayrTestAccess.runner()) {
            // A wait over ten minutes had no delayed link: only the poller finds it
            Job__c job = insertJob('Retry_Wait', System.now().addMinutes(-5));
            Test.setMock(HttpCalloutMock.class, new OkMock());

            Test.startTest();
            new JobPoller().execute(null);
            Test.stopTest();

            Assert.areEqual('Succeeded', statusOf(job.Id), 'Due retry claimed and sent');
        }
    }

    @IsTest
    static void everyPollUpdatesTheOneHeartbeatRow() {
        Datetime first;
        System.runAs(ReplayrTestAccess.runner()) {
            new JobPoller().execute(null);
            first = lastRun();
            new JobPoller().execute(null);
        }

        // Counted as the test's own user: the protected setting can't be queried by Replayr's users
        Assert.areEqual(1, [SELECT COUNT() FROM Replayr_Settings__c], 'One org-wide row, not one per poll');
        Assert.isTrue(lastRun() >= first, 'Moved forward again: ' + lastRun());
    }

    @IsTest
    static void pollWithNoWorkOnlyRecordsTheHeartbeat() {
        System.runAs(ReplayrTestAccess.runner()) {
            Job__c later = insertJob('Retry_Wait', System.now().addHours(3));

            Test.startTest();
            new JobPoller().execute(null);
            Integer enqueued = Limits.getQueueableJobs();
            Test.stopTest();

            Assert.areEqual(0, enqueued, 'No chain and no wake-up for a retry hours away');
            Assert.areEqual('Retry_Wait', statusOf(later.Id), 'Not due yet');
            Assert.isNotNull(lastRun(), 'Heartbeat still recorded');
        }
    }

    @IsTest
    static void scheduleIsHourlyAtOneMinuteAndOnlyOnce() {
        Boolean first;
        Boolean second;
        System.runAs(ReplayrTestAccess.runner()) {
            Test.startTest();
            first = JobPoller.schedule();
            second = JobPoller.schedule();
            Test.stopTest();
        }

        Assert.isTrue(first, 'Scheduled the first time');
        Assert.isFalse(second, 'An existing poller is kept');
        // Read as the test's own user: the runner, like the integration user, can't query CronTrigger
        List<CronTrigger> triggers = [
            SELECT CronExpression, OwnerId
            FROM CronTrigger
            WHERE CronJobDetail.Name = :JobPoller.JOB_NAME
        ];
        Assert.areEqual(1, triggers.size(), 'Scheduled once');
        Assert.isTrue(
            Pattern.matches('0 [0-9]{1,2} \\* \\* \\* \\?', triggers[0].CronExpression),
            'Hourly at a fixed minute: ' + triggers[0].CronExpression
        );
        Assert.areEqual(ReplayrTestAccess.runner().Id, triggers[0].OwnerId, 'Owned, and so run, by the user who scheduled it');
    }

    @IsTest
    static void scheduledPollerReallyRuns() {
        System.runAs(ReplayrTestAccess.runner()) {
            Job__c job = insertJob('Queued', null);
            Test.setMock(HttpCalloutMock.class, new OkMock());

            // stopTest runs the scheduled job: this proves the top-level class's code runs (P0.2b)
            Test.startTest();
            JobPoller.schedule();
            Test.stopTest();

            Assert.isNotNull(lastRun(), 'Heartbeat written by the scheduled run');
            Assert.areNotEqual('Queued', statusOf(job.Id), 'The scheduled run claimed the queued job');
        }
    }
}
