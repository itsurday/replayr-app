// Publishes one Spike4_Wake__e; the trigger's jobs are then counted in AsyncApexJob
Database.SaveResult r = EventBus.publish(new Spike4_Wake__e());
System.debug(LoggingLevel.ERROR, 'SPIKE4 published=' + r.isSuccess());
