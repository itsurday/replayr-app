// P0.6 step 3: call httpbin /headers through the new Named Credential; reports booleans only.
System.debug('P06 ' + SpikeCredWizard.callout('Spike_Wizard_Cred_NC', 'dummy-key-123'));
