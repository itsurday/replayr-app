// P0.6 step 2c: switch on "Allow Formulas in HTTP Header" for the wizard's Named Credential via ConnectApi.
ConnectApi.NamedCredentialCalloutOptionsInput options = new ConnectApi.NamedCredentialCalloutOptionsInput();
options.allowMergeFieldsInBody = false;
options.allowMergeFieldsInHeader = true;
options.generateAuthorizationHeader = false;
ConnectApi.ExternalCredentialInput ecRef = new ConnectApi.ExternalCredentialInput();
ecRef.developerName = 'Spike_Wizard_Cred';
ConnectApi.NamedCredentialInput nc = new ConnectApi.NamedCredentialInput();
nc.developerName = 'Spike_Wizard_Cred_NC';
nc.masterLabel = 'Spike_Wizard_Cred_NC';
nc.type = ConnectApi.NamedCredentialType.SecuredEndpoint;
nc.calloutUrl = 'https://httpbin.org';
nc.externalCredentials = new List<ConnectApi.ExternalCredentialInput>{ ecRef };
nc.calloutOptions = options; // an update needs the full definition, not just the changed field
try {
    ConnectApi.NamedCredential updated = ConnectApi.NamedCredentials.updateNamedCredential('Spike_Wizard_Cred_NC', nc);
    System.debug('P06 updated; allowMergeFieldsInHeader=' + updated.calloutOptions.allowMergeFieldsInHeader);
} catch (Exception e) {
    System.debug('P06 FAILED update: ' + e.getTypeName() + ': ' + e.getMessage());
}
