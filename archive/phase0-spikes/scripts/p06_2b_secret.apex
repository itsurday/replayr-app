// P0.6 step 2b: store the principal's (dummy) secret, after the principal has been granted (step 2).
try {
    System.debug('P06 ' + SpikeCredWizard.setSecret('Spike_Wizard_Cred', 'dummy-key-123'));
} catch (Exception e) {
    System.debug('P06 FAILED at stage [' + SpikeCredWizard.stage + ']: ' + e.getTypeName() + ': ' + e.getMessage());
}
