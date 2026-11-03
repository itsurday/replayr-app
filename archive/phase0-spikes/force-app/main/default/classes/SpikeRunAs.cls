// P0.4: which user each background entry point runs as. Every probe logs UserInfo via SpikeLog.
public class SpikeRunAs {
    public class Request {
        @InvocableVariable(required=true)
        public Id recordId;
    }

    // Called from the async path of the record-triggered flow Spike_Run_As_Async.
    @InvocableMethod(label='Spike: log run-as user')
    public static void logFromFlow(List<Request> requests) {
        SpikeLog.write('P0.4 flow async path', 'records=' + requests.size());
    }

    public class ParentJob implements Queueable {
        public void execute(QueueableContext ctx) {
            SpikeLog.write('P0.4 queueable parent', 'enqueued by the script user');
            System.enqueueJob(new ChildJob());
        }
    }

    public class ChildJob implements Queueable {
        public void execute(QueueableContext ctx) {
            SpikeLog.write('P0.4 queueable child', 'enqueued by ParentJob');
        }
    }

    // Called by SpikeEventTrigger; also starts a Queueable to see whether it inherits the trigger's user.
    public static void handleEvents(List<Spike_Event__e> events) {
        String run = events[0].Run__c;
        SpikeLog.write('P0.4 event trigger ' + run, 'events=' + events.size());
        if (run != null && run.contains('schedule')) {
            // P0.5(c): the trigger's run-as user becomes the owner of this scheduled job.
            SpikeSchedProbe.scheduleInTwoMinutes('P0.5 scheduled by trigger user ' + run);
        }
        System.enqueueJob(new EventJob(run));
    }

    public class EventJob implements Queueable, Database.AllowsCallouts {
        private final String run;

        public EventJob(String run) {
            this.run = run;
        }

        public void execute(QueueableContext ctx) {
            String callout = SpikeCredCallout.call(); // before any DML
            SpikeLog.write('P0.4 event queueable ' + run, 'enqueued by the event trigger; credential callout: ' + callout);
        }
    }

    public class ScheduledProbe implements Schedulable {
        public void execute(SchedulableContext ctx) {
            SpikeLog.write('P0.4 scheduled', 'scheduled by the script user');
        }
    }
}
