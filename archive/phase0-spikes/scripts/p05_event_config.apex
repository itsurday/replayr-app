// P0.5(b)+(c): event trigger running as the configured Integration-licence user; it schedules a probe and its Queueable calls out.
Database.SaveResult pub = EventBus.publish(new Spike_Event__e(Run__c = 'p05-config-schedule'));
SpikeLog.write('P0.5 script event config', 'publish ok=' + pub.isSuccess());
