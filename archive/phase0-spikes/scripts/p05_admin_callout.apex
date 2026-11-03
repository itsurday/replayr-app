// P0.5(b): callout through the Named Credential as the running user; run before and after granting Spike_Callout.
String result = SpikeCredCallout.call(); // before any DML
SpikeLog.write('P0.5 callout as script user', result);
