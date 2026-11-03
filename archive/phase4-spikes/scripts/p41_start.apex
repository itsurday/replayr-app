// Starts link 1, then (same transaction) tries a duplicate: logs the exception and the Queueable count
System.enqueueJob(new Spike4Hold(1), Spike4Hold.options());
Integer before = Limits.getQueueableJobs();
try {
    System.enqueueJob(new Spike4Hold(1), Spike4Hold.options());
    System.debug(LoggingLevel.ERROR, 'SPIKE4 same-transaction duplicate ACCEPTED');
} catch (Exception e) {
    System.debug(LoggingLevel.ERROR, 'SPIKE4 same-transaction duplicate refused: ' + e.getTypeName() + ': ' + e.getMessage());
}
System.debug(LoggingLevel.ERROR, 'SPIKE4 queueables before=' + before + ' after=' + Limits.getQueueableJobs() + ' limit=' + Limits.getLimitQueueableJobs());
