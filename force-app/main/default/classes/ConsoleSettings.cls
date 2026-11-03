/**
 * The console's Settings and setup section: how long finished jobs are kept, and setting
 * Replayr's background work off once (decisions.md, ADR-025). For Replayr Admins, judged as in test mode by
 * those who may edit endpoints.
 */
public with sharing class ConsoleSettings {
    public static final Integer MIN_RETENTION_DAYS = 1;
    public static final Integer MAX_RETENTION_DAYS = 3650;

    /** What the section shows. */
    public class Settings {
        /** The days finished jobs are kept, as the purge uses them (blank or below 1 counts as the default). */
        @AuraEnabled
        public Integer retentionDays;
        @AuraEnabled
        public Integer minRetentionDays = MIN_RETENTION_DAYS;
        @AuraEnabled
        public Integer maxRetentionDays = MAX_RETENTION_DAYS;
    }

    /**
     * Reads the settings.
     * @return the settings
     */
    @AuraEnabled
    public static Settings read() {
        requireAdmin();
        Settings settings = new Settings();
        Decimal stored = Replayr_Settings__c.getOrgDefaults().Retention_Days__c;
        settings.retentionDays = stored == null || stored < 1 ? JobPurge.DEFAULT_RETENTION_DAYS : stored.intValue();
        return settings;
    }

    /**
     * Saves how long finished jobs are kept.
     * @param days from MIN_RETENTION_DAYS to MAX_RETENTION_DAYS
     * @return the settings as saved
     */
    @AuraEnabled
    public static Settings saveRetention(Integer days) {
        requireAdmin();
        if (days == null || days < MIN_RETENTION_DAYS || days > MAX_RETENTION_DAYS) {
            throw ConsoleError.of('Keep finished jobs for ' + MIN_RETENTION_DAYS + ' to ' + MAX_RETENTION_DAYS + ' days.');
        }
        try {
            // The setting is protected, so only package code may write it, and that only after the admin check above
            SettingsWriter.write(new Map<Schema.SObjectField, Object>{ Replayr_Settings__c.Retention_Days__c => days });
        } catch (DmlException e) {
            throw ConsoleError.of('Replayr couldn\'t save the setting just now (another of its tasks was writing it). Try again.');
        }
        return read();
    }

    /**
     * Sets Replayr's background work off once: publishes the work-waiting event, whose trigger (running as the
     * integration user once the run-as setup is done) starts the job chain and schedules the hourly poller. Safe
     * at any time: as anyone else the trigger starts nothing, and the poller is scheduled only once.
     * @return true when the event was published
     */
    @AuraEnabled
    public static Boolean startBackgroundWork() {
        requireAdmin();
        return WorkWaiting.publish();
    }

    private static void requireAdmin() {
        if (!FeatureManagement.checkPermission(JobActions.PERMISSION) || !Schema.SObjectType.Endpoint__c.isUpdateable()) {
            throw ConsoleError.of('Settings need the Replayr Admin permission set (or another that may edit endpoints).');
        }
    }
}
