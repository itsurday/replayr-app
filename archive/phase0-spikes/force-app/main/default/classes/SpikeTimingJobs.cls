// P0.1: delayed Queueable and scheduled Apex timing probes.
public class SpikeTimingJobs {
    public class DelayedJob implements Queueable {
        private final Datetime enqueuedAt;
        private final Integer requestedDelay;

        public DelayedJob(Integer requestedDelay) {
            this.enqueuedAt = Datetime.now();
            this.requestedDelay = requestedDelay;
        }

        public void execute(QueueableContext ctx) {
            Long seconds = (Datetime.now().getTime() - enqueuedAt.getTime()) / 1000;
            SpikeLog.write('P0.1 delayed queueable',
                'requested ' + requestedDelay + ' min; actual ' + seconds + ' s');
        }
    }

    public class ScheduledProbe implements Schedulable {
        public void execute(SchedulableContext ctx) {
            SpikeLog.write('P0.1 scheduled probe', 'fired at ' + Datetime.now());
        }
    }
}
