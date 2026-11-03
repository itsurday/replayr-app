// P0.5(a): run as the user who will be deactivated; schedules a one-time probe 2 minutes out.
Id cronId = SpikeSchedProbe.scheduleInTwoMinutes('P0.5 scheduled by ' + UserInfo.getUserName());
System.debug('CronTrigger ' + cronId);
