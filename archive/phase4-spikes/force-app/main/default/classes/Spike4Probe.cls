// Spike P4.1: does nothing; counted through AsyncApexJob to see how many the event trigger could enqueue
public with sharing class Spike4Probe implements Queueable {
    public void execute(QueueableContext context) {
        return;
    }
}
