/**
 * The hourly safety net for the job engine: starts a chain when work is waiting,
 * which restarts chains that stopped and picks up retries due beyond a Queueable's 10-minute delay, then
 * records a heartbeat. Top-level, because an inner-class Schedulable never runs (P0.2b). It runs as the user
 * who scheduled it, so the integration user must schedule it (P0.4, P0.5).
 */
public with sharing class JobPoller implements Schedulable {
    public static final String JOB_NAME = 'Replayr poller';
    private static final Integer MINUTES_PER_HOUR = 60;
    private static final Integer PURGE_GAP_HOURS = 23;

    /**
     * Runs one poll.
     * @param context the schedulable context (unused)
     */
    public void execute(SchedulableContext context) {
        Boolean watchdogRan = runWatchdog();
        // One org-wide chain (decisions.md, ADR-004): started only if none is running, and it keeps claiming until no
        // work is left. Never throws; a failure leaves the work for the next hour
        JobWorker.startChainIfIdle();
        Boolean alertsRan = runAlerts(watchdogRan);
        Boolean purgeRan = startPurgeIfDue();
        // The heartbeat means the poller and each of its parts ran: without it, the health check reports it
        if (!watchdogRan || !alertsRan || !purgeRan) {
            return;
        }
        try {
            recordHeartbeat();
        } catch (DmlException e) {
            // Never undo the chain just started: a missing heartbeat is itself what the health check reports
            return;
        }
    }

    // Any failure (a lock timeout, missing access) undoes only the watchdog's own work, so the chain still
    // starts; it is reported by the missing heartbeat, not swallowed
    private static Boolean runWatchdog() {
        Savepoint beforeWatchdog = Database.setSavepoint();
        try {
            JobWatchdog.run();
            return true;
        } catch (Exception e) {
            Database.rollback(beforeWatchdog);
            return false;
        }
    }

    // Once a day: the first poll more than 23 hours after the last start, so a slow poll never skips a day. As
    // runWatchdog, a failure (such as a full batch queue) undoes only this, and shows as a missing heartbeat
    private static Boolean startPurgeIfDue() {
        Savepoint beforePurge = Database.setSavepoint();
        try {
            Replayr_Settings__c settings = Replayr_Settings__c.getOrgDefaults();
            Datetime now = System.now();
            if (settings.Last_Purge_Started__c != null && settings.Last_Purge_Started__c > now.addHours(-PURGE_GAP_HOURS)) {
                return true;
            }
            // Only its own field, so a retention saved meanwhile isn't undone (SettingsWriter)
            SettingsWriter.write(new Map<Schema.SObjectField, Object>{ Replayr_Settings__c.Last_Purge_Started__c => now });
            Database.executeBatch(new JobPurge(settings.Retention_Days__c), JobPurge.BATCH_SIZE);
            return true;
        } catch (Exception e) {
            Database.rollback(beforePurge);
            return false;
        }
    }

    // As runWatchdog: a failure undoes only the alert check, and shows as a missing heartbeat
    private static Boolean runAlerts(Boolean watchdogRan) {
        Savepoint beforeAlerts = Database.setSavepoint();
        try {
            JobAlerts.check(watchdogRan);
            return true;
        } catch (Exception e) {
            Database.rollback(beforeAlerts);
            return false;
        }
    }

    /**
     * Schedules the poller hourly at a random minute, so orgs don't all fire at :00. Safe to call again:
     * an existing poller is kept. Call it as the integration user.
     * @return true if it was scheduled now, false if a poller was already scheduled
     */
    public static Boolean schedule() {
        Integer minute = (Integer) Math.floor(Math.random() * MINUTES_PER_HOUR);
        try {
            System.schedule(JOB_NAME, '0 ' + minute + ' * * * ?', new JobPoller());
            return true;
        } catch (AsyncException e) {
            // CronTrigger can't be queried without View Setup and Configuration, which the integration user
            // doesn't get, so an existing poller is recognised by the platform's duplicate-name error, which
            // names the job. Any other scheduling error (such as the 100-job limit) reaches the caller
            if (e.getMessage().contains(JOB_NAME)) {
                return false;
            }
            throw e;
        }
    }

    // System mode on purpose, and explicit: the heartbeat is package bookkeeping in Replayr's own org-wide
    // setting, not user data. A user can never create or update a custom setting's fields (permission sets
    // can't grant it), and plain DML here is still checked against the user (docs/apex-notes.md). In system
    // mode the integration user needs no access to the setting at all (JobWorkerPermissionTest)
    private static void recordHeartbeat() {
        SettingsWriter.write(new Map<Schema.SObjectField, Object>{ Replayr_Settings__c.Poller_Last_Run__c => System.now() });
    }
}
