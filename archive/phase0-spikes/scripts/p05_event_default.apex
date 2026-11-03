// P0.5(b): event trigger with no subscriber config runs as Automated Process; its Queueable makes the credential callout.
Database.SaveResult pub = EventBus.publish(new Spike_Event__e(Run__c = 'p05-default'));
SpikeLog.write('P0.5 script event default', 'publish ok=' + pub.isSuccess());
