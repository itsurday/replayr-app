/**
 * Records a worker link's outcome when the link ends with an unhandled exception, including an uncatchable
 * limit exception. The link's own DML is rolled back, but this instance keeps the progress the link noted
 * on it (docs/decisions.md, P0.3), so a call that was sent is never resent and its real result is kept.
 */
public with sharing class JobFinalizer implements Finalizer {
    private enum Step {
        STARTED,
        CALLING,
        RETURNED
    }

    private final Id jobId;
    // A finalizer that runs late must not record over a later attempt of the same job (watchdog, then retry)
    private final Decimal expectedAttempt;
    private Step phase = Step.STARTED;
    private JobWorker.Attempt attempt;

    /**
     * @param jobId the job the link is working on
     */
    public JobFinalizer(Id jobId) {
        this(jobId, null);
    }

    /**
     * @param jobId the job the link is working on
     * @param expectedAttempt the attempt the link was started for, or null to skip that check
     */
    public JobFinalizer(Id jobId, Decimal expectedAttempt) {
        this.jobId = jobId;
        this.expectedAttempt = expectedAttempt;
    }

    /** Notes that the request is about to be sent: from here a crash may mean the call arrived. */
    public void calling() {
        phase = Step.CALLING;
    }

    /**
     * Notes that the callout returned, with what happened, so a later crash still records the real result.
     * @param attempt the outcome of the call
     */
    public void returned(JobWorker.Attempt attempt) {
        this.attempt = attempt;
        phase = Step.RETURNED;
    }

    /**
     * Runs after the link ends. After a crash it records the job if that has not happened yet, then
     * restarts the chain, which the crashed link can no longer do. A link that succeeded already did both.
     * @param context the finalizer context
     */
    public void execute(FinalizerContext context) {
        if (context.getResult() == ParentJobResult.SUCCESS) {
            return;
        }
        if (isStillProcessing()) {
            recordAfterCrash(outcomeAfterCrash(crashType(context.getException())));
        }
        JobWorker.continueChain();
    }

    private Boolean isStillProcessing() {
        List<Job__c> jobs = [SELECT Status__c, Attempts__c FROM Job__c WHERE Id = :jobId WITH USER_MODE];
        return !jobs.isEmpty() &&
            jobs[0].Status__c == JobWorker.PROCESSING &&
            (expectedAttempt == null || jobs[0].Attempts__c == expectedAttempt);
    }

    // The worker's record() may be what crashed, for example missing access to the log, and would fail
    // the same way here: then at least move the job out of Processing. If even that fails, the error stays
    // on this finalizer's async job for the phase 3 watchdog and health check
    private void recordAfterCrash(JobWorker.Attempt outcome) {
        try {
            JobWorker.record(jobId, outcome);
        } catch (Exception e) {
            // The failed record() may have planned a retry before it failed: that retry is dropped with it
            update as user new Job__c(Id = jobId, Status__c = outcome.jobStatus, Next_Attempt_At__c = null);
        }
    }

    // Only the type, and the message of a platform limit error: other exception text can carry URLs or data
    private static String crashType(Exception crash) {
        if (crash == null) {
            return 'unknown error';
        }
        return crash instanceof LimitException ? crash.getTypeName() + ': ' + crash.getMessage() : crash.getTypeName();
    }

    private JobWorker.Attempt outcomeAfterCrash(String crash) {
        switch on phase {
            when RETURNED {
                return new JobWorker.Attempt(
                    attempt.jobStatus,
                    attempt.logOutcome,
                    attempt.httpStatus,
                    // Marker first, so shortening a long message never cuts it off
                    '(Recorded after the worker crashed: ' + crash + ') ' + (attempt.message ?? ''),
                    attempt.durationMs
                )
                .withRetryAfter(attempt.retryAfter);
            }
            when CALLING {
                // The call may have reached the remote system: record() retries it only for a Retry-safe job
                return new JobWorker.Attempt(
                    JobWorker.OUTCOME_UNKNOWN,
                    JobWorker.OUTCOME_UNKNOWN,
                    null,
                    'Worker stopped during the callout; the call may have arrived. ' + crash,
                    null
                );
            }
            when else {
                // Nothing was sent, but never retried, even when Retry-safe (a deliberate choice): such
                // crashes are rarely temporary and would only use up attempts; a person can replay the job
                return new JobWorker.Attempt(
                    JobWorker.FAILED,
                    JobWorker.NOT_SENT,
                    null,
                    'Worker stopped before the callout; nothing was sent. ' + crash,
                    null
                );
            }
        }
    }
}
