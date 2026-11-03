/**
 * Errors the console's Apex returns to the browser: an AuraHandledException whose message is shown as is, so it
 * must be safe to show (no field values, payloads or secrets).
 */
public with sharing class ConsoleError {
    /**
     * @param message what the person sees
     * @return the exception to throw
     */
    public static AuraHandledException of(String message) {
        // AuraHandledException shows "Script-thrown exception" unless the message is set too
        AuraHandledException e = new AuraHandledException(message);
        e.setMessage(message);
        return e;
    }
}
