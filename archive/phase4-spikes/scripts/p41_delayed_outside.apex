// Separate transaction, while the delayed job is still Queued
AsyncOptions options = new AsyncOptions();
options.DuplicateSignature = QueueableDuplicateSignature.Builder().addString('spike4-delayed').build();
try {
    System.enqueueJob(new Spike4Probe(), options);
    System.debug(LoggingLevel.ERROR, 'SPIKE4 outside enqueue while queued ACCEPTED');
} catch (Exception e) {
    System.debug(LoggingLevel.ERROR, 'SPIKE4 outside enqueue while queued refused: ' + e.getTypeName() + ': ' + e.getMessage());
}
