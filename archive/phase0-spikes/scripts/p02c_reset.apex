// P0.2(c) follow-up: start from 80 Queued jobs.
// Run: sf apex run --target-org spike-ee --file scripts/p02c_reset.apex   (from archive/phase0-spikes/)
delete [SELECT Id FROM Spike_Job__c];
List<Spike_Job__c> jobs = new List<Spike_Job__c>();
for (Integer i = 1; i <= 80; i++) {
    jobs.add(new Spike_Job__c(Status__c = 'Queued', Seq__c = i));
}
insert jobs;
