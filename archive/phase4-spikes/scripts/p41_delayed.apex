// A job certainly Queued (delayed one minute) under signature spike4-delayed
AsyncOptions options = new AsyncOptions();
options.DuplicateSignature = QueueableDuplicateSignature.Builder().addString('spike4-delayed').build();
options.MinimumQueueableDelayInMinutes = 1;
System.enqueueJob(new Spike4Probe(), options);
System.debug(LoggingLevel.ERROR, 'SPIKE4 delayed job queued');
