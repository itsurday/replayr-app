// P0.2c: how many Queueables can a (top-level) scheduled job enqueue?
// Logs the limit it sees, then enqueues `count` jobs. If count exceeds the limit, the whole run rolls back.
public class SpikeSchedFanOut implements Schedulable {
    private final Integer count;

    public SpikeSchedFanOut(Integer count) {
        this.count = count;
    }

    public void execute(SchedulableContext ctx) {
        SpikeLog.write('P0.2c sched n=' + count, 'queueable limit here=' + Limits.getLimitQueueableJobs());
        for (Integer i = 1; i <= count; i++) {
            System.enqueueJob(new SpikeJobEngine.NoOp('P0.2c n=' + count + ' #' + i));
        }
    }
}
