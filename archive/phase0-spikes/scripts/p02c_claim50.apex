// P0.2(c) follow-up: claim up to 50 Queued jobs with FOR UPDATE and hold the lock 6 s.
// Run two copies at the same time to see what the second claimer gets (80 jobs queued).
Integer claimLimit = 50;
String tag = 'L' + claimLimit + '-' + Math.abs(Crypto.getRandomInteger());
Long t0 = System.currentTimeMillis();
List<Spike_Job__c> rows = [SELECT Id, Status__c, Seq__c FROM Spike_Job__c WHERE Status__c = 'Queued' LIMIT :claimLimit FOR UPDATE];
Long waitMs = System.currentTimeMillis() - t0;
List<Spike_Job__c> claimed = new List<Spike_Job__c>();
Integer stale = 0;
for (Spike_Job__c r : rows) {
    if (r.Status__c == 'Queued') {
        claimed.add(new Spike_Job__c(Id = r.Id, Status__c = 'Processing', Claimed_By__c = tag));
    } else {
        stale++;
    }
}
update claimed;
Long holdUntil = System.currentTimeMillis() + 6000;
while (System.currentTimeMillis() < holdUntil) {}
SpikeLog.write('P0.2c claim ' + tag, 'started ' + t0 + '; lock wait ms=' + waitMs + '; returned=' + rows.size()
    + '; stale=' + stale + '; claimed=' + claimed.size());
