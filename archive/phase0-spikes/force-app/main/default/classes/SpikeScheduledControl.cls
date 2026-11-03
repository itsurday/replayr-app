// P0.4 / P0.2b control: a top-level Schedulable with a plain insert, to compare with the inner-class probes.
public class SpikeScheduledControl implements Schedulable {
    public void execute(SchedulableContext ctx) {
        insert new Spike_Log__c(
            Label__c = 'P0.4 scheduled control',
            Run_As__c = UserInfo.getUserName() + ' (' + UserInfo.getUserId() + ')',
            Note__c = 'top-level class, plain insert'
        );
    }
}
