// P0.1: delayed Queueable maximum delay and scheduled Apex minimum interval.
// Run: sf apex run --target-org spike-ee --file scripts/p01.apex   (from archive/phase0-spikes/)
List<String> out = new List<String>();
for (Integer d : new List<Integer>{ 0, 1, 10, 11 }) {
    try {
        System.enqueueJob(new SpikeTimingJobs.DelayedJob(d), d);
        out.add('delay ' + d + ': accepted');
    } catch (Exception e) {
        out.add('delay ' + d + ': ' + e.getTypeName() + ': ' + e.getMessage());
    }
}
for (String c : new List<String>{ '0 * * * * ?', '0 0/5 * * * ?', '0 0,30 * * * ?', '0 0 * * * ?' }) {
    try {
        Id j = System.schedule('P0.1 ' + c + ' ' + Datetime.now().getTime(), c, new SpikeTimingJobs.ScheduledProbe());
        out.add('cron "' + c + '": accepted');
        System.abortJob(j); // only acceptance is tested
    } catch (Exception e) {
        out.add('cron "' + c + '": ' + e.getTypeName() + ': ' + e.getMessage());
    }
}
SpikeLog.write('P0.1 sync results', String.join(out, '\n'));
