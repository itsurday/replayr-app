/**
 * The "Send with Replayr" Flow action. Replayr's first global code: its name,
 * inputs and outputs can never be removed or renamed once released, only added to (decision 1, phase 4).
 * Meant for a record-triggered flow's Run Asynchronously path: it saves one job per record (JobCreation) and
 * publishes the work-waiting event, so the calls go out in the background as the integration user. A record
 * that can't be sent gets an Error and no Job Id, and the others go ahead. Without the Replayr Sender
 * permission set the whole action fails, so the flow's error email tells the admin instead of sends being
 * lost unnoticed (on the async path that doesn't undo the user's save).
 */
global with sharing class SendWithReplayr {
    private static final String TOO_MANY = 'Send at most ' + JobCreation.MAX_REQUESTS + ' records at a time.';

    /** Thrown when the running user may not send at all: a setup problem for the admin. */
    public class SendException extends Exception {
    }

    /** One record to send. */
    global class Request {
        @InvocableVariable(
            label='Endpoint key'
            description='The Key of the Replayr endpoint to send to. Keys stay the same in sandboxes and production.'
            required=true
        )
        global String endpointKey;

        @InvocableVariable(
            label='Record Id'
            description='The record to send, of the object the endpoint\'s Request mapping is for. Optional when the endpoint has no Request mapping.'
        )
        global Id recordId;
    }

    /** What happened to one record. */
    global class Result {
        @InvocableVariable(label='Job Id' description='The Replayr job that sends the record; empty when it couldn\'t be sent.')
        global Id jobId;

        @InvocableVariable(label='Error' description='Why the record couldn\'t be sent; empty when a job was made.')
        global String error;
    }

    /**
     * Saves a job per record and starts sending them in the background.
     * @param requests from the flow, one per record
     * @return one result per request, in the same order
     * @throws SendException if the running user lacks the Replayr Sender permission set
     */
    @InvocableMethod(
        label='Send with Replayr'
        description='Sends each record to a Replayr endpoint, named by its key: saves a job per record, sent in the background with retries and a log. Use it on a Run Asynchronously path.'
        category='Replayr'
    )
    global static List<Result> send(List<Request> requests) {
        if (!FeatureManagement.checkPermission(JobCreation.PERMISSION)) {
            throw new SendException(JobCreation.NO_PERMISSION);
        }
        List<Result> results = new List<Result>();
        if (requests == null || requests.isEmpty()) {
            return results;
        }
        if (requests.size() > JobCreation.MAX_REQUESTS) {
            for (Integer i = 0; i < requests.size(); i++) {
                results.add(result(null, TOO_MANY));
            }
            return results;
        }
        Boolean anyJob = false;
        for (JobCreation.Result created : JobCreation.create(toCreationRequests(requests))) {
            results.add(result(created.jobId, created.error));
            anyJob = anyJob || created.jobId != null;
        }
        if (anyJob) {
            // Not checked: without the event the jobs wait for the poller's next run, and a Sender always has
            // Create on the event
            WorkWaiting.publish();
        }
        return results;
    }

    private static List<JobCreation.Request> toCreationRequests(List<Request> requests) {
        List<JobCreation.Request> converted = new List<JobCreation.Request>();
        for (Request request : requests) {
            converted.add(new JobCreation.Request(request?.endpointKey, request?.recordId));
        }
        return converted;
    }

    private static Result result(Id jobId, String error) {
        Result outcome = new Result();
        outcome.jobId = jobId;
        outcome.error = error;
        return outcome;
    }
}
