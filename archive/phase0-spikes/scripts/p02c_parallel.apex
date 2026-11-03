// P0.2(c) follow-up: do several Queueables started together actually run at the same time?
// Each busy-waits 5 s and logs start/end in ms; overlapping intervals mean parallel execution.
String run = String.valueOf(System.currentTimeMillis());
for (Integer i = 1; i <= 3; i++) {
    System.enqueueJob(new SpikeJobEngine.ParallelProbe(run + '#' + i));
}
