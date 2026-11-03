// P0.2b: schedule the 2x2 matrix (top-level/inner x plain insert/SpikeLog helper) for the same minute.
// Expected labels: 'P0.2b top-level + helper', 'P0.2b inner + plain', 'P0.4 scheduled control' (top+plain), 'P0.4 scheduled' (inner+helper).
Datetime n = Datetime.now().addMinutes(2);
String cron = '0 ' + n.minute() + ' ' + n.hour() + ' ' + n.day() + ' ' + n.month() + ' ? ' + n.year();
String suffix = ' ' + n.getTime();
System.schedule('P0.2b top+plain' + suffix, cron, new SpikeScheduledControl());
System.schedule('P0.2b top+helper' + suffix, cron, new SpikeSchedTopHelper());
System.schedule('P0.2b inner+plain' + suffix, cron, new SpikeSchedMatrix.InnerPlain());
System.schedule('P0.2b inner+helper' + suffix, cron, new SpikeRunAs.ScheduledProbe());
SpikeLog.write('P0.2b script', 'scheduled the matrix for ' + cron);
