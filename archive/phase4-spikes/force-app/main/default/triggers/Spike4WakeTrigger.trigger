// Spike P4.1: (a) a duplicate signature lets only one Spike4Dup through; (b) Spike4Probe counts how many
// Queueables one event-trigger run may enqueue (enqueues until the limit, at most 60)
trigger Spike4WakeTrigger on Spike4_Wake__e(after insert) {
    for (Integer i = 0; i < 2; i++) {
        AsyncOptions options = new AsyncOptions();
        options.DuplicateSignature = QueueableDuplicateSignature.Builder().addString('spike4-chain').build();
        try {
            System.enqueueJob(new Spike4Dup(), options);
        } catch (Exception e) {
            // Expected for the second: the duplicate is refused
            continue;
        }
    }
    // (c) the first link of a self-chaining Queueable, under a signature
    System.enqueueJob(new Spike4Chain(1), Spike4Chain.options());
    Integer probes = 0;
    while (Limits.getQueueableJobs() < Limits.getLimitQueueableJobs() && probes < 60) {
        System.enqueueJob(new Spike4Probe());
        probes++;
    }
}
