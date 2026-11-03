/**
 * Builds job log rows and keeps short text within its field limit, so a long error message can never
 * make the write fail (in a finalizer that would lose both the job update and the log).
 */
public with sharing class JobLogs {
    public static final Integer TEXT_LIMIT = 255;

    /**
     * Shortens text to fit a 255-character field.
     * @param text any text, or null
     * @return the text, abbreviated with "..." when longer than 255 characters
     */
    public static String shorten(String text) {
        return text?.abbreviate(TEXT_LIMIT);
    }

    /**
     * Builds, without inserting, the log row for one attempt at a job.
     * @param jobId the job
     * @param outcome a Job_Log__c.Outcome__c value
     * @param httpStatus the HTTP status code, or null if no response arrived
     * @param message a short summary; never a body or header
     * @param durationMs how long the callout took, or null if nothing was sent
     * @return the unsaved log row
     */
    public static Job_Log__c newLog(Id jobId, String outcome, Integer httpStatus, String message, Long durationMs) {
        return new Job_Log__c(
            Job__c = jobId,
            Outcome__c = outcome,
            HTTP_Status__c = httpStatus,
            Message__c = shorten(message),
            Duration_Ms__c = durationMs
        );
    }
}
