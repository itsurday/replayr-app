// Spike-only helper: records who ran what, for docs/decisions.md evidence.
// without sharing so evidence is written whatever the running user is; that user is what we test.
public without sharing class SpikeLog {
    public static Spike_Log__c build(String label, String note) {
        return new Spike_Log__c(
            Label__c = label,
            Run_As__c = UserInfo.getUserName() + ' (' + UserInfo.getUserId() + ')',
            Note__c = note + ' [ctx=' + Request.getCurrent().getQuiddity() + ']'
        );
    }

    public static void write(String label, String note) {
        insert build(label, note);
    }
}
