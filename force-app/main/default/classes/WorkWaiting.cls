/**
 * The platform-event hand-off (docs/decisions.md, ADR-003): code that saves or re-queues jobs calls
 * publish(); the trigger on Replayr_Work_Waiting__e calls handle(). The trigger runs as the user an admin sets
 * in a PlatformEventSubscriberConfig (docs/admin-guide.md), which must be Replayr's integration user: it holds
 * the credential access, so its chains can call out, and it also schedules the hourly poller. Until that is set
 * up the trigger runs as Automated Process and starts nothing, and nothing else schedules the poller either, so
 * jobs wait until the setup is done rather than fail for lack of credentials.
 */
public with sharing class WorkWaiting {
    public static final String INTEGRATION_SET = 'Replayr_Integration_User';
    // The run time is refreshed at most this often, so a burst of events doesn't keep the settings row locked
    // against the poller's heartbeat
    private static final Integer RECORD_EVERY_MINUTES = 5;
    // One event per transaction is enough: it carries no data. Set only on success, so a later call retries a
    // failed publish. If the transaction then rolls back, Publish After Commit discards the event and this stays
    // true, so a later call in the same transaction publishes nothing; the work waits for the next run
    @TestVisible
    private static Boolean published = false;

    /**
     * Says work is waiting, once the transaction commits. Never throws: if the event can't be published (the
     * user lacks Create on it), the work waits for the poller's next run.
     * @return false when the event couldn't be published
     */
    public static Boolean publish() {
        if (published) {
            return true;
        }
        Database.SaveResult result = EventBus.publish(new Replayr_Work_Waiting__e());
        published = result.isSuccess();
        return published;
    }

    /**
     * The trigger's work, once per batch of events: records the user it runs as, then, if that is Replayr's
     * integration user, starts the job chain (if none is running) and schedules the poller (if not scheduled).
     * Never throws: an uncaught error would only drop the batch, and the next event or poll tries again.
     */
    public static void handle() {
        recordRunAs();
        if (!isIntegrationUser(UserInfo.getUserId())) {
            // Automated Process (not set up yet), or a user without Replayr's Integration User set (an admin or a
            // person): start nothing, so no call runs without credential access or with wider access than Replayr's
            return;
        }
        JobWorker.startChainIfIdle();
        try {
            JobPoller.schedule();
        } catch (Exception e) {
            // A scheduling error other than "already scheduled" (such as the org's 100 scheduled jobs): the chain
            // started anyway, and a poller that never runs shows as a missing heartbeat on the health panel
            return;
        }
    }

    /**
     * Whether a user may run Replayr's background work and own its jobs: active, not Automated Process, and
     * holding the Replayr Integration User set (directly or through a group).
     * @param userId the user
     * @return true for Replayr's integration user
     */
    public static Boolean isIntegrationUser(Id userId) {
        // PermissionSetHolders leaves out inactive users and Automated Process
        return userId != null && PermissionSetHolders.of(INTEGRATION_SET, new Set<Id>{ userId }).contains(userId);
    }

    // System mode on purpose: package bookkeeping in the protected setting, as JobPoller's heartbeat. Written only
    // when the user changed or the last record is older than RECORD_EVERY_MINUTES
    private static void recordRunAs() {
        Replayr_Settings__c settings = Replayr_Settings__c.getOrgDefaults();
        String userId = UserInfo.getUserId();
        Datetime now = System.now();
        Boolean fresh = settings.Hand_Off_Last_Run__c != null && settings.Hand_Off_Last_Run__c > now.addMinutes(-RECORD_EVERY_MINUTES);
        if (settings.Hand_Off_User__c == userId && fresh) {
            return;
        }
        try {
            SettingsWriter.write(new Map<Schema.SObjectField, Object>{ Replayr_Settings__c.Hand_Off_User__c => userId, Replayr_Settings__c.Hand_Off_Last_Run__c => now });
        } catch (Exception e) {
            // A lock on the settings row: only the health panel's view is late; the hand-off goes on
            return;
        }
    }
}
