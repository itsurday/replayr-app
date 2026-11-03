/**
 * Runs the worker as a minimal-access user, with and without the Replayr Integration User permission set,
 * on a job owned by another user. Proves the set grants exactly what the engine needs under USER_MODE.
 */
@IsTest
private with sharing class JobWorkerPermissionTest {
    private static final String WITH_SET = ReplayrTestAccess.username('integration');
    private static final String WITHOUT_SET = ReplayrTestAccess.username('nopermission');

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
        // Setup objects (users, assignments) go in their own runAs block to avoid mixed DML
        System.runAs(new User(Id = UserInfo.getUserId())) {
            Id profileId = ReplayrTestAccess.minimalProfileId();
            User integration = ReplayrTestAccess.newUser(profileId, WITH_SET);
            insert new List<User>{ integration, ReplayrTestAccess.newUser(profileId, WITHOUT_SET) };
            insert new PermissionSetAssignment(
                AssigneeId = integration.Id,
                PermissionSetId = [SELECT Id FROM PermissionSet WHERE Name = 'Replayr_Integration_User'].Id
            );
        }
        // Owned by the test runner, not by the user who will run the worker
        System.runAs(runner) {
            Provider__c provider = new Provider__c(Name = 'P', Named_Credential__c = 'Test_API');
            insert provider;
            Endpoint__c endpoint = new Endpoint__c(Name = 'Get', Provider__c = provider.Id, Method__c = 'GET', Path__c = '/get');
            insert endpoint;
            insert new Job__c(Endpoint__c = endpoint.Id, Method__c = 'GET', Path__c = '/get');
        }
    }

    private static User userNamed(String username) {
        return [SELECT Id FROM User WHERE Username = :username];
    }

    @IsTest
    static void watchdogSettlesAStuckJobUnderTheSet() {
        Id jobId = theJob().Id;
        System.runAs(ReplayrTestAccess.runner()) {
            update new Job__c(Id = jobId, Status__c = 'Processing', Started_At__c = System.now().addHours(-2));
        }

        System.runAs(userNamed(WITH_SET)) {
            Assert.areEqual(1, JobWatchdog.run(), 'Settled with the Integration User set alone');
        }

        Assert.areEqual('Outcome_Unknown', theJob().Status__c, 'Not Retry-safe: a person decides');
    }

    @IsTest
    static void alertsWorkUnderTheSetAlone() {
        Id jobId = theJob().Id;
        System.runAs(ReplayrTestAccess.runner()) {
            update new Job__c(Id = jobId, Status__c = 'Outcome_Unknown');
        }

        JobAlerts.Summary summary;
        JobAlerts.nowForTest = System.now().addMinutes(10);
        System.runAs(userNamed(WITH_SET)) {
            summary = JobAlerts.check(true);
        }

        Assert.areEqual(1, summary.outcomeUnknown, 'Counted with the Integration User set alone');
        Assert.areEqual(1, JobAlerts.sent, 'Sent: recipients and notification type found without setup access');
        Assert.isNotNull(Replayr_Settings__c.getOrgDefaults().Last_Alert_Check__c, 'Check time recorded');
    }

    @IsTest
    static void purgeWorksUnderTheSetAlone() {
        Id jobId = theJob().Id;
        System.runAs(ReplayrTestAccess.runner()) {
            update new Job__c(Id = jobId, Status__c = 'Succeeded');
            insert JobLogs.newLog(jobId, 'Succeeded', 200, 'HTTP 200', 10);
        }

        System.runAs(userNamed(WITH_SET)) {
            Test.startTest();
            Database.executeBatch(new JobPurge(System.now().addMinutes(1)), JobPurge.BATCH_SIZE);
            Test.stopTest();
        }

        Assert.areEqual(0, [SELECT COUNT() FROM Job__c], 'Deleted with the Integration User set alone');
        Assert.areEqual(0, [SELECT COUNT() FROM Job_Log__c], 'Its log rows went with it');
    }

    @IsTest
    static void pollerWithoutAccessWritesNoHeartbeat() {
        String purgeFailure;
        System.runAs(userNamed(WITHOUT_SET)) {
            Test.startTest();
            new JobPoller().execute(null);
            try {
                Test.stopTest();
            } catch (QueryException e) {
                // The purge batch the poll started fails too, without access; stopTest re-throws it
                purgeFailure = e.getMessage();
            }
        }

        Assert.isNotNull(purgeFailure, 'The purge could not read jobs either');
        // The watchdog failed (no access), so the poll leaves no heartbeat for the health check to find
        Assert.isNull(Replayr_Settings__c.getOrgDefaults().Poller_Last_Run__c, 'No heartbeat after a failed watchdog');
        Assert.areEqual('Queued', theJob().Status__c, 'Without access nothing was claimed either');
    }

    @IsTest
    static void pollerRunsUnderTheSetAndRecordsItsHeartbeat() {
        System.runAs(userNamed(WITH_SET)) {
            Test.setMock(HttpCalloutMock.class, new OkMock());
            Test.startTest();
            new JobPoller().execute(null);
            Test.stopTest();
        }

        Assert.isNotNull(Replayr_Settings__c.getOrgDefaults().Poller_Last_Run__c, 'Heartbeat written as the integration user');
        Assert.areEqual('Succeeded', theJob().Status__c, 'The chain it started ran the queued job');
    }

    // Read as the test runner, who can see Replayr's fields
    private static Job__c theJob() {
        Job__c job;
        System.runAs(ReplayrTestAccess.runner()) {
            job = [SELECT Status__c, HTTP_Status__c, OwnerId FROM Job__c LIMIT 1];
        }
        return job;
    }

    private static Integer logCount(Id jobId) {
        Integer count;
        System.runAs(ReplayrTestAccess.runner()) {
            count = [SELECT COUNT() FROM Job_Log__c WHERE Job__c = :jobId];
        }
        return count;
    }

    @IsTest
    static void integrationUserClaimsCallsAndRecordsAJobOwnedByAnotherUser() {
        Test.setMock(HttpCalloutMock.class, new OkMock());
        User integration = userNamed(WITH_SET);
        Id started;

        System.runAs(integration) {
            Test.startTest();
            started = JobWorker.start();
            Test.stopTest();
        }

        Job__c job = theJob();
        Assert.isNotNull(started, 'The job owned by another user was visible and claimed');
        Assert.areNotEqual(integration.Id, job.OwnerId, 'Job is owned by someone else');
        Assert.areEqual('Succeeded', job.Status__c, 'Result recorded in user mode');
        Assert.areEqual(200, job.HTTP_Status__c, 'HTTP status recorded');
        Assert.areEqual(1, logCount(job.Id), 'Log row created');
    }

    @IsTest
    static void finalizerRecordsACrashedJobUnderTheSet() {
        Test.setMock(HttpCalloutMock.class, new OkMock());
        Job__c job = theJob();
        String crash;

        System.runAs(userNamed(WITH_SET)) {
            // Claim as the integration user, then crash the link right after its callout returned
            Job__c claimed = JobWorker.claimNext();
            JobWorker link = new JobWorker(claimed.Id);
            link.crashAfterCallout = true;
            Test.startTest();
            System.enqueueJob(link);
            try {
                Test.stopTest();
            } catch (Exception e) {
                crash = e.getTypeName();
            }
        }

        Assert.isNotNull(crash, 'The link really crashed');
        Assert.areEqual('Succeeded', theJob().Status__c, 'Finalizer recorded the real result under the set');
        Assert.areEqual(1, logCount(job.Id), 'Finalizer created the log row');
    }

    private class CrashTestException extends Exception {
    }

    private class CrashingMock implements HttpCalloutMock {
        public HttpResponse respond(HttpRequest request) {
            throw new CrashTestException('Worker died during the callout');
        }
    }

    @IsTest
    static void finalizerRecordsOutcomeUnknownUnderTheSet() {
        Test.setMock(HttpCalloutMock.class, new CrashingMock());
        Job__c job = theJob();
        String crash;

        System.runAs(userNamed(WITH_SET)) {
            Job__c claimed = JobWorker.claimNext();
            Test.startTest();
            System.enqueueJob(new JobWorker(claimed.Id));
            try {
                Test.stopTest();
            } catch (Exception e) {
                crash = e.getTypeName();
            }
        }

        Assert.isNotNull(crash, 'The link really crashed during the callout');
        Assert.areEqual('Outcome_Unknown', theJob().Status__c, 'Recorded with the integration set alone');
        Assert.areEqual(1, logCount(job.Id), 'Finalizer created the log row');
    }

    @IsTest
    static void userWithoutThePermissionSetCannotClaimJobs() {
        Boolean denied = false;

        System.runAs(userNamed(WITHOUT_SET)) {
            try {
                JobWorker.start();
            } catch (QueryException e) {
                denied = true;
            }
        }

        Assert.isTrue(denied, 'User mode refuses the claim without access');
        Assert.areEqual('Queued', theJob().Status__c, 'Job untouched');
    }
}
