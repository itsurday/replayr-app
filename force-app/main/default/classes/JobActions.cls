/**
 * What a person can do with a finished job: replay it, or resolve a job whose
 * outcome is unknown. Gated by the Replayr_Manage_Jobs custom permission. Jobs stay read-only for people, so
 * the writes here run in system mode after that check: nobody can bypass the duplicate-risk confirmation by
 * editing a job's status. The console (phase 4) calls these.
 */
public with sharing class JobActions {
    public static final String PERMISSION = 'Replayr_Manage_Jobs';
    public static final String DUPLICATE_RISK =
        'This job is not Retry-safe: replaying it may send the call twice, for example creating a second order or charge.';
    public static final Integer MAX_JOBS = 200;
    private static final String LISTED_TWICE = 'Listed more than once; handled once.';
    private static final String REPLAY_REQUESTED = 'Replay_Requested';
    // Also the console's "replayable" flag (ConsoleJobs)
    public static final Set<String> REPLAYABLE = new Set<String>{
        JobWorker.SUCCEEDED,
        JobWorker.FAILED,
        JobWorker.DEAD,
        JobWorker.OUTCOME_UNKNOWN
    };
    private static final Set<String> RESOLUTIONS = new Set<String>{ JobWorker.SUCCEEDED, JobWorker.FAILED };

    /** Thrown when the whole request is refused: no permission, too many jobs or an invalid argument. */
    public class ActionException extends Exception {
    }

    /** What happened to one job. */
    public class Result {
        public final Id jobId;
        public final Boolean done;
        public final String message;

        Result(Id jobId, Boolean done, String message) {
            this.jobId = jobId;
            this.done = done;
            this.message = message;
        }
    }

    /**
     * Queues finished jobs again, with their stored request body and idempotency key. They are sent once the
     * work-waiting event starts the chain (WorkWaiting), or else at the poller's next run. A replay counts as one more attempt: a job whose automatic
     * attempts are used up gets exactly one try; any other keeps the automatic retries it has left.
     * @param jobIds up to MAX_JOBS jobs
     * @param duplicateRiskConfirmed true once the person accepted DUPLICATE_RISK for jobs that aren't Retry-safe
     * @return one result per job, in the order given
     * @throws ActionException without the permission, or for too many jobs
     */
    public static List<Result> replay(List<Id> jobIds, Boolean duplicateRiskConfirmed) {
        Map<Id, Job__c> jobs = lockedJobs(jobIds);
        String note = 'Replay requested by ' + UserInfo.getName() + '.';
        List<Result> results = new List<Result>();
        List<Job__c> updates = new List<Job__c>();
        List<Job_Log__c> logs = new List<Job_Log__c>();
        Set<Id> seen = new Set<Id>();
        for (Id jobId : jobIds) {
            if (!seen.add(jobId)) {
                results.add(new Result(jobId, false, LISTED_TWICE));
                continue;
            }
            Job__c job = jobs.get(jobId);
            String refusal = replayRefusal(job, duplicateRiskConfirmed == true);
            // Kept with the job, where people look first, and in the log, which the next attempt doesn't overwrite
            String done = job?.Retry_Safe__c == true ? note : JobLogs.shorten(note + ' Duplicate risk accepted.');
            results.add(new Result(jobId, refusal == null, refusal ?? done));
            if (refusal == null) {
                updates.add(new Job__c(Id = jobId, Status__c = JobWorker.QUEUED, Next_Attempt_At__c = null, Result__c = done));
                logs.add(JobLogs.newLog(jobId, REPLAY_REQUESTED, null, done, null));
            }
        }
        new PrivilegedWriter().write(updates, logs);
        // Starts the chain as the integration user once this commits. Without the event (the person lacks Create
        // on it) the jobs stay queued for the poller's next run, which the person is told
        if (!updates.isEmpty() && !WorkWaiting.publish()) {
            return withNote(results, ' It starts at Replayr\'s next scheduled run.');
        }
        return results;
    }

    private static List<Result> withNote(List<Result> results, String note) {
        List<Result> noted = new List<Result>();
        for (Result result : results) {
            noted.add(result.done ? new Result(result.jobId, true, JobLogs.shorten(result.message + note)) : result);
        }
        return noted;
    }

    /**
     * Records what a person found out about jobs whose outcome is unknown, or closes jobs whose retries were
     * used up (as Failed only: those calls never succeeded), so purge can remove them later.
     * @param jobIds up to MAX_JOBS jobs
     * @param outcome Succeeded or Failed; a job whose retries were used up can only be resolved as Failed
     * @param note why, up to 255 characters; stored with the person's name
     * @return one result per job, in the order given
     * @throws ActionException without the permission, for too many jobs, another outcome, or a blank or long note
     */
    public static List<Result> resolve(List<Id> jobIds, String outcome, String note) {
        if (!RESOLUTIONS.contains(outcome)) {
            throw new ActionException('A job can only be resolved as Succeeded or Failed.');
        }
        if (String.isBlank(note) || note.length() > JobLogs.TEXT_LIMIT) {
            throw new ActionException('Say why, in at most ' + JobLogs.TEXT_LIMIT + ' characters.');
        }
        Map<Id, Job__c> jobs = lockedJobs(jobIds);
        String message = JobLogs.shorten('Resolved as ' + outcome + ' by ' + UserInfo.getName() + ': ' + note);
        List<Result> results = new List<Result>();
        List<Job__c> updates = new List<Job__c>();
        List<Job_Log__c> logs = new List<Job_Log__c>();
        Set<Id> seen = new Set<Id>();
        for (Id jobId : jobIds) {
            if (!seen.add(jobId)) {
                results.add(new Result(jobId, false, LISTED_TWICE));
                continue;
            }
            Job__c job = jobs.get(jobId);
            Boolean resolvable = job?.Status__c == JobWorker.OUTCOME_UNKNOWN || (job?.Status__c == JobWorker.DEAD && outcome == JobWorker.FAILED);
            results.add(
                new Result(jobId, resolvable, resolvable ? message : 'Only a job whose outcome is unknown, or one whose retries were used up (as Failed), can be resolved.')
            );
            if (resolvable) {
                updates.add(new Job__c(Id = jobId, Status__c = outcome, Result__c = message));
                logs.add(JobLogs.newLog(jobId, outcome, null, message, null));
            }
        }
        new PrivilegedWriter().write(updates, logs);
        return results;
    }

    // without sharing on purpose, and only here: people can read jobs but not edit them, so nobody can bypass
    // the duplicate-risk confirmation by changing a status directly. The jobs written were read in user mode
    // (ones the person can see) and the Replayr_Manage_Jobs permission was checked first. System mode skips
    // object and field access, but record sharing comes from the class, hence this small class
    private without sharing class PrivilegedWriter {
        void write(List<Job__c> updates, List<Job_Log__c> logs) {
            Database.update(updates, true, AccessLevel.SYSTEM_MODE);
            Database.insert(logs, true, AccessLevel.SYSTEM_MODE);
        }
    }

    // Read in user mode (only jobs the person can see) and locked, so a worker or the watchdog can't change
    // them mid-action; the status checks below run on the locked values
    private static Map<Id, Job__c> lockedJobs(List<Id> jobIds) {
        if (!FeatureManagement.checkPermission(PERMISSION)) {
            throw new ActionException('You need the "Replay and resolve Replayr jobs" permission.');
        }
        if (jobIds == null || jobIds.isEmpty() || jobIds.size() > MAX_JOBS) {
            throw new ActionException('Choose between 1 and ' + MAX_JOBS + ' jobs.');
        }
        try {
            return new Map<Id, Job__c>(
                [SELECT Id, Status__c, Retry_Safe__c, Not_Replayable__c, Test_Run__c FROM Job__c WHERE Id IN :jobIds WITH USER_MODE FOR UPDATE]
            );
        } catch (QueryException e) {
            // Usually a lock held by a worker or the watchdog for a moment
            throw new ActionException('Some of these jobs are busy right now; try again in a minute.');
        }
    }

    private static String replayRefusal(Job__c job, Boolean duplicateRiskConfirmed) {
        if (job == null) {
            return 'Job not found, or you can\'t see it.';
        }
        if (!REPLAYABLE.contains(job.Status__c)) {
            return 'Only a finished job can be replayed.';
        }
        // Through the engine it would be sent as a real job and its Response mapping applied
        if (job.Test_Run__c) {
            return 'A test run can\'t be replayed; run the test again.';
        }
        if (job.Not_Replayable__c) {
            return 'The stored request is incomplete, so this job can\'t be replayed.';
        }
        if (!job.Retry_Safe__c && !duplicateRiskConfirmed) {
            return DUPLICATE_RISK;
        }
        return null;
    }
}
