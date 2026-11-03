/**
 * The console's Jobs section: lists jobs, shows one with its attempts, and replays or resolves
 * jobs through JobActions. For Replayr Admins and Operators (Replayr_Manage_Jobs). Everything is read in user mode;
 * everything shown that could carry a secret (path, result, log messages, request body) is masked by the
 * provider's Redactor. Reading the masked names is part of each user-mode query, so a person who can't read them
 * (no field access, or the provider hidden by sharing) gets an error, never an unmasked value. Not masked, as they
 * are not secrets by design: the idempotency key, record Id and endpoint name.
 */
public with sharing class ConsoleJobs {
    public static final Integer PAGE_SIZE = 50;
    @TestVisible
    private static final Integer ATTEMPTS_SHOWN = 50;
    // The list's filters (decisions.md, ADR-022); null means every status
    private static final Map<String, List<String>> FILTERS = new Map<String, List<String>>{
        'needsPerson' => new List<String>{ JobWorker.OUTCOME_UNKNOWN, JobWorker.DEAD },
        'failed' => new List<String>{ JobWorker.FAILED },
        'waiting' => new List<String>{ JobWorker.QUEUED, JobWorker.RETRY_WAIT, JobWorker.PROCESSING },
        'succeeded' => new List<String>{ JobWorker.SUCCEEDED },
        'all' => null
    };
    private static final String ROW_FIELDS =
        'Id, Name, Endpoint__r.Name, Endpoint__r.Provider__c, Endpoint__r.Provider__r.Masked_Names__c, Status__c, Attempts__c, HTTP_Status__c, ' +
        'Result__c, Record_Id__c, Retry_Safe__c, Not_Replayable__c, Test_Run__c, CreatedDate, Next_Attempt_At__c';

    /** One job in the list. */
    public class Row {
        @AuraEnabled
        public Id id;
        @AuraEnabled
        public String name;
        @AuraEnabled
        public String endpoint;
        @AuraEnabled
        public String status;
        @AuraEnabled
        public String statusLabel;
        @AuraEnabled
        public Integer attempts;
        @AuraEnabled
        public Integer httpStatus;
        @AuraEnabled
        public String result;
        @AuraEnabled
        public String recordId;
        @AuraEnabled
        public Boolean retrySafe;
        /** What JobActions.replay accepts: a finished job with a complete stored request, not a test run. */
        @AuraEnabled
        public Boolean replayable;
        @AuraEnabled
        public Boolean testRun;
        @AuraEnabled
        public Datetime createdDate;
        @AuraEnabled
        public Datetime nextAttemptAt;
    }

    /** A page of the list, newest first. */
    public class JobPage {
        @AuraEnabled
        public List<Row> rows = new List<Row>();
        /** For the next page, pass the last row's createdDate and id in the JobQuery. */
        @AuraEnabled
        public Boolean hasMore = false;
    }

    /** One attempt from the job's log. */
    public class Attempt {
        @AuraEnabled
        public Datetime at;
        @AuraEnabled
        public String outcome;
        @AuraEnabled
        public Integer httpStatus;
        @AuraEnabled
        public String message;
        @AuraEnabled
        public Integer durationMs;
    }

    /** One job in full. */
    public class Detail {
        @AuraEnabled
        public Row job;
        @AuraEnabled
        public String method;
        @AuraEnabled
        public String path;
        @AuraEnabled
        public String idempotencyKey;
        /** Masked; null when the person may not read request bodies (only Admins may), there is none, or it is withheld. */
        @AuraEnabled
        public String requestBody;
        @AuraEnabled
        public Boolean requestBodyReadable;
        /** Set when the body exists but can't be masked reliably, so it isn't shown: why. */
        @AuraEnabled
        public String requestBodyWithheld;
        /** Newest first, at most ATTEMPTS_SHOWN. */
        @AuraEnabled
        public List<Attempt> attempts = new List<Attempt>();
    }

    private class MaskingException extends Exception {
    }

    /** What happened to one job in a replay or resolve. */
    public class ActionResult {
        @AuraEnabled
        public Id jobId;
        @AuraEnabled
        public Boolean done;
        @AuraEnabled
        public String message;
    }

    /** Which jobs to list. */
    public class JobQuery {
        /** needsPerson, failed, waiting, succeeded or all. */
        public String filter;
        /** Only this endpoint's jobs; null for all. */
        public Id endpointId;
        public Boolean includeTestRuns;
        /** The last row's createdDate and id, for the next page; null for the first. */
        public Datetime beforeCreated;
        public Id beforeId;
    }

    /**
     * The console's job list. Plain parameters, not a JobQuery: in real orgs a custom Apex class parameter was seen
     * to fail ("An internal server error has occurred") before any Apex ran (docs/apex-notes.md).
     * @param filter needsPerson, failed, waiting, succeeded or all
     * @param endpointId only this endpoint's jobs; null for all
     * @param includeTestRuns whether to include test runs
     * @param beforeCreated the last row's createdDate, for the next page; null for the first
     * @param beforeId the last row's id, for the next page; null for the first
     * @return the page
     */
    @AuraEnabled
    public static JobPage listJobs(String filter, Id endpointId, Boolean includeTestRuns, Datetime beforeCreated, Id beforeId) {
        JobQuery query = new JobQuery();
        query.filter = filter;
        query.endpointId = endpointId;
        query.includeTestRuns = includeTestRuns;
        query.beforeCreated = beforeCreated;
        query.beforeId = beforeId;
        return listPage(query);
    }

    /**
     * Lists jobs, newest first, a page at a time.
     * @param query which jobs
     * @return the page
     */
    public static JobPage listPage(JobQuery query) {
        requirePermission();
        if (query == null || !FILTERS.containsKey(query.filter)) {
            throw ConsoleError.of('Unknown filter.');
        }
        // Both or neither: half a cursor would quietly return the first page again
        if ((query.beforeCreated == null) != (query.beforeId == null)) {
            throw ConsoleError.of('Unknown page.');
        }
        List<String> statuses = FILTERS.get(query.filter);
        try {
            List<Job__c> jobs = Database.queryWithBinds(
                listQuery(query, statuses != null),
                new Map<String, Object>{
                    'statuses' => statuses,
                    'endpointId' => query.endpointId,
                    'beforeCreated' => query.beforeCreated,
                    'beforeId' => query.beforeId,
                    'rowLimit' => PAGE_SIZE + 1
                },
                AccessLevel.USER_MODE
            );
            JobPage page = new JobPage();
            page.hasMore = jobs.size() > PAGE_SIZE;
            Masker masker = new Masker();
            for (Integer i = 0; i < Math.min(jobs.size(), PAGE_SIZE); i++) {
                page.rows.add(toRow(jobs[i], masker));
            }
            return page;
        } catch (Exception e) {
            throw unreadable(e);
        }
    }

    // Only fixed text is added; every value is a bind variable
    private static String listQuery(JobQuery query, Boolean byStatus) {
        List<String> conditions = new List<String>();
        if (byStatus) {
            conditions.add('Status__c IN :statuses');
        }
        if (query.endpointId != null) {
            conditions.add('Endpoint__c = :endpointId');
        }
        if (query.includeTestRuns != true) {
            conditions.add('Test_Run__c = FALSE');
        }
        if (query.beforeCreated != null && query.beforeId != null) {
            conditions.add('(CreatedDate < :beforeCreated OR (CreatedDate = :beforeCreated AND Id < :beforeId))');
        }
        String whereClause = conditions.isEmpty() ? '' : ' WHERE ' + String.join(conditions, ' AND ');
        return 'SELECT ' + ROW_FIELDS + ' FROM Job__c' + whereClause + ' ORDER BY CreatedDate DESC, Id DESC LIMIT :rowLimit';
    }

    /**
     * Reads one job with its latest attempts.
     * @param jobId the job
     * @return the job, masked
     */
    @AuraEnabled
    public static Detail detail(Id jobId) {
        requirePermission();
        List<Job__c> jobs;
        try {
            jobs = [
                SELECT
                    Id, Name, Endpoint__r.Name, Endpoint__r.Provider__c, Endpoint__r.Provider__r.Masked_Names__c, Status__c, Attempts__c, HTTP_Status__c,
                    Result__c, Record_Id__c, Retry_Safe__c, Not_Replayable__c, Test_Run__c, CreatedDate, Next_Attempt_At__c,
                    Method__c, Path__c, Idempotency_Key__c,
                    (SELECT CreatedDate, Outcome__c, HTTP_Status__c, Message__c, Duration_Ms__c FROM Job_Logs__r ORDER BY CreatedDate DESC, Id DESC LIMIT :ATTEMPTS_SHOWN)
                FROM Job__c
                WHERE Id = :jobId
                WITH USER_MODE
            ];
        } catch (Exception e) {
            throw unreadable(e);
        }
        if (jobs.isEmpty()) {
            throw ConsoleError.of('Job not found, or you can\'t see it.');
        }
        try {
            return toDetail(jobs[0], new Masker());
        } catch (Exception e) {
            throw unreadable(e);
        }
    }

    private static Detail toDetail(Job__c job, Masker masker) {
        Redactor redactor = masker.of(job);
        Detail detail = new Detail();
        detail.job = toRow(job, masker);
        detail.method = job.Method__c;
        detail.path = redactor.url(job.Path__c);
        detail.idempotencyKey = job.Idempotency_Key__c;
        Map<String, String> outcomes = labels(Job_Log__c.Outcome__c);
        for (Job_Log__c log : job.Job_Logs__r) {
            Attempt attempt = new Attempt();
            attempt.at = log.CreatedDate;
            attempt.outcome = outcomes.get(log.Outcome__c) ?? log.Outcome__c;
            attempt.httpStatus = log.HTTP_Status__c?.intValue();
            attempt.message = redactor.message(log.Message__c);
            attempt.durationMs = log.Duration_Ms__c?.intValue();
            detail.attempts.add(attempt);
        }
        // Request bodies are Admin-only (phase 2): read only with field access, and never in a failed read's message
        detail.requestBodyReadable = Schema.SObjectType.Job__c.fields.Request_Body__c.isAccessible();
        if (detail.requestBodyReadable) {
            String body = [SELECT Request_Body__c FROM Job__c WHERE Id = :job.Id WITH USER_MODE].Request_Body__c;
            if (isMaskable(body)) {
                detail.requestBody = redactor.json(body);
            } else {
                detail.requestBodyWithheld = 'Not shown: Replayr can only mask JSON bodies, and JSON held inside a text value can\'t be masked.';
            }
        }
        return detail;
    }

    /**
     * Whether a body may be shown once Redactor.json has masked it (fails closed): JSON whose text values hold no
     * JSON themselves. Not XML or other formats, which Redactor leaves as they are. Test mode uses it too.
     * @param body a request or response body
     * @return true if blank or fully maskable
     */
    public static Boolean isMaskable(String body) {
        if (String.isBlank(body)) {
            return true;
        }
        try {
            return !holdsJsonText(JSON.deserializeUntyped(body));
        } catch (JSONException e) {
            return false;
        }
    }

    private static Boolean holdsJsonText(Object value) {
        if (value instanceof String) {
            String text = ((String) value).trim();
            return text.startsWith('{') || text.startsWith('[');
        }
        List<Object> children = value instanceof Map<String, Object>
            ? ((Map<String, Object>) value).values()
            : value instanceof List<Object> ? (List<Object>) value : new List<Object>();
        for (Object child : children) {
            if (holdsJsonText(child)) {
                return true;
            }
        }
        return false;
    }

    /**
     * Replays jobs (JobActions.replay).
     * @param jobIds up to JobActions.MAX_JOBS jobs
     * @param duplicateRiskConfirmed true once the person accepted JobActions.DUPLICATE_RISK
     * @return one result per job, in the order given
     */
    @AuraEnabled
    public static List<ActionResult> replay(List<Id> jobIds, Boolean duplicateRiskConfirmed) {
        try {
            return results(JobActions.replay(jobIds ?? new List<Id>(), duplicateRiskConfirmed == true));
        } catch (JobActions.ActionException e) {
            // Its messages are written for people: no permission, too many jobs
            throw ConsoleError.of(e.getMessage());
        } catch (Exception e) {
            throw ConsoleError.of('Replayr couldn\'t replay these jobs (' + e.getTypeName() + '). Nothing was changed.');
        }
    }

    /**
     * Resolves jobs whose outcome is unknown or whose retries were used up (JobActions.resolve).
     * @param jobIds up to JobActions.MAX_JOBS jobs
     * @param outcome Succeeded or Failed
     * @param note why, up to 255 characters
     * @return one result per job, in the order given
     */
    @AuraEnabled
    public static List<ActionResult> resolve(List<Id> jobIds, String outcome, String note) {
        try {
            return results(JobActions.resolve(jobIds ?? new List<Id>(), outcome, note));
        } catch (JobActions.ActionException e) {
            throw ConsoleError.of(e.getMessage());
        } catch (Exception e) {
            throw ConsoleError.of('Replayr couldn\'t resolve these jobs (' + e.getTypeName() + '). Nothing was changed.');
        }
    }

    private static List<ActionResult> results(List<JobActions.Result> given) {
        List<ActionResult> results = new List<ActionResult>();
        for (JobActions.Result one : given) {
            ActionResult result = new ActionResult();
            result.jobId = one.jobId;
            result.done = one.done;
            result.message = one.message;
            results.add(result);
        }
        return results;
    }

    private static Row toRow(Job__c job, Masker masker) {
        Row row = new Row();
        row.id = job.Id;
        row.name = job.Name;
        row.endpoint = job.Endpoint__r?.Name;
        row.status = job.Status__c;
        row.statusLabel = masker.statusLabels.get(job.Status__c) ?? job.Status__c;
        row.attempts = job.Attempts__c?.intValue();
        row.httpStatus = job.HTTP_Status__c?.intValue();
        row.result = masker.of(job).message(job.Result__c);
        row.recordId = job.Record_Id__c;
        row.retrySafe = job.Retry_Safe__c;
        row.replayable = JobActions.REPLAYABLE.contains(job.Status__c) && !job.Not_Replayable__c && !job.Test_Run__c;
        row.testRun = job.Test_Run__c;
        row.createdDate = job.CreatedDate;
        row.nextAttemptAt = job.Next_Attempt_At__c;
        return row;
    }

    // One Redactor per provider's masked names, and the status labels, built once per call
    private class Masker {
        final Map<String, Redactor> byNames = new Map<String, Redactor>();
        final Map<String, String> statusLabels = labels(Job__c.Status__c);

        Redactor of(Job__c job) {
            // A user-mode query returns a parent hidden by sharing as null rather than failing: without the provider
            // its masked names are unknown, so nothing is shown (fails closed). Every job has an endpoint
            if (job.Endpoint__r?.Provider__c == null) {
                throw new MaskingException('The provider of ' + job.Name + ' can\'t be read.');
            }
            String names = job.Endpoint__r.Provider__r?.Masked_Names__c ?? '';
            if (!byNames.containsKey(names)) {
                byNames.put(names, new Redactor(names));
            }
            return byNames.get(names);
        }
    }

    private static Map<String, String> labels(Schema.SObjectField field) {
        Map<String, String> labels = new Map<String, String>();
        for (Schema.PicklistEntry entry : field.getDescribe().getPicklistValues()) {
            labels.put(entry.getValue(), entry.getLabel());
        }
        return labels;
    }

    private static void requirePermission() {
        if (!FeatureManagement.checkPermission(JobActions.PERMISSION)) {
            throw ConsoleError.of('You need the Replayr Admin or Replayr Operator permission set.');
        }
    }

    // Only the type: a query error can name fields and objects
    private static AuraHandledException unreadable(Exception e) {
        return ConsoleError.of('Replayr couldn\'t read jobs (' + e.getTypeName() + '): check your Replayr permission set.');
    }
}
