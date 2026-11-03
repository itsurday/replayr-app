/**
 * One link of a worker chain. It calls out for the job the previous link claimed, records the result,
 * then claims the next queued job and enqueues the next link. The callout always comes before any DML
 * in the transaction, and a claim is committed before its job is called (docs/decisions.md, P0.2).
 */
public with sharing class JobWorker implements Queueable, Database.AllowsCallouts {
    public static final String QUEUED = 'Queued';
    public static final String PROCESSING = 'Processing';
    public static final String SUCCEEDED = 'Succeeded';
    public static final String FAILED = 'Failed';
    public static final String NOT_SENT = 'Not_Sent';
    public static final String OUTCOME_UNKNOWN = 'Outcome_Unknown';
    public static final String RETRY_WAIT = 'Retry_Wait';
    public static final String DEAD = 'Dead';
    // ORDER BY is not allowed with FOR UPDATE, so lock a few candidates and pick the oldest in code
    private static final Integer CLAIM_CANDIDATES = 10;
    // The longest delay a Queueable accepts (P0.1); longer waits are left to the hourly poller
    private static final Integer MAX_DELAY_MINUTES = 10;
    // An IMF-fixdate is 29 characters; anything longer is unreadable anyway
    private static final Integer RETRY_AFTER_LIMIT = 64;
    // A chain is taken as running while a job claimed this recently is still Processing: a link's work takes at
    // most about two minutes (a 120-second callout, lock waits). A dead link's job is settled later by the
    // watchdog (60 minutes), and the claim never takes a Processing job, so a new chain started meanwhile can't
    // send it twice. shortcut: a chain that dies right after a claim makes a poll in the next five minutes skip
    // the start, so its work waits one more hour
    private static final Integer CHAIN_RUNNING_MINUTES = 5;
    private static final String CHAIN_SIGNATURE = 'replayr-job-chain';

    private final Id jobId;
    // The attempt this link was started for: a late link must not call a job that was moved on and claimed
    // again (by the watchdog and a retry). Null skips the check (tests, wake-up links)
    private final Decimal expectedAttempt;

    // Test hook only: lets a test crash a link right after its callout returned, to prove the finalizer
    // records the real result. Production code never sets it
    @TestVisible
    private Boolean crashAfterCallout = false;

    @TestVisible
    private class SimulatedCrashException extends Exception {
    }

    /**
     * Creates the link for a job that is already claimed (Processing).
     * @param jobId the claimed job, or null for a link that only wakes the chain up for a due retry
     */
    public JobWorker(Id jobId) {
        this(jobId, null);
    }

    @TestVisible
    private JobWorker(Id jobId, Decimal expectedAttempt) {
        this.jobId = jobId;
        this.expectedAttempt = expectedAttempt;
    }

    /**
     * Claims the next queued job and starts a chain for it. Errors, such as a lock timeout or missing
     * access, reach the caller.
     * @return the claimed job's Id, or null when nothing is queued
     */
    public static Id start() {
        Job__c next = claimNext();
        if (next != null) {
            // Refused (DuplicateMessageException) while another chain's next link waits in the queue: the caller
            // rolls this claim back, so the two chains become one again
            System.enqueueJob(new JobWorker(next.Id, next.Attempts__c), chainOptions());
        } else {
            wakeUpForRetries();
        }
        return next?.Id;
    }

    /**
     * Starts the chain unless one is running: a job claimed within the last CHAIN_RUNNING_MINUTES means a link
     * is at work (a claim and its call take far less). The duplicate signature covers the moment a link waits
     * in the queue, which this check can't see (P4.1). Never throws, like continueChain.
     */
    public static void startChainIfIdle() {
        Datetime recent = System.now().addMinutes(-CHAIN_RUNNING_MINUTES);
        List<Job__c> working;
        try {
            // The first match is enough (a COUNT would read them all)
            working = [
                SELECT Id
                FROM Job__c
                WHERE Status__c = :PROCESSING AND Started_At__c >= :recent
                WITH USER_MODE
                LIMIT 1
            ];
        } catch (Exception e) {
            // Missing access to Job (a SecurityException in user mode) or a query failure: the claim needs the same
            // access, so no chain could run either; the work waits, and the health check reports it (6.2)
            return;
        }
        if (working.isEmpty()) {
            continueChain();
        }
    }

    // One signature for every link that holds a job. A duplicate is refused only while the first waits in the
    // queue, not while it runs (spike P4.1), so a running link can still enqueue its own next link
    private static AsyncOptions chainOptions() {
        AsyncOptions options = new AsyncOptions();
        options.DuplicateSignature = QueueableDuplicateSignature.Builder().addString(CHAIN_SIGNATURE).build();
        return options;
    }

    // Nothing to claim now: if a retry is due within the longest Queueable delay, one delayed link picks it
    // up. A Queueable may enqueue only one more (P0.2), which this is, since no next link was enqueued
    private static void wakeUpForRetries() {
        List<AggregateResult> due = [
            SELECT MIN(Next_Attempt_At__c) nextDue
            FROM Job__c
            WHERE Status__c = :RETRY_WAIT
            WITH USER_MODE
        ];
        Datetime nextDue = (Datetime) due[0].get('nextDue');
        if (nextDue == null) {
            return;
        }
        // Rounded up, and at least a minute, so a due job that couldn't be claimed never makes a tight loop
        Long waitMs = nextDue.getTime() - System.now().getTime();
        Integer minutes = Math.max(1, ((waitMs + 59999) / 60000).intValue());
        // shortcut: each idle chain queues its own wake-up, so N parallel chains can keep N wake-ups going
        // while retries are due within ten minutes; harmless (claims lock) but uses async runs. Deduplicate
        // (one wake-up per org) if many chains run in parallel. No chain signature here: while it waits (up
        // to ten minutes) it would refuse every new start, delaying new work; the links it starts carry one
        if (minutes <= MAX_DELAY_MINUTES) {
            System.enqueueJob(new JobWorker(null), minutes);
        }
    }

    /**
     * Calls out for this link's job, records the result and starts the next link.
     * @param context the Queueable context (unused)
     */
    public void execute(QueueableContext context) {
        if (jobId == null) {
            continueChain();
            return;
        }
        // Attached first, so a crash at any later point is recorded from the progress noted on it
        JobFinalizer finalizer = new JobFinalizer(jobId, expectedAttempt);
        System.attachFinalizer(finalizer);
        // The body is loaded for this one job only, just before its callout: never in bulk (heap)
        List<Job__c> jobs = [
            SELECT Id, Status__c, Attempts__c, Method__c, Path__c, Request_Body__c, Record_Id__c, Endpoint__c, Idempotency_Key__c,
                Endpoint__r.Idempotency_Header__c, Endpoint__r.Provider__r.Named_Credential__c
            FROM Job__c
            WHERE Id = :jobId
            WITH USER_MODE
        ];
        // Only a claimed job is called. This stops a duplicate link that starts after this one finished;
        // it is not a lock, so overlapping links are handled by the finalizer and watchdog rules
        if (jobs.isEmpty() || jobs[0].Status__c != PROCESSING || isStaleLink(jobs[0])) {
            return;
        }
        Job__c job = jobs[0];
        // Built before calling(): a failure here sent nothing, so it must not be recorded as Outcome unknown.
        // Path, method, header and key are checked inside call(), which records that failure as Not sent
        Endpoint__c endpoint = endpointFor(job);
        List<Mapping__c> responseMappings = responseMappings(job.Endpoint__c);
        if (responseMappings.size() > 1) {
            record(job.Id, new Attempt(FAILED, NOT_SENT, null, 'The endpoint has more than one Response mapping; keep one', null));
            continueChain();
            return;
        }
        finalizer.calling();
        Call result = call(endpoint, job.Request_Body__c, job.Idempotency_Key__c);
        Attempt attempt = result.attempt;
        finalizer.returned(attempt);
        if (crashAfterCallout) {
            throw new SimulatedCrashException('Simulated crash after the callout returned');
        }
        if (attempt.jobStatus == SUCCEEDED && !responseMappings.isEmpty()) {
            // If the link dies while writing (a huge body can exceed the heap), the write is rolled back and
            // the finalizer says so. The body is read only here, after the finalizer has the call's result
            finalizer.returned(attempt.withNote('Response not saved: the worker stopped while writing it.'));
            attempt = attempt.withNote(writeResponse(responseMappings[0], result.response.getBody(), job.Record_Id__c));
        }
        recordIfStillCurrent(job.Id, attempt);
        continueChain();
    }

    // A link slow enough for the watchdog may find its job settled, replayed or retried meanwhile: its late
    // result is logged but never overwrites the newer state. Locked, so nothing changes the job in between
    private void recordIfStillCurrent(Id currentJobId, Attempt attempt) {
        List<Job__c> jobs = [SELECT Status__c, Attempts__c FROM Job__c WHERE Id = :currentJobId WITH USER_MODE FOR UPDATE];
        if (jobs.isEmpty()) {
            return;
        }
        if (jobs[0].Status__c == PROCESSING && !isStaleLink(jobs[0])) {
            record(currentJobId, attempt);
            return;
        }
        String late = '(Arrived after the job moved on; not applied) ' + attempt.message;
        insert as user JobLogs.newLog(currentJobId, attempt.logOutcome, attempt.httpStatus, late, attempt.durationMs);
    }

    private Boolean isStaleLink(Job__c job) {
        return expectedAttempt != null && job.Attempts__c != expectedAttempt;
    }

    private static List<Mapping__c> responseMappings(Id endpointId) {
        return [
            SELECT Direction__c, Target_Object__c, Operation__c, Match_Field__c, List_Path__c, Rules__c
            FROM Mapping__c
            WHERE Endpoint__c = :endpointId AND Direction__c = 'Response'
            WITH USER_MODE
            LIMIT 2
        ];
    }

    // The call already succeeded, so a failed write never changes the job's status (decisions.md, ADR-008): it is
    // rolled back on its own and reported in the result. Only a WriteException's message is kept; other
    // exception text can carry record data
    private static String writeResponse(Mapping__c mapping, String responseBody, String recordId) {
        // A 204 No Content, for example: nothing to write, which is not an error
        if (String.isBlank(responseBody)) {
            return 'Response: empty, nothing to save.';
        }
        Savepoint beforeWrite = Database.setSavepoint();
        try {
            ResponseWriter.Outcome outcome = ResponseWriter.write(mapping, responseBody, idOrNull(recordId));
            if (outcome.errors.isEmpty()) {
                return 'Response: ' + outcome.saved + ' saved.';
            }
            return 'Response: ' + outcome.saved + ' saved, ' + outcome.errors.size() + ' problems. First: ' + outcome.errors[0];
        } catch (Exception e) {
            Database.rollback(beforeWrite);
            return 'Response not saved: ' + (e instanceof ResponseWriter.WriteException ? e.getMessage() : e.getTypeName());
        }
    }

    // Record Id is free text on the job; a malformed one simply has no record to write back to
    private static Id idOrNull(String recordId) {
        try {
            return String.isBlank(recordId) ? null : Id.valueOf(recordId);
        } catch (StringException e) {
            return null;
        }
    }

    /**
     * Writes an attempt's outcome: the job's status and result, and one log row. Used by the worker and,
     * after a crash, by the finalizer, so both record outcomes the same way.
     * @param jobId the job
     * @param attempt what happened
     */
    public static void record(Id jobId, Attempt attempt) {
        Job__c outcome = new Job__c(Id = jobId, Status__c = attempt.jobStatus, HTTP_Status__c = attempt.httpStatus);
        String message = attempt.message;
        // Read from the job itself, so the worker and the finalizer decide exactly alike
        if (RetryPolicy.isRetryable(attempt)) {
            List<Job__c> jobs = [
                SELECT Retry_Safe__c, Attempts__c, Endpoint__r.Max_Attempts__c
                FROM Job__c
                WHERE Id = :jobId
                WITH USER_MODE
            ];
            message = jobs.isEmpty() ? message : applyRetryRule(jobs[0], outcome, attempt);
        }
        outcome.Result__c = JobLogs.shorten(message);
        update as user outcome;
        insert as user JobLogs.newLog(jobId, attempt.logOutcome, attempt.httpStatus, message, attempt.durationMs);
    }

    /**
     * The retry rule shared by the worker, the finalizer and the watchdog: a Retry-safe job whose error may
     * pass waits for another attempt, or has used them all up. Never for a job that isn't Retry-safe: it
     * might be sent twice. Sets the status (and next attempt) on the outcome being built.
     * @param job loaded with Retry_Safe__c, Attempts__c and Endpoint__r.Max_Attempts__c
     * @param outcome the job update being built
     * @param attempt what happened
     * @return the message to record
     */
    public static String applyRetryRule(Job__c job, Job__c outcome, Attempt attempt) {
        if (!RetryPolicy.isRetryable(attempt) || !job.Retry_Safe__c) {
            return attempt.message;
        }
        if (!RetryPolicy.hasAttemptsLeft(job.Attempts__c, job.Endpoint__r?.Max_Attempts__c)) {
            outcome.Status__c = DEAD;
            return attempt.withNote('No attempts left').message;
        }
        Datetime next = RetryPolicy.nextAttemptAt(job.Attempts__c?.intValue(), attempt.retryAfter, System.now(), Math.random());
        outcome.Status__c = RETRY_WAIT;
        outcome.Next_Attempt_At__c = next;
        return attempt.withNote('Retrying at ' + next.formatGmt('yyyy-MM-dd HH:mm') + ' GMT').message;
    }

    /**
     * Starts the next link. A failure here must never roll back an outcome just recorded for a call
     * that was already sent, so it only undoes its own claim.
     */
    public static void continueChain() {
        Savepoint beforeClaim = Database.setSavepoint();
        try {
            start();
        } catch (Exception e) {
            // shortcut: a lock timeout or missing access ends the chain and leaves the next job Queued; the hourly
            // JobPoller restarts it, and the health check (6.2) alerts when work stops moving
            Database.rollback(beforeClaim);
            // The chain-depth limit (5 links in Developer, Trial and scratch orgs, gate 4a) is an AsyncException
            // (a duplicate signature is not): the hand-off starts a fresh chain, with its own depth count, once
            // this link (or its finalizer) commits. Never from the hand-off's own trigger, so it can't loop
            if (e instanceof AsyncException && !Trigger.isExecuting) {
                WorkWaiting.publish();
            }
        }
    }

    @TestVisible
    private static Job__c claimNext() {
        Datetime now = System.now();
        // Due retries are claimed directly, as if queued again
        List<Job__c> candidates = [
            SELECT Id, Status__c, Sequence__c, Attempts__c, Next_Attempt_At__c, Idempotency_Key__c
            FROM Job__c
            WHERE Status__c = :QUEUED OR (Status__c = :RETRY_WAIT AND Next_Attempt_At__c <= :now)
            WITH USER_MODE
            LIMIT :CLAIM_CANDIDATES
            FOR UPDATE
        ];
        Job__c next;
        for (Job__c candidate : candidates) {
            if (isClaimable(candidate, now) && (next == null || sequenceOf(candidate) < sequenceOf(next))) {
                next = candidate;
            }
        }
        if (next != null) {
            // Returned with its new attempt number, which its link checks
            next.Attempts__c = (next.Attempts__c ?? 0) + 1;
            update as user new Job__c(
                Id = next.Id,
                Status__c = PROCESSING,
                Attempts__c = next.Attempts__c,
                Started_At__c = System.now(),
                Next_Attempt_At__c = null,
                // Made once and committed with the claim, before any call: every attempt sends the same key
                Idempotency_Key__c = next.Idempotency_Key__c ?? UUID.randomUUID().toString()
            );
        }
        return next;
    }

    // Re-checked after the lock, as the query's filter is (P0.2): a cheap safety net
    private static Boolean isClaimable(Job__c job, Datetime now) {
        return job.Status__c == QUEUED || (job.Status__c == RETRY_WAIT && job.Next_Attempt_At__c <= now);
    }

    // Sequence__c is an auto-number, so Apex returns it as text: compare numerically, or "10" sorts before "9"
    private static Long sequenceOf(Job__c job) {
        return Long.valueOf(job.Sequence__c);
    }

    // The call uses the method and path copied onto the job, not the endpoint's current values
    private static Endpoint__c endpointFor(Job__c job) {
        return new Endpoint__c(
            Method__c = job.Method__c,
            Path__c = job.Path__c,
            // The header name is the endpoint's current one; the key is the job's own
            Idempotency_Header__c = job.Endpoint__r.Idempotency_Header__c,
            Provider__r = new Provider__c(Named_Credential__c = job.Endpoint__r.Provider__r.Named_Credential__c)
        );
    }

    // The response stays out of Attempt, which the finalizer keeps: its body is read at most once and never stored
    private class Call {
        final Attempt attempt;
        final HttpResponse response;

        Call(Attempt attempt, HttpResponse response) {
            this.attempt = attempt;
            this.response = response;
        }
    }

    private static Call call(Endpoint__c endpoint, String body, String idempotencyKey) {
        Long started = System.currentTimeMillis();
        try {
            HttpResponse response = CalloutService.send(endpoint, body, idempotencyKey);
            Integer code = response.getStatusCode();
            String status = code >= 200 && code < 300 ? SUCCEEDED : FAILED;
            Attempt attempt = new Attempt(status, status, code, 'HTTP ' + code + ' ' + response.getStatus(), elapsedSince(started))
                .withRetryAfter(response.getHeader('Retry-After'));
            return new Call(attempt, response);
        } catch (CalloutService.InvalidEndpointException e) {
            return new Call(new Attempt(FAILED, NOT_SENT, null, e.getMessage(), null), null);
        } catch (CalloutException e) {
            // A timeout may have reached the remote system, so only a Retry-safe job is resent (record()).
            // shortcut: errors such as a missing Named Credential were never sent but are treated the same;
            // tell them apart if platform messages prove stable enough to match
            String message = withoutPath(e.getMessage(), endpoint.Path__c);
            return new Call(new Attempt(OUTCOME_UNKNOWN, OUTCOME_UNKNOWN, null, message, elapsedSince(started)), null);
        }
    }

    // Some platform errors repeat the URL, and a path can carry a query-string key. Best effort: a literal
    // match, so an encoded form of the path is not caught
    private static String withoutPath(String message, String path) {
        if (message == null || String.isBlank(path) || path == '/') {
            return message;
        }
        String scrubbed = message.replace(path, '<path>');
        String query = path.substringAfter('?');
        return String.isBlank(query) ? scrubbed : scrubbed.replace(query, '<query>');
    }

    private static Long elapsedSince(Long started) {
        return System.currentTimeMillis() - started;
    }

    /** What one attempt at a job did: the job status and log outcome to record, and its details. */
    public class Attempt {
        public final String jobStatus;
        public final String logOutcome;
        public final Integer httpStatus;
        public final String message;
        public final Long durationMs;
        // The response's Retry-After header, kept short: it comes from the remote system
        public final String retryAfter;

        /**
         * @param jobStatus a Job__c.Status__c value
         * @param logOutcome a Job_Log__c.Outcome__c value
         * @param httpStatus the HTTP status code, or null if no response arrived
         * @param message a short summary; never a body or header
         * @param durationMs how long the callout took, or null if nothing was sent
         */
        public Attempt(String jobStatus, String logOutcome, Integer httpStatus, String message, Long durationMs) {
            this(jobStatus, logOutcome, httpStatus, message, durationMs, null);
        }

        private Attempt(String jobStatus, String logOutcome, Integer httpStatus, String message, Long durationMs, String retryAfter) {
            this.jobStatus = jobStatus;
            this.logOutcome = logOutcome;
            this.httpStatus = httpStatus;
            this.message = message;
            this.durationMs = durationMs;
            this.retryAfter = retryAfter?.left(RETRY_AFTER_LIMIT);
        }

        /**
         * @param retryAfter the response's Retry-After header, or null
         * @return the same attempt with the header kept for the retry decision
         */
        public Attempt withRetryAfter(String retryAfter) {
            return new Attempt(jobStatus, logOutcome, httpStatus, message, durationMs, retryAfter);
        }

        /**
         * Adds a note to the message, such as what happened to the response.
         * @param note text to add after the message
         * @return the same attempt with the note added
         */
        public Attempt withNote(String note) {
            return new Attempt(jobStatus, logOutcome, httpStatus, message + '. ' + note, durationMs, retryAfter);
        }
    }
}
