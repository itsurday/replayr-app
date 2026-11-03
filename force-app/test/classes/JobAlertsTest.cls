@IsTest
private with sharing class JobAlertsTest {
    @TestSetup
    static void setup() {
        // The runner holds the Replayr Admin set, so it is a recipient
        System.runAs(ReplayrTestAccess.createRunner()) {
            Provider__c provider = new Provider__c(Name = 'P', Named_Credential__c = 'Test_API');
            insert provider;
            insert new Endpoint__c(Name = 'Put', Provider__c = provider.Id, Method__c = 'PUT', Path__c = '/items');
        }
    }

    private static Id endpointId {
        get {
            endpointId = endpointId ?? [SELECT Id FROM Endpoint__c LIMIT 1].Id;
            return endpointId;
        }
        set;
    }

    private static Job__c newJob(String status, String result) {
        return new Job__c(Endpoint__c = endpointId, Status__c = status, Method__c = 'PUT', Path__c = '/items', Result__c = result);
    }

    // The check time lives in the protected setting, which only package code writes (system mode)
    private static void lastCheckedAt(Datetime moment) {
        Replayr_Settings__c settings = Replayr_Settings__c.getOrgDefaults();
        settings.Last_Alert_Check__c = moment;
        Database.upsert(settings, true, AccessLevel.SYSTEM_MODE);
    }

    @IsTest
    static void reportsProblemsSinceTheLastCheckButNotTestRuns() {
        // As at the next poll: changes from just now are past the window's lag
        JobAlerts.nowForTest = System.now().addMinutes(10);
        Job__c testRun = newJob('Outcome_Unknown', null);
        testRun.Test_Run__c = true;
        Database.insert(testRun, true, AccessLevel.SYSTEM_MODE);
        lastCheckedAt(System.now().addHours(-1));
        System.runAs(ReplayrTestAccess.runner()) {
            insert new List<Job__c>{
                newJob('Outcome_Unknown', null),
                newJob('Outcome_Unknown', null),
                newJob('Dead', null),
                newJob('Succeeded', 'HTTP 200 OK. Response not saved: Name is required'),
                newJob('Succeeded', 'HTTP 200 OK. Response: 1 saved.'),
                newJob('Failed', 'HTTP 400 Bad Request')
            };
            Datetime before = System.now();

            JobAlerts.Summary summary = JobAlerts.check(true);

            Assert.areEqual(2, summary.outcomeUnknown, 'Outcome unknown, test run left out');
            Assert.areEqual(1, summary.dead, 'Retries used up');
            Assert.areEqual(1, summary.notSaved, 'Response not saved');
            Assert.isFalse(summary.notMoving, 'Work is moving');
            Assert.areEqual('2 Outcome unknown, 1 Retries used up, 1 Response not saved.', summary.text(), 'One grouped message');
            Assert.areEqual(1, JobAlerts.sent, 'One notification');
            Assert.isTrue(Replayr_Settings__c.getOrgDefaults().Last_Alert_Check__c >= before.addSeconds(-1), 'Check time moved on');
        }
    }

    @IsTest
    static void problemsAlreadyReportedAreNotSentAgain() {
        // As at the next poll: changes from just now are past the window's lag
        JobAlerts.nowForTest = System.now().addMinutes(10);
        System.runAs(ReplayrTestAccess.runner()) {
            insert newJob('Outcome_Unknown', null);
        }
        // As if the last check ran after the job changed
        lastCheckedAt(System.now().addMinutes(1));

        JobAlerts.Summary summary;
        System.runAs(ReplayrTestAccess.runner()) {
            summary = JobAlerts.check(true);
        }

        Assert.isTrue(summary.isEmpty(), 'Nothing new');
        Assert.areEqual(0, JobAlerts.sent, 'Nothing sent');
    }

    @IsTest
    static void workNotMovingIsReportedEveryHourWhileItLasts() {
        // As at the next poll: changes from just now are past the window's lag
        JobAlerts.nowForTest = System.now().addMinutes(10);
        Job__c stuck = newJob('Retry_Wait', null);
        stuck.Next_Attempt_At__c = System.now().addHours(-(JobAlerts.NOT_MOVING_HOURS + 1));
        System.runAs(ReplayrTestAccess.runner()) {
            insert stuck;
        }
        lastCheckedAt(System.now().addMinutes(1));

        System.runAs(ReplayrTestAccess.runner()) {
            Assert.isTrue(JobAlerts.check(true).notMoving, 'First hour');
            Assert.isTrue(JobAlerts.check(true).notMoving, 'Still, the next hour');
        }

        Assert.areEqual(2, JobAlerts.sent, 'Repeated while it lasts');
    }

    @IsTest
    static void aQueuedJobWaitingTooLongIsWorkNotMoving() {
        System.runAs(ReplayrTestAccess.runner()) {
            insert newJob('Queued', null);
            JobAlerts.nowForTest = System.now().addHours(JobAlerts.NOT_MOVING_HOURS).addMinutes(1);

            Assert.isTrue(JobAlerts.check(true).notMoving, 'Queued for over two hours');
        }
    }

    @IsTest
    static void aChangeBeingSavedIsCountedAtTheNextPollNotLost() {
        lastCheckedAt(System.now().addHours(-1));
        System.runAs(ReplayrTestAccess.runner()) {
            insert newJob('Dead', null);

            // Polled straight away: the change is inside the commit lag, so it waits for the next window
            Assert.areEqual(0, JobAlerts.check(true).dead, 'Not yet');
            JobAlerts.nowForTest = System.now().addHours(1);
            Assert.areEqual(1, JobAlerts.check(true).dead, 'Counted once, at the next poll');
            JobAlerts.nowForTest = System.now().addHours(2);
            Assert.areEqual(0, JobAlerts.check(true).dead, 'Not counted again');
        }
    }

    @IsTest
    static void aRecentRetryIsNotWorkStopping() {
        // As at the next poll: changes from just now are past the window's lag
        JobAlerts.nowForTest = System.now().addMinutes(10);
        Job__c waiting = newJob('Retry_Wait', null);
        waiting.Next_Attempt_At__c = System.now().addMinutes(-30);
        System.runAs(ReplayrTestAccess.runner()) {
            insert waiting;
            Assert.isFalse(JobAlerts.check(true).notMoving, 'Due for half an hour only');
        }
    }

    @IsTest
    static void aFailedWatchdogIsReported() {
        JobAlerts.Summary summary;
        System.runAs(ReplayrTestAccess.runner()) {
            summary = JobAlerts.check(false);
        }

        Assert.isTrue(summary.watchdogFailed, 'Reported');
        Assert.areEqual('the watchdog failed.', summary.text(), 'Says so');
        Assert.areEqual(1, JobAlerts.sent, 'Sent');
    }

    @IsTest
    static void firstCheckLooksBackOneHour() {
        // As at the next poll: changes from just now are past the window's lag
        JobAlerts.nowForTest = System.now().addMinutes(10);
        System.runAs(ReplayrTestAccess.runner()) {
            insert newJob('Dead', null);
            Assert.isNull(Replayr_Settings__c.getOrgDefaults().Last_Alert_Check__c, 'Never checked');

            Assert.areEqual(1, JobAlerts.check(true).dead, 'A job that just changed is reported');
        }
    }
}
