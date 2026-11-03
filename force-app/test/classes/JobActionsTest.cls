@IsTest
private with sharing class JobActionsTest {
    private static final String OPERATOR = ReplayrTestAccess.username('operator');
    private static final String NO_PERMISSION = ReplayrTestAccess.username('integrationonly');

    @TestSetup
    static void setup() {
        User runner = ReplayrTestAccess.createRunner();
        // Setup objects in their own runAs block to avoid mixed DML
        System.runAs(new User(Id = UserInfo.getUserId())) {
            Id profileId = ReplayrTestAccess.minimalProfileId();
            User operator = ReplayrTestAccess.newUser(profileId, OPERATOR);
            User integrationOnly = ReplayrTestAccess.newUser(profileId, NO_PERMISSION);
            insert new List<User>{ operator, integrationOnly };
            Map<String, Id> sets = new Map<String, Id>();
            for (PermissionSet permissionSet : [SELECT Id, Name FROM PermissionSet WHERE Name IN ('Replayr_Operator', 'Replayr_Integration_User')]) {
                sets.put(permissionSet.Name, permissionSet.Id);
            }
            insert new List<PermissionSetAssignment>{
                new PermissionSetAssignment(AssigneeId = operator.Id, PermissionSetId = sets.get('Replayr_Operator')),
                new PermissionSetAssignment(AssigneeId = integrationOnly.Id, PermissionSetId = sets.get('Replayr_Integration_User'))
            };
        }
        System.runAs(runner) {
            Provider__c provider = new Provider__c(Name = 'P', Named_Credential__c = 'Test_API');
            insert provider;
            insert new Endpoint__c(Name = 'Put', Provider__c = provider.Id, Method__c = 'PUT', Path__c = '/items');
        }
    }

    private static User userNamed(String username) {
        return [SELECT Id FROM User WHERE Username = :username];
    }

    private static Id endpointId {
        get {
            endpointId = endpointId ?? [SELECT Id FROM Endpoint__c LIMIT 1].Id;
            return endpointId;
        }
        set;
    }

    private static Job__c newJob(String status, Boolean retrySafe) {
        return new Job__c(
            Endpoint__c = endpointId,
            Status__c = status,
            Method__c = 'PUT',
            Path__c = '/items',
            Retry_Safe__c = retrySafe,
            Attempts__c = 5,
            Idempotency_Key__c = '3f2b9c1e-0000-4000-8000-000000000001'
        );
    }

    // Jobs are created by the runner (the engine's side), then acted on by the operator
    private static Job__c insertJob(String status, Boolean retrySafe) {
        Job__c job = newJob(status, retrySafe);
        System.runAs(ReplayrTestAccess.runner()) {
            insert job;
        }
        return job;
    }

    private static Job__c reload(Id jobId) {
        // Read as the test's own user, who holds no Replayr set in a clean org (CI, the package build org)
        return [SELECT Status__c, Result__c, Attempts__c, Idempotency_Key__c, Next_Attempt_At__c FROM Job__c WHERE Id = :jobId WITH SYSTEM_MODE];
    }

    private static String actionError(Id jobId, Boolean replay) {
        try {
            if (replay) {
                JobActions.replay(new List<Id>{ jobId }, true);
            } else {
                JobActions.resolve(new List<Id>{ jobId }, 'Succeeded', 'Checked');
            }
        } catch (JobActions.ActionException e) {
            return e.getMessage();
        }
        return null;
    }

    @IsTest
    static void operatorReplaysARetrySafeJobKeepingItsKey() {
        Job__c job = insertJob('Failed', true);

        List<JobActions.Result> results;
        System.runAs(userNamed(OPERATOR)) {
            results = JobActions.replay(new List<Id>{ job.Id }, false);
        }

        Assert.isTrue(results[0].done, 'Replayed: ' + results[0].message);
        Job__c saved = reload(job.Id);
        Assert.areEqual('Queued', saved.Status__c, 'Queued for the next chain run');
        Assert.areEqual(job.Idempotency_Key__c, saved.Idempotency_Key__c, 'Same key, so the API can drop a duplicate');
        Assert.areEqual(5, saved.Attempts__c, 'History kept; the claim adds the replay attempt');
        Assert.isTrue(saved.Result__c.startsWith('Replay requested by '), 'Says who: ' + saved.Result__c);
        Job_Log__c log = [SELECT Outcome__c, Message__c FROM Job_Log__c WHERE Job__c = :job.Id WITH SYSTEM_MODE];
        Assert.areEqual('Replay_Requested', log.Outcome__c, 'A log row the next attempt never overwrites');
        Assert.areEqual(saved.Result__c, log.Message__c, 'Who asked');
    }

    @IsTest
    static void jobThatIsNotRetrySafeNeedsTheDuplicateRiskConfirmed() {
        Job__c job = insertJob('Outcome_Unknown', false);

        System.runAs(userNamed(OPERATOR)) {
            JobActions.Result refused = JobActions.replay(new List<Id>{ job.Id }, false)[0];
            Assert.isFalse(refused.done, 'Not without confirmation');
            Assert.areEqual(JobActions.DUPLICATE_RISK, refused.message, 'Names the risk');
            Assert.areEqual('Outcome_Unknown', reload(job.Id).Status__c, 'Unchanged');
            Assert.areEqual(0, [SELECT COUNT() FROM Job_Log__c WHERE Job__c = :job.Id], 'A refused replay writes no log row');

            Assert.isTrue(JobActions.replay(new List<Id>{ job.Id }, true)[0].done, 'Replayed once confirmed');
        }
        Assert.areEqual('Queued', reload(job.Id).Status__c, 'Queued');
    }

    @IsTest
    static void refusesJobsThatArentFinishedOrCantBeReplayed() {
        Job__c processing = newJob('Processing', true);
        Job__c waiting = newJob('Retry_Wait', true);
        Job__c incomplete = newJob('Failed', true);
        incomplete.Not_Replayable__c = true;
        Job__c deleted = newJob('Failed', true);
        System.runAs(ReplayrTestAccess.runner()) {
            insert new List<Job__c>{ processing, waiting, incomplete, deleted };
            delete deleted;
        }
        Id missing = deleted.Id;

        List<JobActions.Result> results;
        System.runAs(userNamed(OPERATOR)) {
            results = JobActions.replay(new List<Id>{ processing.Id, waiting.Id, incomplete.Id, missing }, true);
        }

        for (JobActions.Result result : results) {
            Assert.isFalse(result.done, 'Refused: ' + result.message);
        }
        Assert.isTrue(results[2].message.contains('incomplete'), 'Says why: ' + results[2].message);
        Assert.isTrue(results[3].message.startsWith('Job not found'), 'Unknown Id: ' + results[3].message);
        Assert.areEqual('Processing', reload(processing.Id).Status__c, 'Untouched');
    }

    @IsTest
    static void replaysTwoHundredJobsInOneUpdateAndOneLogInsert() {
        List<Job__c> jobs = new List<Job__c>();
        for (Integer i = 0; i < JobActions.MAX_JOBS; i++) {
            jobs.add(newJob('Dead', true));
        }
        System.runAs(ReplayrTestAccess.runner()) {
            insert jobs;
        }
        List<Id> ids = new List<Id>(new Map<Id, Job__c>(jobs).keySet());

        System.runAs(userNamed(OPERATOR)) {
            Integer dmlBefore = Limits.getDmlStatements();
            JobActions.replay(ids, false);
            // Publishing the work-waiting event counts as a DML statement
            Assert.areEqual(3, Limits.getDmlStatements() - dmlBefore, 'One update, one log insert, one event');
            Assert.areEqual(JobActions.MAX_JOBS, [SELECT COUNT() FROM Job_Log__c WHERE Outcome__c = 'Replay_Requested'], 'One log row per job');
        }

        Assert.areEqual(JobActions.MAX_JOBS, [SELECT COUNT() FROM Job__c WHERE Status__c = 'Queued' WITH SYSTEM_MODE], 'All queued');
    }

    @IsTest
    static void operatorResolvesAnUnknownOutcomeWithANote() {
        Job__c job = insertJob('Outcome_Unknown', false);

        System.runAs(userNamed(OPERATOR)) {
            Assert.isTrue(JobActions.resolve(new List<Id>{ job.Id }, 'Succeeded', 'Order 1042 exists in the shop')[0].done, 'Resolved');
        }

        Job__c saved = reload(job.Id);
        Assert.areEqual('Succeeded', saved.Status__c, 'Marked as found');
        Assert.isTrue(saved.Result__c.endsWith(': Order 1042 exists in the shop'), 'Note kept: ' + saved.Result__c);
        Job_Log__c log = [SELECT Outcome__c, Message__c FROM Job_Log__c WHERE Job__c = :job.Id WITH SYSTEM_MODE];
        Assert.areEqual('Succeeded', log.Outcome__c, 'Logged');
        Assert.isTrue(log.Message__c.startsWith('Resolved as Succeeded by '), 'Logged with the name: ' + log.Message__c);
    }

    @IsTest
    static void resolvesOnlyUnknownOutcomesAndNeedsAValidRequest() {
        Job__c failed = insertJob('Failed', false);
        Job__c unknown = insertJob('Outcome_Unknown', false);

        System.runAs(userNamed(OPERATOR)) {
            Assert.isFalse(JobActions.resolve(new List<Id>{ failed.Id }, 'Succeeded', 'x')[0].done, 'Only unknown outcomes');
            for (List<String> bad : new List<List<String>>{
                new List<String>{ 'Queued', 'x' },
                new List<String>{ 'Failed', ' ' },
                new List<String>{ 'Failed', 'n'.repeat(JobLogs.TEXT_LIMIT + 1) }
            }) {
                try {
                    JobActions.resolve(new List<Id>{ unknown.Id }, bad[0], bad[1]);
                    Assert.fail('Refused: ' + bad[0]);
                } catch (JobActions.ActionException e) {
                    Assert.isNotNull(e.getMessage(), 'Says why');
                }
            }
        }
        Assert.areEqual('Failed', reload(failed.Id).Status__c, 'Untouched');
        Assert.areEqual('Outcome_Unknown', reload(unknown.Id).Status__c, 'Untouched');
    }

    @IsTest
    static void withoutThePermissionNothingHappens() {
        Job__c job = insertJob('Outcome_Unknown', true);

        System.runAs(userNamed(NO_PERMISSION)) {
            Assert.isTrue(actionError(job.Id, true)?.contains('permission'), 'Replay refused');
            Assert.isTrue(actionError(job.Id, false)?.contains('permission'), 'Resolve refused');
        }
        Assert.areEqual('Outcome_Unknown', reload(job.Id).Status__c, 'Untouched');
    }

    @IsTest
    static void refusesAnEmptyOrTooLargeRequest() {
        System.runAs(userNamed(OPERATOR)) {
            for (List<Id> ids : new List<List<Id>>{ new List<Id>(), new List<Id>(new Id[JobActions.MAX_JOBS + 1]) }) {
                try {
                    JobActions.replay(ids, true);
                    Assert.fail('Refused: ' + ids.size());
                } catch (JobActions.ActionException e) {
                    Assert.isTrue(e.getMessage().contains('between 1 and'), 'Says the limit');
                }
            }
        }
    }

    @IsTest
    static void aJobListedTwiceIsHandledOnce() {
        Job__c replayed = insertJob('Failed', true);
        Job__c resolved = insertJob('Outcome_Unknown', false);

        List<JobActions.Result> replays;
        List<JobActions.Result> resolutions;
        System.runAs(userNamed(OPERATOR)) {
            replays = JobActions.replay(new List<Id>{ replayed.Id, replayed.Id }, false);
            resolutions = JobActions.resolve(new List<Id>{ resolved.Id, resolved.Id }, 'Failed', 'Not in the shop');
        }

        Assert.isTrue(replays[0].done && !replays[1].done, 'First handled, repeat reported: ' + replays[1].message);
        Assert.isTrue(resolutions[0].done && !resolutions[1].done, 'First handled, repeat reported');
        Assert.areEqual(1, [SELECT COUNT() FROM Job_Log__c WHERE Job__c = :resolved.Id WITH SYSTEM_MODE], 'One log row for one decision');
    }

    @IsTest
    static void replayedJobIsSentAgainWithTheSameKey() {
        Job__c job = insertJob('Dead', true);
        System.runAs(ReplayrTestAccess.runner()) {
            update new Endpoint__c(Id = endpointId, Idempotency_Header__c = 'Idempotency-Key');
        }
        System.runAs(userNamed(OPERATOR)) {
            JobActions.replay(new List<Id>{ job.Id }, false);
        }
        KeyMock mock = new KeyMock();

        System.runAs(ReplayrTestAccess.runner()) {
            Test.setMock(HttpCalloutMock.class, mock);
            Test.startTest();
            JobWorker.start();
            Test.stopTest();
        }

        Assert.areEqual(job.Idempotency_Key__c, mock.key, 'Sent with the original key');
        Job__c saved = reload(job.Id);
        Assert.areEqual('Succeeded', saved.Status__c, 'The replay went through');
        Assert.areEqual(6, saved.Attempts__c, 'Counted as one more attempt');
    }

    private class KeyMock implements HttpCalloutMock {
        public String key;

        public HttpResponse respond(HttpRequest request) {
            key = request.getHeader('Idempotency-Key');
            HttpResponse response = new HttpResponse();
            response.setStatusCode(200);
            response.setStatus('OK');
            return response;
        }
    }

    @IsTest
    static void confirmedReplayOfAJobThatIsNotRetrySafeSaysTheRiskWasAccepted() {
        Job__c job = insertJob('Failed', false);

        System.runAs(userNamed(OPERATOR)) {
            JobActions.replay(new List<Id>{ job.Id }, true);
        }

        Assert.isTrue(reload(job.Id).Result__c.endsWith('Duplicate risk accepted.'), 'Recorded with the job');
    }

    @IsTest
    static void aJobWhoseRetriesWereUsedUpCanBeClosedOnlyAsFailed() {
        Job__c asFailed = insertJob('Dead', true);
        Job__c asSucceeded = insertJob('Dead', true);

        List<JobActions.Result> results;
        System.runAs(userNamed(OPERATOR)) {
            results = JobActions.resolve(new List<Id>{ asFailed.Id }, 'Failed', 'Gave up on this order');
            results.addAll(JobActions.resolve(new List<Id>{ asSucceeded.Id }, 'Succeeded', 'It worked'));
        }

        Assert.isTrue(results[0].done, 'Closed as Failed, so purge can remove it later');
        Assert.areEqual('Failed', reload(asFailed.Id).Status__c, 'Failed');
        Assert.isFalse(results[1].done, 'Never as Succeeded: every attempt failed');
        Assert.areEqual('Dead', reload(asSucceeded.Id).Status__c, 'Untouched');
    }

    @IsTest
    static void aTestRunIsNeverReplayed() {
        Job__c job = newJob('Succeeded', true);
        job.Test_Run__c = true;
        // Only test mode sets this, in system mode; no permission set can edit it
        Database.insert(job, true, AccessLevel.SYSTEM_MODE);

        JobActions.Result result;
        System.runAs(userNamed(OPERATOR)) {
            result = JobActions.replay(new List<Id>{ job.Id }, true)[0];
        }

        Assert.isFalse(result.done, 'Refused: the engine would send it as a real job');
        Assert.isTrue(result.message.contains('test run'), 'Says why: ' + result.message);
        Assert.areEqual('Succeeded', reload(job.Id).Status__c, 'Untouched');
    }

    @IsTest
    static void operatorCannotChangeAJobStatusDirectly() {
        Job__c job = insertJob('Outcome_Unknown', false);

        System.runAs(userNamed(OPERATOR)) {
            try {
                update as user new Job__c(Id = job.Id, Status__c = 'Queued');
                Assert.fail('Jobs are read-only for operators');
            } catch (TypeException e) {
                // User mode refuses before the database: no edit permission on the object
                Assert.isTrue(e.getMessage().contains('UPDATE not allowed'), 'Refused for lack of access: ' + e.getMessage());
            }
        }
        Assert.areEqual('Outcome_Unknown', reload(job.Id).Status__c, 'The confirmation can only be given through JobActions');
    }
}
