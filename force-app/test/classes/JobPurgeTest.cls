@IsTest
private with sharing class JobPurgeTest {
    @TestSetup
    static void setup() {
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

    private static Job__c newJob(String status) {
        return new Job__c(Endpoint__c = endpointId, Status__c = status, Method__c = 'PUT', Path__c = '/items');
    }

    private static Job__c insertWithLog(String status) {
        Job__c job = newJob(status);
        insert job;
        insert JobLogs.newLog(job.Id, JobWorker.FAILED, 500, 'HTTP 500', 10);
        return job;
    }

    // A cutoff just ahead: every job counts as old, since a test can't age its records
    private static void purgeEverythingOld() {
        Test.startTest();
        Database.executeBatch(new JobPurge(System.now().addMinutes(1)), JobPurge.BATCH_SIZE);
        Test.stopTest();
    }

    @IsTest
    static void purgesOnlyFinishedJobsWithTheirLogs() {
        System.runAs(ReplayrTestAccess.runner()) {
            Job__c succeeded = insertWithLog('Succeeded');
            Job__c failed = insertWithLog('Failed');
            Map<String, Job__c> kept = new Map<String, Job__c>();
            for (String status : new List<String>{ 'Queued', 'Processing', 'Retry_Wait', 'Outcome_Unknown', 'Dead' }) {
                kept.put(status, insertWithLog(status));
            }

            purgeEverythingOld();

            Assert.areEqual(0, [SELECT COUNT() FROM Job__c WHERE Id IN :new List<Id>{ succeeded.Id, failed.Id }], 'Finished jobs purged');
            Assert.areEqual(kept.size(), [SELECT COUNT() FROM Job__c], 'Open jobs and jobs needing a person kept');
            Assert.areEqual(kept.size(), [SELECT COUNT() FROM Job_Log__c], 'Only the purged jobs\' logs went with them');
            // The recycle bin can't be checked: emptied rows still show with ALL ROWS for a while (docs/apex-notes.md)
        }
    }

    @IsTest
    static void recentFinishedJobsAreKept() {
        System.runAs(ReplayrTestAccess.runner()) {
            insertWithLog('Succeeded');

            Test.startTest();
            Database.executeBatch(new JobPurge(30), JobPurge.BATCH_SIZE);
            Test.stopTest();

            Assert.areEqual(1, [SELECT COUNT() FROM Job__c], 'Changed today, kept for 30 days');
        }
    }

    @IsTest
    static void testRunsArePurgedLikeOtherJobs() {
        Job__c testRun = newJob('Succeeded');
        testRun.Test_Run__c = true;
        Database.insert(testRun, true, AccessLevel.SYSTEM_MODE);

        System.runAs(ReplayrTestAccess.runner()) {
            purgeEverythingOld();
        }

        Assert.areEqual(0, [SELECT COUNT() FROM Job__c], 'Purged');
    }

    @IsTest
    static void aJobReplayedAfterTheBatchStartedIsKept() {
        System.runAs(ReplayrTestAccess.runner()) {
            Job__c job = insertWithLog('Failed');
            // Selected as finished, then replayed before its batch ran
            update new Job__c(Id = job.Id, Status__c = 'Queued');

            new JobPurge(System.now().addMinutes(1)).execute(null, new List<Job__c>{ new Job__c(Id = job.Id) });

            Assert.areEqual(1, [SELECT COUNT() FROM Job__c WHERE Id = :job.Id], 'Kept: no longer finished');
        }
    }

    @IsTest
    static void purgesTwoHundredJobsInOneBatch() {
        System.runAs(ReplayrTestAccess.runner()) {
            List<Job__c> jobs = new List<Job__c>();
            for (Integer i = 0; i < JobPurge.BATCH_SIZE; i++) {
                jobs.add(newJob('Succeeded'));
            }
            insert jobs;
            List<Job_Log__c> logs = new List<Job_Log__c>();
            for (Job__c job : jobs) {
                for (Integer attempt = 0; attempt < 10; attempt++) {
                    logs.add(JobLogs.newLog(job.Id, JobWorker.FAILED, 503, 'HTTP 503', 10));
                }
            }
            insert logs;

            new JobPurge(System.now().addMinutes(1)).execute(null, jobs);

            Assert.areEqual(0, [SELECT COUNT() FROM Job__c], 'All 200 purged');
            Assert.areEqual(0, [SELECT COUNT() FROM Job_Log__c], 'And their 2,000 log rows');
        }
    }

    @IsTest
    static void aJobWithUnusuallyManyLogsNeverBlocksTheOthers() {
        System.runAs(ReplayrTestAccess.runner()) {
            Job__c heavy = newJob('Failed');
            Job__c light = newJob('Succeeded');
            insert new List<Job__c>{ heavy, light };
            List<Job_Log__c> logs = new List<Job_Log__c>();
            for (Integer i = 0; i < 30; i++) {
                logs.add(JobLogs.newLog(heavy.Id, JobWorker.FAILED, 503, 'HTTP 503', 10));
            }
            logs.add(JobLogs.newLog(light.Id, JobWorker.SUCCEEDED, 200, 'HTTP 200', 10));
            insert logs;
            // As if the heavy job had thousands of logs: over this batch's row budget on its own
            JobPurge.rowBudget = 10;

            new JobPurge(System.now().addMinutes(1)).execute(null, new List<Job__c>{ heavy, light });

            Assert.areEqual(0, [SELECT COUNT() FROM Job__c WHERE Id = :light.Id], 'The light job is purged');
            Assert.areEqual(1, [SELECT COUNT() FROM Job__c WHERE Id = :heavy.Id], 'The heavy job is skipped, not the batch failed');
        }
    }

    @IsTest
    static void aJobChangedAfterTheCutoffIsKept() {
        System.runAs(ReplayrTestAccess.runner()) {
            Job__c job = insertWithLog('Succeeded');

            new JobPurge(System.now().addDays(-1)).execute(null, new List<Job__c>{ job });

            Assert.areEqual(1, [SELECT COUNT() FROM Job__c], 'Changed today, newer than the cutoff');
        }
    }

    @IsTest
    static void aDeadJobIsKeptUntilAPersonClosesItThenPurged() {
        System.runAs(ReplayrTestAccess.runner()) {
            Job__c job = insertWithLog('Dead');
            new JobPurge(System.now().addMinutes(1)).execute(null, new List<Job__c>{ job });
            Assert.areEqual(1, [SELECT COUNT() FROM Job__c], 'Needs a person: kept');

            JobActions.resolve(new List<Id>{ job.Id }, 'Failed', 'Checked; the order was cancelled');
            new JobPurge(System.now().addMinutes(1)).execute(null, new List<Job__c>{ job });

            Assert.areEqual(0, [SELECT COUNT() FROM Job__c], 'Closed as Failed, then purged');
        }
    }

    @IsTest
    static void pollerStartsTheNextPurgeAfterADay() {
        Replayr_Settings__c settings = Replayr_Settings__c.getOrgDefaults();
        settings.Last_Purge_Started__c = System.now().addHours(-24);
        Database.upsert(settings, true, AccessLevel.SYSTEM_MODE);
        Datetime before = System.now();

        System.runAs(ReplayrTestAccess.runner()) {
            Test.startTest();
            new JobPoller().execute(null);
            Test.stopTest();
        }

        Assert.isTrue(Replayr_Settings__c.getOrgDefaults().Last_Purge_Started__c >= before.addSeconds(-1), 'Started again');
        Assert.areEqual(1, [SELECT COUNT() FROM AsyncApexJob WHERE ApexClass.Name = 'JobPurge' AND JobType = 'BatchApex'], 'One batch');
    }

    @IsTest
    static void retentionDaysDefaultToThirty() {
        Assert.areEqual(30, JobPurge.keptDays(null), 'Blank');
        Assert.areEqual(30, JobPurge.keptDays(0), 'Below 1');
        Assert.areEqual(7, JobPurge.keptDays(7), 'Set');
    }

    @IsTest
    static void pollerStartsThePurgeOnceADay() {
        System.runAs(ReplayrTestAccess.runner()) {
            Test.startTest();
            new JobPoller().execute(null);
            Datetime firstStart = Replayr_Settings__c.getOrgDefaults().Last_Purge_Started__c;
            new JobPoller().execute(null);
            Test.stopTest();

            Assert.isNotNull(firstStart, 'Started on the first poll');
            Assert.areEqual(firstStart, Replayr_Settings__c.getOrgDefaults().Last_Purge_Started__c, 'Not again within 23 hours');
        }
        Assert.areEqual(1, [SELECT COUNT() FROM AsyncApexJob WHERE ApexClass.Name = 'JobPurge' AND JobType = 'BatchApex'], 'One batch');
    }
}
