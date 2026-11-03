// Spike P4.1 (second round): does a RUNNING job block an outside enqueue under its signature?
// Link 1 stays running for HOLD_SECONDS, then starts link 2 under the same signature; meanwhile an outside
// enqueue with that signature is tried (spike script p41_outside.apex)
public with sharing class Spike4Hold implements Queueable {
    public static final String SIGNATURE = 'spike4-hold';
    private static final Integer HOLD_SECONDS = 20;
    private final Integer depth;

    public Spike4Hold(Integer depth) {
        this.depth = depth;
    }

    public static AsyncOptions options() {
        AsyncOptions options = new AsyncOptions();
        options.DuplicateSignature = QueueableDuplicateSignature.Builder().addString(SIGNATURE).build();
        return options;
    }

    public void execute(QueueableContext context) {
        if (depth >= 2) {
            return;
        }
        Long until = System.currentTimeMillis() + HOLD_SECONDS * 1000;
        while (System.currentTimeMillis() < until) {
            // Busy wait: keeps this job Processing while the outside enqueue is tried
            continue;
        }
        System.enqueueJob(new Spike4Hold(depth + 1), options());
    }
}
