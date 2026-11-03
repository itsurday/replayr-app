// P0.2: dispatcher/worker callout pattern, claim locking, async fan-out limits.
public class SpikeJobEngine {
    // Claims Queued jobs with FOR UPDATE, re-checks status in code, optionally holds the lock.
    public class Dispatcher implements Queueable {
        private final String tag;
        private final Integer holdMillis;
        private final Boolean startWorker;

        public Dispatcher(String tag, Integer holdMillis, Boolean startWorker) {
            this.tag = tag;
            this.holdMillis = holdMillis;
            this.startWorker = startWorker;
        }

        public void execute(QueueableContext ctx) {
            Long started = System.currentTimeMillis();
            List<Spike_Job__c> rows = [
                SELECT Id, Status__c, Seq__c FROM Spike_Job__c
                WHERE Status__c = 'Queued' LIMIT 50 FOR UPDATE
            ];
            Long lockWaitMs = System.currentTimeMillis() - started;
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
            Long holdUntil = System.currentTimeMillis() + holdMillis;
            while (System.currentTimeMillis() < holdUntil) {
                // busy-wait keeps the row locks held so a second dispatcher overlaps
            }
            List<String> ids = new List<String>();
            for (Spike_Job__c c : claimed) {
                ids.add(c.Id);
            }
            SpikeLog.write('P0.2 dispatcher ' + tag,
                'lock wait ms=' + lockWaitMs + '; returned=' + rows.size() + '; stale=' + stale
                + '; claimed=' + claimed.size() + '; queueable limit here=' + Limits.getLimitQueueableJobs()
                + '\n' + String.join(ids, ','));
            if (startWorker && !claimed.isEmpty()) {
                System.enqueueJob(new Worker(claimed[0].Id));
            }
        }
    }

    // Calls out first, then writes the result in one DML.
    public class Worker implements Queueable, Database.AllowsCallouts {
        private final Id jobId;

        public Worker(Id jobId) {
            this.jobId = jobId;
        }

        public void execute(QueueableContext ctx) {
            HttpRequest req = new HttpRequest();
            req.setEndpoint('https://httpbin.org/anything?job=' + jobId);
            req.setMethod('GET');
            HttpResponse res = new Http().send(req);
            update new Spike_Job__c(Id = jobId, Status__c = 'Succeeded', Result__c = 'HTTP ' + res.getStatusCode());
            SpikeLog.write('P0.2 worker', 'job ' + jobId + ' HTTP ' + res.getStatusCode());
        }
    }

    // Negative control: callout after uncommitted DML in the same transaction.
    public class SameTransactionProbe implements Queueable, Database.AllowsCallouts {
        public void execute(QueueableContext ctx) {
            insert SpikeLog.build('P0.2 same-txn DML', 'pending before callout');
            String outcome;
            try {
                HttpRequest req = new HttpRequest();
                req.setEndpoint('https://httpbin.org/get');
                req.setMethod('GET');
                outcome = 'callout allowed: HTTP ' + new Http().send(req).getStatusCode();
            } catch (Exception e) {
                outcome = e.getTypeName() + ': ' + e.getMessage();
            }
            SpikeLog.write('P0.2 same-txn result', outcome);
        }
    }

    // Tries to enqueue two jobs from an async Queueable; AsyncApexJob shows the outcome.
    public class QueueableFanOutProbe implements Queueable {
        public void execute(QueueableContext ctx) {
            System.enqueueJob(new NoOp('from queueable #1'));
            System.enqueueJob(new NoOp('from queueable #2'));
        }
    }

    public class SchedulableFanOutProbe implements Schedulable {
        public void execute(SchedulableContext ctx) {
            System.enqueueJob(new NoOp('from schedulable #1'));
            System.enqueueJob(new NoOp('from schedulable #2'));
        }
    }

    // Enqueues a single job, so the transaction commits and the logged limit is visible.
    public class SchedulableLimitProbe implements Schedulable {
        public void execute(SchedulableContext ctx) {
            SpikeLog.write('P0.2 schedulable limit', 'queueable limit here=' + Limits.getLimitQueueableJobs());
            System.enqueueJob(new NoOp('from schedulable, single'));
        }
    }

    // Busy-waits so start/end times show whether several Queueables run at the same time.
    public class ParallelProbe implements Queueable {
        private final String label;

        public ParallelProbe(String label) {
            this.label = label;
        }

        public void execute(QueueableContext ctx) {
            Long started = System.currentTimeMillis();
            Long holdUntil = started + 5000;
            while (System.currentTimeMillis() < holdUntil) {
                // occupy this worker for 5 s
            }
            SpikeLog.write('P0.2 parallel ' + label, 'start=' + started + '; end=' + System.currentTimeMillis());
        }
    }

    public class NoOp implements Queueable {
        private final String label;

        public NoOp(String label) {
            this.label = label;
        }

        public void execute(QueueableContext ctx) {
            SpikeLog.write('P0.2 fan-out', label);
        }
    }
}
