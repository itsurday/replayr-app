// P0.4 run 1: start every entry point once as the script (admin) user, default settings.
// Run: sf apex run --target-org spike-ee --file scripts/p04_run.apex   (from archive/phase0-spikes/)
insert new Spike_Job__c(Status__c = 'P0.4', Seq__c = 0);           // record-triggered flow, async path
System.enqueueJob(new SpikeRunAs.ParentJob());                     // Queueable and its chained child
Database.SaveResult pub = EventBus.publish(new Spike_Event__e(Run__c = 'default')); // event trigger, default user
Datetime n = Datetime.now().addMinutes(2);
String cron = '0 ' + n.minute() + ' ' + n.hour() + ' ' + n.day() + ' ' + n.month() + ' ? ' + n.year();
System.schedule('P0.4 scheduled ' + n.getTime(), cron, new SpikeRunAs.ScheduledProbe());
System.schedule('P0.4 scheduled control ' + n.getTime(), cron, new SpikeScheduledControl());
SpikeLog.write('P0.4 script', 'started all entry points; event publish ok=' + pub.isSuccess()
    + (pub.isSuccess() ? '' : ' ' + pub.getErrors()));
