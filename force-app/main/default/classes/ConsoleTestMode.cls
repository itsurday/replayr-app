/**
 * The console's test mode: previews an endpoint's request for one record, or sends it when the
 * endpoint is Side-effect-free (TestMode). For Replayr Admins only, judged as those who may edit endpoints
 * (decisions.md, ADR-013): a send is a real call, made as the person testing. Bodies Redactor can't fully mask are
 * withheld with the reason, as in a job's detail (ConsoleJobs.isMaskable).
 */
public with sharing class ConsoleTestMode {
    @TestVisible
    private static final String WITHHELD = 'Not shown: Replayr can only mask JSON, and JSON held inside a text value can\'t be masked.';

    /** One header of the request. */
    public class Header {
        @AuraEnabled
        public String name;
        @AuraEnabled
        public String value;
    }

    /** What test mode built and, when sent, what came back; everything shown is masked. */
    public class Outcome {
        @AuraEnabled
        public String method;
        @AuraEnabled
        public String url;
        @AuraEnabled
        public List<Header> headers = new List<Header>();
        @AuraEnabled
        public String body;
        /** Set when the request body isn't shown: why. */
        @AuraEnabled
        public String bodyWithheld;
        /** Whether the endpoint may be sent in test mode (Side-effect-free). */
        @AuraEnabled
        public Boolean sideEffectFree;
        @AuraEnabled
        public Boolean sent;
        @AuraEnabled
        public Integer statusCode;
        @AuraEnabled
        public String status;
        @AuraEnabled
        public String responseBody;
        @AuraEnabled
        public String responseWithheld;
        @AuraEnabled
        public Long durationMs;
        @AuraEnabled
        public String error;
        /** The test job a send was logged as. */
        @AuraEnabled
        public Id jobId;
    }

    /**
     * Builds an endpoint's request for one record, and sends it if asked and the endpoint is Side-effect-free.
     * @param endpointId the endpoint
     * @param recordId the record the body is built from, when the endpoint has a Request mapping
     * @param send true to send (Side-effect-free endpoints only); false to preview
     * @return what was built and what came back
     */
    @AuraEnabled
    public static Outcome run(Id endpointId, Id recordId, Boolean send) {
        if (!FeatureManagement.checkPermission(JobActions.PERMISSION) || !Schema.SObjectType.Endpoint__c.isUpdateable()) {
            throw ConsoleError.of('Testing an endpoint needs the Replayr Admin permission set (or another that may edit endpoints).');
        }
        TestMode.Result result;
        try {
            result = TestMode.run(endpointId, recordId, send == true);
        } catch (TestMode.TestModeException e) {
            // Its messages are about the endpoint, its mapping and the record, written for the admin
            throw ConsoleError.of(e.getMessage());
        } catch (Exception e) {
            // Only the type: other errors can name fields and objects
            throw ConsoleError.of('Replayr couldn\'t run the test (' + e.getTypeName() + ').');
        }
        // No request could be built (a bad path, method, header or Named Credential name): that reason is the answer
        if (result.method == null && result.error != null) {
            throw ConsoleError.of('The request can\'t be built: ' + result.error);
        }
        return toOutcome(result);
    }

    private static Outcome toOutcome(TestMode.Result result) {
        Outcome outcome = new Outcome();
        outcome.method = result.method;
        outcome.url = result.url;
        for (String name : result.headers.keySet()) {
            Header header = new Header();
            header.name = name;
            header.value = result.headers.get(name);
            outcome.headers.add(header);
        }
        outcome.sideEffectFree = result.sideEffectFree;
        outcome.sent = result.sent;
        outcome.statusCode = result.statusCode;
        outcome.status = result.status;
        outcome.durationMs = result.durationMs;
        outcome.error = result.error;
        outcome.jobId = result.jobId;
        if (ConsoleJobs.isMaskable(result.body)) {
            outcome.body = result.body;
        } else {
            outcome.bodyWithheld = WITHHELD;
        }
        if (ConsoleJobs.isMaskable(result.responseBody)) {
            outcome.responseBody = result.responseBody;
        } else {
            outcome.responseWithheld = WITHHELD;
        }
        return outcome;
    }
}
