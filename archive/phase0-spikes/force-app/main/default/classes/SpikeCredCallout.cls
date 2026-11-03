// P0.5: one GET through the Named Credential; returns the status or the exact error text.
// Call before any DML in the transaction (P0.2 rule).
public class SpikeCredCallout {
    public static String call() {
        try {
            HttpRequest req = new HttpRequest();
            req.setEndpoint('callout:Spike_Httpbin/anything?p05=1');
            req.setMethod('GET');
            return 'HTTP ' + new Http().send(req).getStatusCode();
        } catch (Exception e) {
            return e.getTypeName() + ': ' + e.getMessage();
        }
    }
}
