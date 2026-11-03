/**
 * Settles jobs left in Processing because their worker and its finalizer both stopped without recording a
 * result. Nobody knows whether the call arrived, so each is recorded as
 * Outcome unknown under the shared retry rule: a Retry-safe job waits for another attempt (or has none
 * left); any other job stays Outcome unknown for a person. Run by the hourly JobPoller.
 */
public with sharing class JobWatchdog {
    public static final String MESSAGE = 'The worker stopped without recording a result; the call may have been sent.';
    // A normal attempt takes seconds to minutes, queue time included. Acting early is still safe: a job that
    // isn't Retry-safe only goes to Outcome unknown, and a late link stops on its attempt number
    @TestVisible
    private static final Integer STUCK_MINUTES = 60;
    // More wait for the next hour
    @TestVisible
    private static final Integer BATCH_SIZE = 200;

    /**
     * Settles up to BATCH_SIZE stuck jobs: one query, one update and one log insert.
     * @return how many jobs were settled
     */
    public static Integer run() {
        Datetime cutoff = System.now().addMinutes(-STUCK_MINUTES);
        // Locked, so a finalizer finishing at this moment waits and then sees the job is no longer Processing.
        // Jobs claimed before Started_At__c existed fall back to when they last changed
        List<Job__c> stuck = [
            SELECT Id, Status__c, Started_At__c, LastModifiedDate, Retry_Safe__c, Attempts__c, Endpoint__r.Max_Attempts__c
            FROM Job__c
            WHERE Status__c = :JobWorker.PROCESSING
                AND (Started_At__c < :cutoff OR (Started_At__c = NULL AND LastModifiedDate < :cutoff))
            WITH USER_MODE
            LIMIT :BATCH_SIZE
            FOR UPDATE
        ];
        JobWorker.Attempt unknown = new JobWorker.Attempt(JobWorker.OUTCOME_UNKNOWN, JobWorker.OUTCOME_UNKNOWN, null, MESSAGE, null);
        List<Job__c> outcomes = new List<Job__c>();
        List<Job_Log__c> logs = new List<Job_Log__c>();
        for (Job__c job : stuck) {
            if (!isStillStuck(job, cutoff)) {
                continue;
            }
            Job__c outcome = new Job__c(Id = job.Id, Status__c = JobWorker.OUTCOME_UNKNOWN);
            String message = JobWorker.applyRetryRule(job, outcome, unknown);
            outcome.Result__c = JobLogs.shorten(message);
            outcomes.add(outcome);
            logs.add(JobLogs.newLog(job.Id, JobWorker.OUTCOME_UNKNOWN, null, message, null));
        }
        update as user outcomes;
        insert as user logs;
        return outcomes.size();
    }

    // Re-checked after the lock, as the claim does (P0.2): a cheap safety net
    private static Boolean isStillStuck(Job__c job, Datetime cutoff) {
        Datetime since = job.Started_At__c ?? job.LastModifiedDate;
        return job.Status__c == JobWorker.PROCESSING && since < cutoff;
    }
}
