/**
 * Builds and sends the HTTP request for an endpoint through its provider's Named Credential.
 * The platform adds authentication, so this class never sees or stores a secret.
 */
public with sharing class CalloutService {
    private static final Set<String> METHODS = new Set<String>{ 'GET', 'POST', 'PUT', 'PATCH', 'DELETE' };
    private static final Pattern CREDENTIAL_NAME = Pattern.compile('[A-Za-z][A-Za-z0-9_]*');
    // RFC 3986 path and query characters, minus '@' and '#'; '%' only as a %XX escape; one leading '/'.
    // shortcut: the repeated group is fine for Path__c's 255 characters; rewrite it if the field ever becomes Long Text
    // (Apex throws an uncatchable "Regex too complicated" on very long input)
    private static final Pattern SAFE_PATH = Pattern.compile(
        '/(?!/)([A-Za-z0-9\\-._~!$&\'()*+,;=:/?]|%[0-9A-Fa-f]{2})*'
    );
    private static final Pattern CONTROL_CHARACTER = Pattern.compile('\\p{Cntrl}');
    // Checked again here, not only by the Endpoint validation rule: a header name with a line break could
    // add headers of its own. Same token characters and reserved names as the rule
    private static final Pattern HEADER_NAME = Pattern.compile('[A-Za-z0-9!#$%&\'*+.^_`|~-]{1,80}');
    private static final Set<String> RESERVED_HEADERS = new Set<String>{
        'authorization', 'connection', 'content-length', 'content-type', 'cookie', 'expect', 'host', 'transfer-encoding', 'upgrade'
    };
    private static final Pattern IDEMPOTENCY_KEY = Pattern.compile('[A-Za-z0-9-]{1,36}');

    /** Thrown before anything is sent. Messages never echo the path, which may hold a query-string key. */
    public class InvalidEndpointException extends Exception {
    }

    /**
     * Builds the request without sending it.
     * @param endpoint loaded with Method__c, Path__c and Provider__r.Named_Credential__c; a missing
     *        field throws SObjectException, also before anything is sent
     * @param body request body, or null for none
     * @return the request for callout:NamedCredential plus the endpoint's path
     * @throws InvalidEndpointException if the credential name, method or path is unsafe
     */
    public static HttpRequest buildRequest(Endpoint__c endpoint, String body) {
        return buildRequest(endpoint, body, null);
    }

    /**
     * Builds the request without sending it, with the job's idempotency key when the endpoint names a header.
     * @param endpoint as above, plus Idempotency_Header__c; a blank header sends no key
     * @param body request body, or null for none
     * @param idempotencyKey the job's key, the same on every attempt
     * @return the request
     * @throws InvalidEndpointException as above, or if the header name or key is unsafe or the key is missing
     */
    public static HttpRequest buildRequest(Endpoint__c endpoint, String body, String idempotencyKey) {
        HttpRequest request = new HttpRequest();
        request.setEndpoint('callout:' + validCredential(endpoint) + validPath(endpoint.Path__c));
        request.setMethod(validMethod(endpoint.Method__c));
        String header = endpoint.Idempotency_Header__c;
        if (String.isNotBlank(header)) {
            request.setHeader(validHeaderName(header), validKey(idempotencyKey));
        }
        if (String.isNotEmpty(body)) {
            // Request bodies are built from JSON templates (MergeTemplate)
            request.setHeader('Content-Type', 'application/json');
            request.setBody(body);
        }
        return request;
    }

    /**
     * Builds and sends the request.
     * @param endpoint as for buildRequest
     * @param body request body, or null for none
     * @return the response
     * @throws InvalidEndpointException before sending, as for buildRequest
     * @throws CalloutException from the platform, for example a missing Named Credential or a
     *         timeout; after a timeout the call may have reached the remote system
     */
    public static HttpResponse send(Endpoint__c endpoint, String body) {
        return send(endpoint, body, null);
    }

    /**
     * Builds and sends the request with the job's idempotency key, as buildRequest does.
     * @param endpoint as for buildRequest
     * @param body request body, or null for none
     * @param idempotencyKey the job's key
     * @return the response
     * @throws InvalidEndpointException before sending, as for buildRequest
     * @throws CalloutException from the platform, as above
     */
    public static HttpResponse send(Endpoint__c endpoint, String body, String idempotencyKey) {
        return new Http().send(buildRequest(endpoint, body, idempotencyKey));
    }

    private static String validHeaderName(String name) {
        if (!HEADER_NAME.matcher(name).matches() || RESERVED_HEADERS.contains(name.toLowerCase('en_US'))) {
            throw new InvalidEndpointException(
                'The endpoint\'s idempotency header must be a plain header name, such as Idempotency-Key, and not one the platform sets.'
            );
        }
        return name;
    }

    // Never sent without its key: a retry with a new or no key would defeat the API's duplicate check
    private static String validKey(String key) {
        if (key == null || !IDEMPOTENCY_KEY.matcher(key).matches()) {
            throw new InvalidEndpointException('The job has no valid idempotency key, so it was not sent.');
        }
        return key;
    }

    private static String validCredential(Endpoint__c endpoint) {
        String name = endpoint.Provider__r?.Named_Credential__c;
        if (name == null || !CREDENTIAL_NAME.matcher(name).matches()) {
            throw new InvalidEndpointException(
                'The provider\'s Named Credential name must start with a letter and use only letters, digits and underscores.'
            );
        }
        return name;
    }

    private static String validMethod(String method) {
        if (!METHODS.contains(method)) {
            throw new InvalidEndpointException('The endpoint method must be GET, POST, PUT, PATCH or DELETE.');
        }
        return method;
    }

    private static String validPath(String path) {
        if (String.isEmpty(path)) {
            return '';
        }
        // A decoded '%' means double encoding, which could hide '..' from this check
        Boolean safe = SAFE_PATH.matcher(path).matches();
        if (safe) {
            // Cannot throw: SAFE_PATH allows only well-formed %XX, and invalid UTF-8 decodes to U+FFFD (tested)
            String decoded = EncodingUtil.urlDecode(path, 'UTF-8');
            safe = !(decoded.contains('..') ||
                decoded.contains('@') ||
                decoded.contains('\\') ||
                decoded.contains('%') ||
                CONTROL_CHARACTER.matcher(decoded).find());
        }
        if (!safe) {
            throw new InvalidEndpointException(
                'The endpoint path must start with a single / and use only URL characters, with no .., @, \\, # or double encoding.'
            );
        }
        return path;
    }
}
