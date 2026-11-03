// P0.6: can Apex do what a credential setup wizard would do, through ConnectApi.NamedCredentials?
// Only dummy secrets. Methods return summaries that never contain a secret value.
public with sharing class SpikeCredWizard {
    private static final String PRINCIPAL_NAME = 'WizardPrincipal';
    private static final String KEY_PARAM = 'ApiKey';
    public static String stage = 'not started'; // last stage reached, for diagnosing ConnectApi failures

    // Step 1: External Credential (Custom protocol, key sent as X-Api-Key), Named Credential, principal secret.
    public static String create(String devName, String apiKey) {
        ConnectApi.ExternalCredentialPrincipalInput principal = new ConnectApi.ExternalCredentialPrincipalInput();
        principal.principalName = PRINCIPAL_NAME;
        principal.principalType = ConnectApi.CredentialPrincipalType.NamedPrincipal;
        principal.sequenceNumber = 1;

        ConnectApi.CredentialCustomHeaderInput header = new ConnectApi.CredentialCustomHeaderInput();
        header.headerName = 'X-Api-Key';
        header.headerValue = '{!$Credential.' + devName + '.' + KEY_PARAM + '}';
        header.sequenceNumber = 1;

        ConnectApi.ExternalCredentialInput ec = new ConnectApi.ExternalCredentialInput();
        ec.developerName = devName;
        ec.masterLabel = devName;
        ec.authenticationProtocol = ConnectApi.CredentialAuthenticationProtocol.Custom;
        ec.principals = new List<ConnectApi.ExternalCredentialPrincipalInput>{ principal };
        ec.customHeaders = new List<ConnectApi.CredentialCustomHeaderInput>{ header };
        stage = 'creating external credential';
        ConnectApi.ExternalCredential createdEc = ConnectApi.NamedCredentials.createExternalCredential(ec);
        stage = 'external credential created; creating named credential';

        ConnectApi.ExternalCredentialInput ecRef = new ConnectApi.ExternalCredentialInput();
        ecRef.developerName = devName;
        ConnectApi.NamedCredentialInput nc = new ConnectApi.NamedCredentialInput();
        nc.developerName = devName + '_NC';
        nc.masterLabel = devName + '_NC';
        nc.type = ConnectApi.NamedCredentialType.SecuredEndpoint;
        nc.calloutUrl = 'https://httpbin.org';
        nc.externalCredentials = new List<ConnectApi.ExternalCredentialInput>{ ecRef };
        ConnectApi.NamedCredentialCalloutOptionsInput options = new ConnectApi.NamedCredentialCalloutOptionsInput();
        options.allowMergeFieldsInBody = false;
        options.allowMergeFieldsInHeader = false;
        options.generateAuthorizationHeader = false;
        nc.calloutOptions = options; // required by ConnectApi (P0.6 finding)
        ConnectApi.NamedCredential createdNc = ConnectApi.NamedCredentials.createNamedCredential(nc);
        stage = 'named credential created';
        return 'created externalCredential=' + createdEc.developerName + ' namedCredential=' + createdNc.developerName;
    }

    // Step 2b: store the principal's secret (split from create: it failed there with an opaque error).
    public static String setSecret(String devName, String apiKey) {
        ConnectApi.CredentialValueInput value = new ConnectApi.CredentialValueInput();
        value.value = apiKey;
        value.encrypted = true;
        ConnectApi.CredentialInput cred = new ConnectApi.CredentialInput();
        cred.externalCredential = devName;
        cred.principalName = PRINCIPAL_NAME;
        cred.principalType = ConnectApi.CredentialPrincipalType.NamedPrincipal;
        cred.authenticationProtocol = ConnectApi.CredentialAuthenticationProtocol.Custom;
        cred.credentials = new Map<String, ConnectApi.CredentialValueInput>{ KEY_PARAM => value };
        stage = 'setting principal credential';
        ConnectApi.Credential createdCred = ConnectApi.NamedCredentials.createCredential(cred);
        stage = 'principal credential set';
        return 'secret stored; credential status=' + createdCred.authenticationStatus;
    }

    // Step 2: give a permission set principal access to the new principal, from code.
    public static String grant(String devName, String permSetName) {
        // ExternalCredentialParameter is not queryable from Apex, so take the principal Id from ConnectApi.
        Id principalId;
        for (ConnectApi.ExternalCredentialPrincipal p : ConnectApi.NamedCredentials.getExternalCredential(devName).principals) {
            if (p.principalName == PRINCIPAL_NAME) {
                principalId = p.id;
            }
        }
        PermissionSet ps = [SELECT Id FROM PermissionSet WHERE Name = :permSetName LIMIT 1];
        insert new SetupEntityAccess(ParentId = ps.Id, SetupEntityId = principalId);
        return 'granted principal ' + principalId + ' to ' + permSetName;
    }

    // Step 3: does the secret arrive as a header? Reports booleans only.
    // Note: ConnectApi has no calloutStatus at API 68.0, so a Named Credential it creates stays
    // "Enabled for Callouts" = off until an admin switches it on in Setup (P0.6 finding).
    public static String callout(String namedCredential, String expectedKey) {
        HttpRequest req = new HttpRequest();
        req.setEndpoint('callout:' + namedCredential + '/headers');
        req.setMethod('GET');
        HttpResponse res = new Http().send(req);
        Map<String, Object> body = (Map<String, Object>) JSON.deserializeUntyped(res.getBody());
        Map<String, Object> headers = (Map<String, Object>) body.get('headers');
        Object sent = headers == null ? null : headers.get('X-Api-Key');
        return 'HTTP ' + res.getStatusCode() + '; X-Api-Key present=' + (sent != null)
            + '; matches expected=' + (sent != null && String.valueOf(sent) == expectedKey)
            + '; unresolved merge field=' + (sent != null && String.valueOf(sent).startsWith('{!'));
    }

    // Step 4: what does Apex get back for the stored secret? Never returns the value itself.
    public static String readBack(String devName, String original) {
        ConnectApi.Credential c = ConnectApi.NamedCredentials.getCredential(
            devName, PRINCIPAL_NAME, ConnectApi.CredentialPrincipalType.NamedPrincipal);
        ConnectApi.CredentialValue v = c.credentials == null ? null : c.credentials.get(KEY_PARAM);
        String kind;
        if (v == null || v.value == null) {
            kind = 'no value returned';
        } else if (v.value == original) {
            kind = 'PLAINTEXT returned';
        } else {
            kind = 'masked (length ' + v.value.length() + ')';
        }
        return 'readBack ' + KEY_PARAM + ': ' + kind + '; encrypted flag=' + (v == null ? null : v.encrypted);
    }
}
