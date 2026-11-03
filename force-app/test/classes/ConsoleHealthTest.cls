@IsTest
private with sharing class ConsoleHealthTest {
    // A Replayr Admin who can see scheduled jobs (View Setup and Configuration), as most admins can
    private static final String VIEWER = ReplayrTestAccess.username('viewer');

    @TestSetup
    static void setup() {
        ReplayrTestAccess.createRunner();
        System.runAs(new User(Id = UserInfo.getUserId())) {
            User viewer = ReplayrTestAccess.newUser([SELECT Id FROM Profile WHERE Name = 'System Administrator'].Id, VIEWER);
            insert viewer;
            insert new PermissionSetAssignment(AssigneeId = viewer.Id, PermissionSetId = [SELECT Id FROM PermissionSet WHERE Name = 'Replayr_Admin'].Id);
        }
        System.runAs(ReplayrTestAccess.runner()) {
            Provider__c provider = new Provider__c(Name = 'P', Named_Credential__c = 'Test_API');
            insert provider;
            insert new Endpoint__c(Name = 'Put', Provider__c = provider.Id, Method__c = 'PUT', Path__c = '/items');
        }
    }

    private static Job__c newJob(Id endpointId, String status) {
        return new Job__c(Endpoint__c = endpointId, Status__c = status, Method__c = 'PUT', Path__c = '/items');
    }

    // The protected setting, written only by package code (system mode)
    private static void recorded(Datetime pollerLastRun, Id handOffUser) {
        Replayr_Settings__c settings = Replayr_Settings__c.getOrgDefaults();
        settings.Poller_Last_Run__c = pollerLastRun;
        settings.Hand_Off_User__c = handOffUser;
        settings.Hand_Off_Last_Run__c = handOffUser == null ? null : System.now();
        Database.upsert(settings, true, AccessLevel.SYSTEM_MODE);
    }

    private static void assertWarns(ConsoleHealth.Health health, String fragment) {
        for (String warning : health.warnings) {
            if (warning.contains(fragment)) {
                return;
            }
        }
        Assert.fail('Expected a warning with "' + fragment + '": ' + health.warnings);
    }

    @IsTest
    static void refusesUsersWithoutReplayrAdminOrOperator() {
        User nobody = ReplayrTestAccess.newUser(ReplayrTestAccess.minimalProfileId(), ReplayrTestAccess.username('nobody'));
        System.runAs(new User(Id = UserInfo.getUserId())) {
            insert nobody;
        }
        System.runAs(nobody) {
            try {
                ConsoleHealth.read();
                Assert.fail('Expected AuraHandledException');
            } catch (AuraHandledException e) {
                Assert.isTrue(e.getMessage().contains('Replayr Operator'), e.getMessage());
            }
        }
    }

    @IsTest
    static void saysWhatIsNotSetUpYet() {
        ConsoleHealth.Health health;
        System.runAs(ReplayrTestAccess.runner()) {
            health = ConsoleHealth.read();
        }

        assertWarns(health, 'hasn\'t finished a run yet');
        assertWarns(health, 'hasn\'t run yet');
        // The runner's minimal profile can't see scheduled jobs: unknown, not "not scheduled", and no warning for it
        Assert.isNull(health.pollerScheduled, 'Unknown');
        Assert.areEqual(2, health.warnings.size(), 'Only the poller and the trigger: ' + health.warnings);
        Assert.areEqual(0, health.outcomeUnknown + health.retriesUsedUp, 'No jobs');
        Assert.isNull(health.oldestQueued, 'Nothing queued');
    }

    @IsTest
    static void aWorkingSetupHasNoWarnings() {
        User runner = [SELECT Id, Name FROM User WHERE Id = :ReplayrTestAccess.runner().Id];
        // The runner holds the Integration User set: the poller and the trigger run as it
        System.runAs(runner) {
            JobPoller.schedule();
        }
        recorded(System.now(), runner.Id);

        ConsoleHealth.Health health;
        User viewer = [SELECT Id FROM User WHERE Username = :VIEWER];
        System.runAs(viewer) {
            health = ConsoleHealth.read();
        }

        Assert.areEqual(new List<String>(), health.warnings, 'Healthy');
        Assert.isTrue(health.pollerScheduled, 'Scheduled');
        Assert.isNotNull(health.pollerOwner, 'Owner shown');
        Assert.areEqual(runner.Name, health.handOffUser, 'Run-as user shown by name');
        Assert.isNotNull(health.handOffLastRun, 'Last hand-off shown');
    }

    // Like JobPollerTest, these two need an org with no real poller scheduled (docs/dev-setup.md)
    @IsTest
    static void warnsWhenThePollerIsNotScheduled() {
        recorded(System.now(), null);
        User viewer = [SELECT Id FROM User WHERE Username = :VIEWER];
        ConsoleHealth.Health health;
        System.runAs(viewer) {
            health = ConsoleHealth.read();
        }

        Assert.isFalse(health.pollerScheduled, 'Not scheduled');
        assertWarns(health, 'The poller isn\'t scheduled');
    }

    @IsTest
    static void warnsWhenThePollerIsScheduledByAnotherUser() {
        recorded(System.now(), null);
        User viewer = [SELECT Id, Name FROM User WHERE Username = :VIEWER];
        ConsoleHealth.Health health;
        System.runAs(viewer) {
            // An admin without the Integration User set: its chains would have no credential access
            JobPoller.schedule();
            health = ConsoleHealth.read();
        }

        Assert.areEqual(viewer.Name, health.pollerOwner, 'Owner shown');
        assertWarns(health, 'The poller runs as ' + viewer.Name);
    }

    @IsTest
    static void warnsOfALatePollerAndATriggerRunningAsAutomatedProcess() {
        recorded(System.now().addMinutes(-(ConsoleHealth.POLLER_LATE_MINUTES + 1)), [SELECT Id FROM User WHERE UserType = 'AutomatedProcess' LIMIT 1].Id);

        ConsoleHealth.Health health;
        System.runAs(ReplayrTestAccess.runner()) {
            health = ConsoleHealth.read();
        }

        assertWarns(health, 'hasn\'t finished a run for over ' + ConsoleHealth.POLLER_LATE_MINUTES + ' minutes');
        assertWarns(health, 'not an active Replayr integration user, so new work waits');
    }

    @IsTest
    static void countsTwoHundredJobsAndSeesWorkNotMoving() {
        System.runAs(ReplayrTestAccess.runner()) {
            Id endpointId = [SELECT Id FROM Endpoint__c LIMIT 1].Id;
            List<Job__c> jobs = new List<Job__c>();
            for (Integer i = 0; i < 200; i++) {
                String status = i < 120 ? 'Outcome_Unknown' : i < 180 ? 'Dead' : 'Queued';
                jobs.add(newJob(endpointId, status));
            }
            // Not counted: a test-mode run
            Job__c testRun = newJob(endpointId, 'Outcome_Unknown');
            testRun.Test_Run__c = true;
            jobs.add(testRun);
            // A retry overdue by more than the alert's window: work not moving
            Job__c stuck = newJob(endpointId, 'Retry_Wait');
            stuck.Next_Attempt_At__c = System.now().addHours(-(JobAlerts.NOT_MOVING_HOURS + 1));
            jobs.add(stuck);
            // System mode: people can't set Test Run or Next Attempt At
            Database.insert(jobs, true, AccessLevel.SYSTEM_MODE);

            Test.startTest();
            ConsoleHealth.Health health = ConsoleHealth.read();
            Integer queries = Limits.getQueries();
            Test.stopTest();

            Assert.areEqual(120, health.outcomeUnknown, 'Outcome unknown, not test runs');
            Assert.areEqual(60, health.retriesUsedUp, 'Retries used up');
            Assert.isNotNull(health.oldestQueued, 'Oldest queued job shown');
            assertWarns(health, 'Jobs need a person: 120 Outcome unknown, 60 Retries used up.');
            assertWarns(health, 'hasn\'t moved for over');
            Assert.isTrue(queries <= 10, 'Queries: ' + queries);
        }
    }
}
