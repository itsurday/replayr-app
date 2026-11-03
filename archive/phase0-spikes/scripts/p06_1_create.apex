// P0.6 step 1: create External Credential, Named Credential and the principal's (dummy) secret through ConnectApi.
// Catches the error so the CLI prints the log; reports the last stage reached.
try {
    System.debug('P06 ' + SpikeCredWizard.create('Spike_Wizard_Cred', 'dummy-key-123'));
} catch (Exception e) {
    System.debug('P06 FAILED at stage [' + SpikeCredWizard.stage + ']: ' + e.getTypeName() + ': ' + e.getMessage());
}
