// P0.3: what a Transaction Finalizer sees after the worker hits a limit exception.
public class SpikeFinalizer {
    public class CrashingWorker implements Queueable, Database.AllowsCallouts {
        public void execute(QueueableContext ctx) {
            Recorder recorder = new Recorder();
            System.attachFinalizer(recorder);
            recorder.progress = 'attached, callout starting';
            HttpRequest req = new HttpRequest();
            req.setEndpoint('https://httpbin.org/anything?p03=1');
            req.setMethod('POST');
            recorder.progress = 'callout returned HTTP ' + new Http().send(req).getStatusCode();
            insert SpikeLog.build('P0.3 worker DML', 'written after the callout, before the crash');
            recorder.progress += '; DML done';
            Integer spin = 0;
            while (true) {
                spin++; // forced CPU limit exception, which cannot be caught
            }
        }
    }

    public class Recorder implements Finalizer {
        public String progress = 'none';

        public void execute(FinalizerContext ctx) {
            Integer survived = [SELECT COUNT() FROM Spike_Log__c WHERE Label__c = 'P0.3 worker DML'];
            SpikeLog.write('P0.3 finalizer',
                'result=' + ctx.getResult()
                + '; exception=' + (ctx.getException() == null ? 'none' : ctx.getException().getTypeName() + ': ' + ctx.getException().getMessage())
                + '; progress seen=' + progress
                + '; worker DML rows surviving=' + survived);
        }
    }
}
