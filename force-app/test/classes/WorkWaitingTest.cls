// The platform-event hand-off (decisions.md, ADR-003): publishing, and what the trigger does as the integration
// user and as Automated Process
@IsTest
private with sharing class WorkWaitingTest {
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

    private static Job__c queuedJob() {
        Job__c job = new Job__c(Endpoint__c = [SELECT Id FROM Endpoint__c LIMIT 1].Id, Status__c = 'Queued', Method__c = 'GET', Path__c = '/get');
        insert job;
        return job;
    }

    private static String statusOf(Id jobId) {
        return [SELECT Status__c FROM Job__c WHERE Id = :jobId].Status__c;
    }

    @IsTest
    static void asTheIntegrationUserStartsTheChainAndSchedulesThePoller() {
        User runner = ReplayrTestAccess.runner();
        System.runAs(runner) {
            Job__c job = queuedJob();
            Test.setMock(HttpCalloutMock.class, new OkMock());
            Test.startTest();
            WorkWaiting.handle();

            Assert.areEqual('Processing', statusOf(job.Id), 'The chain claimed the job');
            Assert.areEqual(String.valueOf(runner.Id), Replayr_Settings__c.getOrgDefaults().Hand_Off_User__c, 'Run-as user recorded');
            Assert.isNotNull(Replayr_Settings__c.getOrgDefaults().Hand_Off_Last_Run__c, 'Run time recorded');
            Test.stopTest();
        }
        // Read as the test's own user: the runner can't query CronTrigger
        Assert.areEqual(1, [SELECT COUNT() FROM CronTrigger WHERE CronJobDetail.Name = :JobPoller.JOB_NAME], 'Poller scheduled by the hand-off');
    }

    @IsTest
    static void aSecondHandOffLeavesThePollerAsItIs() {
        System.runAs(ReplayrTestAccess.runner()) {
            Test.setMock(HttpCalloutMock.class, new OkMock());
            Test.startTest();
            WorkWaiting.handle();
            WorkWaiting.handle();
            Test.stopTest();
        }
        Assert.areEqual(1, [SELECT COUNT() FROM CronTrigger WHERE CronJobDetail.Name = :JobPoller.JOB_NAME], 'Still one poller');
    }

    // An admin, say, named in the subscriber config: holds the Admin set but not the Integration User set
    private static User adminOnly() {
        User admin = ReplayrTestAccess.newUser(ReplayrTestAccess.minimalProfileId(), ReplayrTestAccess.username('adminonly'));
        System.runAs(new User(Id = UserInfo.getUserId())) {
            insert admin;
            insert new PermissionSetAssignment(AssigneeId = admin.Id, PermissionSetId = [SELECT Id FROM PermissionSet WHERE Name = 'Replayr_Admin'].Id);
        }
        return admin;
    }

    @IsTest
    static void asAUserWithoutTheIntegrationSetStartsNothing() {
        Job__c job;
        System.runAs(ReplayrTestAccess.runner()) {
            job = queuedJob();
        }
        User admin = adminOnly();
        System.runAs(admin) {
            Test.startTest();
            WorkWaiting.handle();
            Test.stopTest();
        }

        Assert.areEqual(String.valueOf(admin.Id), Replayr_Settings__c.getOrgDefaults().Hand_Off_User__c, 'Recorded, so the health panel can show it');
        System.runAs(ReplayrTestAccess.runner()) {
            Assert.areEqual('Queued', statusOf(job.Id), 'No chain with wider access than Replayr\'s own');
        }
        Assert.areEqual(0, [SELECT COUNT() FROM CronTrigger WHERE CronJobDetail.Name = :JobPoller.JOB_NAME], 'No poller owned by that user');
    }

    @IsTest
    static void aSecondHandOffSoonAfterLeavesTheSettingsRowAlone() {
        System.runAs(adminOnly()) {
            WorkWaiting.handle();
            Integer dmlBefore = Limits.getDmlStatements();
            WorkWaiting.handle();
            Assert.areEqual(dmlBefore, Limits.getDmlStatements(), 'Same user, recorded moments ago: no write');
        }
    }

    @IsTest
    static void asAutomatedProcessStartsNothing() {
        Job__c job;
        System.runAs(ReplayrTestAccess.runner()) {
            job = queuedJob();
            Assert.isTrue(WorkWaiting.publish(), 'Admins may publish');
            Test.startTest();
        }
        // Delivered to the trigger, which runs as Automated Process here: no subscriber config in a test
        Test.getEventBus().deliver();
        Test.stopTest();

        String handOffUser = Replayr_Settings__c.getOrgDefaults().Hand_Off_User__c;
        Assert.isNotNull(handOffUser, 'The trigger ran and recorded its user');
        Assert.areEqual('AutomatedProcess', [SELECT UserType FROM User WHERE Id = :handOffUser].UserType, 'Not set up: Automated Process');
        System.runAs(ReplayrTestAccess.runner()) {
            Assert.areEqual('Queued', statusOf(job.Id), 'No chain without credential access: the job waits');
        }
        Assert.areEqual(0, [SELECT COUNT() FROM CronTrigger WHERE CronJobDetail.Name = :JobPoller.JOB_NAME], 'No poller owned by Automated Process');
    }

    @IsTest
    static void publishesOncePerTransaction() {
        System.runAs(ReplayrTestAccess.runner()) {
            Assert.isTrue(WorkWaiting.publish(), 'First: published');
            Integer dmlBefore = Limits.getDmlStatements();
            Assert.isTrue(WorkWaiting.publish(), 'Second: already published');
            Assert.areEqual(dmlBefore, Limits.getDmlStatements(), 'No second event (publishing counts as a DML statement)');
        }
    }

    @IsTest
    static void publishingWithoutCreateOnTheEventFailsQuietly() {
        User nobody = ReplayrTestAccess.newUser(ReplayrTestAccess.minimalProfileId(), ReplayrTestAccess.username('nobody'));
        System.runAs(new User(Id = UserInfo.getUserId())) {
            insert nobody;
        }
        Boolean published;
        System.runAs(nobody) {
            published = WorkWaiting.publish();
        }

        Assert.isFalse(published, 'Refused, not thrown: the hourly poller picks the work up');
    }

    @IsTest
    static void aReplayPublishesTheEvent() {
        System.runAs(ReplayrTestAccess.runner()) {
            Job__c job = new Job__c(
                Endpoint__c = [SELECT Id FROM Endpoint__c LIMIT 1].Id,
                Status__c = 'Failed',
                Method__c = 'GET',
                Path__c = '/get',
                Retry_Safe__c = true
            );
            insert job;

            List<JobActions.Result> results = JobActions.replay(new List<Id>{ job.Id }, false);
            Assert.isTrue(results[0].done, results[0].message);
            Assert.isFalse(results[0].message.contains('next scheduled run'), 'Published, so no note: ' + results[0].message);
            Test.startTest();
        }
        // The event reaches the trigger, which records the run
        Test.getEventBus().deliver();
        Test.stopTest();
        Assert.isNotNull(Replayr_Settings__c.getOrgDefaults().Hand_Off_Last_Run__c, 'The replay\'s event reached the hand-off');
    }
}
