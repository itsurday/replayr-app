// P0.5: top-level scheduled probe (P0.2b: Schedulables must be top-level); logs its label and who ran it.
public class SpikeSchedProbe implements Schedulable {
    private final String label;

    public SpikeSchedProbe(String label) {
        this.label = label;
    }

    public void execute(SchedulableContext ctx) {
        SpikeLog.write(label, 'scheduled probe ran');
    }

    // Schedules a one-time run 5 minutes from now (time to deactivate the owner first) and returns the CronTrigger Id.
    public static Id scheduleInTwoMinutes(String label) {
        Datetime n = Datetime.now().addMinutes(5);
        String cron = '0 ' + n.minute() + ' ' + n.hour() + ' ' + n.day() + ' ' + n.month() + ' ? ' + n.year();
        return System.schedule(label + ' ' + n.getTime(), cron, new SpikeSchedProbe(label));
    }
}
