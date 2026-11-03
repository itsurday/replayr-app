// P0.2b matrix: top-level Schedulable that logs through the SpikeLog helper.
public class SpikeSchedTopHelper implements Schedulable {
    public void execute(SchedulableContext ctx) {
        SpikeLog.write('P0.2b top-level + helper', 'ran');
    }
}
