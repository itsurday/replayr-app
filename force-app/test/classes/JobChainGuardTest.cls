// The one-chain guard (decisions.md, ADR-004): a chain starts only when none is running, and a second start
// while a link waits in the queue is refused by the chain's duplicate signature. Async jobs are left
// unrun until the test ends, so only the starts are observed
@IsTest
private with sharing class JobChainGuardTest {
    // Links left in the queue still run when the test ends, and each calls out
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
        System.runAs(ReplayrTestAccess.createRunner()) {
            Provider__c provider = new Provider__c(Name = 'P', Named_Credential__c = 'Test_API');
            insert provider;
            insert new Endpoint__c(Name = 'Get', Provider__c = provider.Id, Method__c = 'GET', Path__c = '/get');
        }
    }

    private static Job__c newJob(String status, Datetime startedAt) {
        return new Job__c(
            Endpoint__c = [SELECT Id FROM Endpoint__c LIMIT 1].Id,
            Status__c = status,
            Method__c = 'GET',
            Path__c = '/get',
            Started_At__c = startedAt
        );
    }

    private static String statusOf(Id jobId) {
        return [SELECT Status__c FROM Job__c WHERE Id = :jobId].Status__c;
    }

    @IsTest
    static void startsTheChainWhenNoneIsRunning() {
        System.runAs(ReplayrTestAccess.runner()) {
            Job__c queued = newJob('Queued', null);
            insert queued;

            Test.setMock(HttpCalloutMock.class, new OkMock());
            Test.startTest();
            JobWorker.startChainIfIdle();
            Integer started = Limits.getQueueableJobs();

            Assert.areEqual(1, started, 'One link enqueued');
            Assert.areEqual('Processing', statusOf(queued.Id), 'Its job claimed');
        }
    }

    @IsTest
    static void aFullChainHandsTheRestToAFreshChain() {
        Job__c first = newJob('Queued', null);
        Job__c second = newJob('Queued', null);
        System.runAs(ReplayrTestAccess.runner()) {
            insert new List<Job__c>{ first, second };
            Test.setMock(HttpCalloutMock.class, new OkMock());
            Test.startTest();
            JobWorker.startChainIfIdle();
            // The link runs here; in a test every chained link fails as a full chain does (chain-depth limit)
            Test.stopTest();
        }
        // Its event reaches the hand-off, which would start the fresh chain as the integration user
        Test.getEventBus().deliver();

        System.runAs(ReplayrTestAccess.runner()) {
            // Either job may be claimed first (no ORDER BY with FOR UPDATE)
            Assert.areEqual(1, [SELECT COUNT() FROM Job__c WHERE Status__c = 'Succeeded'], 'The link sent its job');
            Assert.areEqual(1, [SELECT COUNT() FROM Job__c WHERE Status__c = 'Queued'], 'The claim of the next job was undone');
        }
        Assert.isNotNull(Replayr_Settings__c.getOrgDefaults().Hand_Off_Last_Run__c, 'The full chain published the work-waiting event');
        String event = Schema.SObjectType.Replayr_Work_Waiting__e.getName();
        Assert.areEqual(
            1,
            [SELECT COUNT() FROM ObjectPermissions WHERE Parent.Name = 'Replayr_Integration_User' AND SobjectType = :event AND PermissionsCreate = TRUE],
            'Chains run as the integration user, who must be able to publish'
        );
    }

    @IsTest
    static void startsNothingWhileAJobWasClaimedRecently() {
        System.runAs(ReplayrTestAccess.runner()) {
            Job__c working = newJob('Processing', System.now().addMinutes(-2));
            Job__c queued = newJob('Queued', null);
            insert new List<Job__c>{ working, queued };

            Test.setMock(HttpCalloutMock.class, new OkMock());
            Test.startTest();
            JobWorker.startChainIfIdle();
            Integer started = Limits.getQueueableJobs();

            Assert.areEqual(0, started, 'A chain is at work, so no second one');
            Assert.areEqual('Queued', statusOf(queued.Id), 'The running chain claims it next');
        }
    }

    @IsTest
    static void aJobStuckInProcessingDoesNotBlockNewWork() {
        System.runAs(ReplayrTestAccess.runner()) {
            // Its link died; the watchdog settles it after 60 minutes, and no claim ever takes it
            Job__c stuck = newJob('Processing', System.now().addMinutes(-6));
            Job__c queued = newJob('Queued', null);
            insert new List<Job__c>{ stuck, queued };

            Test.setMock(HttpCalloutMock.class, new OkMock());
            Test.startTest();
            JobWorker.startChainIfIdle();
            Integer started = Limits.getQueueableJobs();

            Assert.areEqual(1, started, 'A new chain starts');
            Assert.areEqual('Processing', statusOf(queued.Id), 'It claimed the queued job');
            Assert.areEqual('Processing', statusOf(stuck.Id), 'The stuck job is left to the watchdog');
        }
    }

    @IsTest
    static void startsTheChainForADueRetry() {
        System.runAs(ReplayrTestAccess.runner()) {
            Job__c due = newJob('Retry_Wait', null);
            due.Next_Attempt_At__c = System.now().addMinutes(-1);
            insert due;

            Test.setMock(HttpCalloutMock.class, new OkMock());
            Test.startTest();
            JobWorker.startChainIfIdle();

            Assert.areEqual(1, Limits.getQueueableJobs(), 'One link enqueued');
            Assert.areEqual('Processing', statusOf(due.Id), 'The due retry claimed');
        }
    }

    @IsTest
    static void aWaitingWakeUpLinkDoesNotBlockANewStart() {
        System.runAs(ReplayrTestAccess.runner()) {
            Job__c queued = newJob('Queued', null);
            insert queued;

            Test.setMock(HttpCalloutMock.class, new OkMock());
            Test.startTest();
            // As wakeUpForRetries queues it: delayed, holding no job, without the chain's signature
            System.enqueueJob(new JobWorker(null), 1);
            JobWorker.continueChain();

            Assert.areEqual('Processing', statusOf(queued.Id), 'New work starts at once, not after the wake-up');
            Assert.areEqual(2, Limits.getQueueableJobs(), 'The wake-up and the new link');
        }
    }

    @IsTest
    static void aSecondStartWhileALinkWaitsInTheQueueIsUndone() {
        System.runAs(ReplayrTestAccess.runner()) {
            insert new List<Job__c>{ newJob('Queued', null), newJob('Queued', null) };

            Test.setMock(HttpCalloutMock.class, new OkMock());
            Test.startTest();
            JobWorker.continueChain();
            // The first link waits in the queue, so its signature refuses this one, and the claim is rolled back
            JobWorker.continueChain();

            Assert.areEqual(1, [SELECT COUNT() FROM Job__c WHERE Status__c = 'Processing'], 'Only one chain holds a job');
            Assert.areEqual(1, [SELECT COUNT() FROM Job__c WHERE Status__c = 'Queued'], 'The other job waits for that chain');
        }
    }
}
