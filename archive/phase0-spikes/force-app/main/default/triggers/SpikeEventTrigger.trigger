trigger SpikeEventTrigger on Spike_Event__e (after insert) {
    SpikeRunAs.handleEvents(Trigger.new);
}
