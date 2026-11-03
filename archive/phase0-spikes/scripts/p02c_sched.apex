// P0.2c: schedule the top-level fan-out probe with n=1 and n=2 for the same minute.
// Rows to expect: 'P0.2c sched n=1' + 'P0.2 fan-out' note 'P0.2c n=1 #1'; for n=2 either both '#1','#2' or nothing (rolled back).
Datetime n = Datetime.now().addMinutes(2);
String cron = '0 ' + n.minute() + ' ' + n.hour() + ' ' + n.day() + ' ' + n.month() + ' ? ' + n.year();
System.schedule('P0.2c n=1 ' + n.getTime(), cron, new SpikeSchedFanOut(1));
System.schedule('P0.2c n=2 ' + n.getTime(), cron, new SpikeSchedFanOut(2));
SpikeLog.write('P0.2c script', 'scheduled n=1 and n=2 for ' + cron);
