// Spike P4.1: can a running Queueable enqueue its next link under its own duplicate signature?
// Two Spike4Chain jobs mean yes; one means the running link blocks its own successor
public with sharing class Spike4Chain implements Queueable {
    public static final String SIGNATURE = 'spike4-self';
    private final Integer depth;

    public Spike4Chain(Integer depth) {
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
        try {
            System.enqueueJob(new Spike4Chain(depth + 1), options());
        } catch (Exception e) {
            // Refused as a duplicate: visible as a single Spike4Chain job
            return;
        }
    }
}
