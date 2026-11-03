// P0.2b matrix: inner-class Schedulable that does a plain insert (no SpikeLog helper).
public class SpikeSchedMatrix {
    public class InnerPlain implements Schedulable {
        public void execute(SchedulableContext ctx) {
            insert new Spike_Log__c(
                Label__c = 'P0.2b inner + plain',
                Run_As__c = UserInfo.getUserName() + ' (' + UserInfo.getUserId() + ')',
                Note__c = 'ran'
            );
        }
    }
}
