// Run while link 1 is Processing: an outside start under the same signature
try {
    System.enqueueJob(new Spike4Hold(2), Spike4Hold.options());
    System.debug(LoggingLevel.ERROR, 'SPIKE4 outside enqueue while running ACCEPTED');
} catch (Exception e) {
    System.debug(LoggingLevel.ERROR, 'SPIKE4 outside enqueue while running refused: ' + e.getTypeName() + ': ' + e.getMessage());
}
