/**
 * Test mode: builds an endpoint's real request for one record and shows it. It is sent only
 * when the endpoint is Side-effect-free, and its response is shown but never written into Salesforce. A send is
 * logged as a Job marked Test run, recorded after the call (callouts come before DML). The console (phase 4)
 * calls it. Everything is read in user mode, and a send runs as the person testing. One run per transaction:
 * a second callout after the first run's log insert would be refused by the platform.
 */
public with sharing class TestMode {
    public static final Integer RESPONSE_LIMIT = 10000;
    private static final String REQUEST = 'Request';

    /** Thrown when no request can be built: unknown endpoint, mapping problems or a missing record. */
    public class TestModeException extends Exception {
    }

    /**
     * The request as built and, when sent, what came back. sent with no statusCode means the call failed
     * (error says why). shortcut: plain fields, filled in by run(); the phase 4 console wraps it for display
     */
    public class Result {
        public String method;
        public String url;
        public Map<String, String> headers = new Map<String, String>();
        public String body;
        public Boolean sent = false;
        public Integer statusCode;
        public String status;
        public String responseBody;
        public Long durationMs;
        public String error;
        public Id jobId;
        /** Whether the endpoint may be sent in test mode (Side-effect-free). */
        public Boolean sideEffectFree = false;
    }

    /**
     * @param endpointId the endpoint to test
     * @param recordId the record the request body is built from; needed when the endpoint has a Request mapping
     * @return the request, and the response when the endpoint is Side-effect-free
     * @throws TestModeException if no request can be built
     */
    public static Result run(Id endpointId, Id recordId) {
        return run(endpointId, recordId, true);
    }

    /**
     * @param endpointId the endpoint to test
     * @param recordId the record the request body is built from; needed when the endpoint has a Request mapping
     * @param send false to only build the request (a preview), even for a Side-effect-free endpoint
     * @return the request, and the response when sent
     * @throws TestModeException if no request can be built
     */
    public static Result run(Id endpointId, Id recordId, Boolean send) {
        Endpoint__c endpoint = endpointFor(endpointId);
        String body = bodyFor(endpointId, recordId);
        // A real key, so a send behaves exactly as a job would; recorded on the test job
        String key = UUID.randomUUID().toString();
        Result result = new Result();
        HttpRequest request;
        try {
            request = CalloutService.buildRequest(endpoint, body, key);
        } catch (CalloutService.InvalidEndpointException e) {
            result.error = e.getMessage();
            return result;
        }
        describe(request, endpoint.Idempotency_Header__c, result);
        result.sideEffectFree = endpoint.Side_Effect_Free__c;
        if (send == true && endpoint.Side_Effect_Free__c) {
            send(request, result);
            Savepoint beforeLog = Database.setSavepoint();
            try {
                result.jobId = recordTestJob(endpoint, recordId, body, key, result);
            } catch (DmlException e) {
                // The call already happened: keep what came back and say it wasn't logged (job and log row
                // together, never a job without its log)
                Database.rollback(beforeLog);
                result.error = (result.error == null ? '' : result.error + ' ') + 'The test call was sent but could not be logged.';
            }
        }
        return masked(result, new Redactor(endpoint.Provider__r?.Masked_Names__c));
    }

    // Only what is shown is masked; the test job keeps the real request (decisions.md, ADR-014)
    private static Result masked(Result result, Redactor redactor) {
        result.url = redactor.url(result.url);
        result.headers = redactor.headers(result.headers);
        result.body = redactor.json(result.body);
        result.responseBody = redactor.json(result.responseBody);
        // A platform error can repeat the URL, query string included
        result.error = redactor.message(result.error);
        return result;
    }

    // Allow_Sending__c is ignored on purpose: an admin tries an endpoint here before opening it to senders
    private static Endpoint__c endpointFor(Id endpointId) {
        List<Endpoint__c> endpoints = [
            SELECT Id, Method__c, Path__c, Side_Effect_Free__c, Retry_Safe__c, Idempotency_Header__c, Provider__r.Named_Credential__c,
                Provider__r.Masked_Names__c
            FROM Endpoint__c
            WHERE Id = :endpointId
            WITH USER_MODE
        ];
        if (endpoints.isEmpty()) {
            throw new TestModeException('Endpoint not found, or you can\'t see it.');
        }
        return endpoints[0];
    }

    private static String bodyFor(Id endpointId, Id recordId) {
        List<Mapping__c> mappings = [
            SELECT Rules__c, Target_Object__c
            FROM Mapping__c
            WHERE Endpoint__c = :endpointId AND Direction__c = :REQUEST
            WITH USER_MODE
            LIMIT 2
        ];
        if (mappings.isEmpty()) {
            return null;
        }
        if (mappings.size() > 1) {
            throw new TestModeException('The endpoint has more than one Request mapping; keep one.');
        }
        if (recordId == null) {
            throw new TestModeException('Choose a record to build the request body from.');
        }
        requireTargetObject(mappings[0].Target_Object__c, recordId);
        MergeTemplate.Result rendered;
        try {
            rendered = MergeTemplate.render(mappings[0].Rules__c, new Set<Id>{ recordId }).get(recordId);
        } catch (MergeTemplate.MergeException e) {
            throw new TestModeException(e.getMessage());
        }
        if (rendered?.error != null) {
            throw new TestModeException(rendered.error);
        }
        return rendered?.body;
    }

    // A template written for one object must not be filled from another the person happens to be able to read
    private static void requireTargetObject(String targetObject, Id recordId) {
        String expected;
        String actual;
        try {
            expected = FieldConverter.objectType(targetObject).getName();
            actual = recordId.getSobjectType().getDescribe(SObjectDescribeOptions.DEFERRED).getName();
        } catch (Exception e) {
            // An unknown object name or an Id of no object in this org: either way, not the mapping's object
            throw new TestModeException('Choose a record of the Request mapping\'s object.');
        }
        if (expected != actual) {
            throw new TestModeException('Choose a record of the Request mapping\'s object (' + targetObject + ').');
        }
    }

    // HttpRequest can't list its headers, so the ones Replayr sets are read back by name
    private static void describe(HttpRequest request, String idempotencyHeader, Result result) {
        result.method = request.getMethod();
        result.url = request.getEndpoint();
        // HttpRequest gives '' for no body; the preview says "none" plainly
        result.body = String.isEmpty(request.getBody()) ? null : request.getBody();
        for (String name : new List<String>{ 'Content-Type', idempotencyHeader }) {
            if (String.isNotBlank(name) && request.getHeader(name) != null) {
                result.headers.put(name, request.getHeader(name));
            }
        }
    }

    private static void send(HttpRequest request, Result result) {
        Long started = System.currentTimeMillis();
        result.sent = true;
        try {
            HttpResponse response = new Http().send(request);
            result.statusCode = response.getStatusCode();
            result.status = response.getStatus();
            result.responseBody = response.getBody()?.left(RESPONSE_LIMIT);
        } catch (CalloutException e) {
            result.error = e.getMessage();
        }
        result.durationMs = System.currentTimeMillis() - started;
    }

    // Recorded in system mode: people who test can't create jobs, and this records a call that already happened
    private static Id recordTestJob(Endpoint__c endpoint, Id recordId, String body, String key, Result result) {
        Boolean succeeded = result.statusCode != null && result.statusCode >= 200 && result.statusCode < 300;
        String status = succeeded ? JobWorker.SUCCEEDED : JobWorker.FAILED;
        String message = result.error ?? ('HTTP ' + result.statusCode + ' ' + result.status);
        Job__c job = new Job__c(
            Endpoint__c = endpoint.Id,
            Status__c = status,
            Method__c = endpoint.Method__c,
            Path__c = endpoint.Path__c,
            Record_Id__c = recordId,
            Request_Body__c = body,
            HTTP_Status__c = result.statusCode,
            Result__c = JobLogs.shorten('Test run. ' + message),
            Test_Run__c = true,
            Attempts__c = 1,
            Retry_Safe__c = endpoint.Retry_Safe__c,
            Idempotency_Key__c = key,
            Started_At__c = System.now()
        );
        Database.insert(job, true, AccessLevel.SYSTEM_MODE);
        String logOutcome = result.error != null ? JobWorker.OUTCOME_UNKNOWN : status;
        Database.insert(JobLogs.newLog(job.Id, logOutcome, result.statusCode, 'Test run. ' + message, result.durationMs), true, AccessLevel.SYSTEM_MODE);
        return job.Id;
    }
}
