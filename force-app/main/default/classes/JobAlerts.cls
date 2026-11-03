/**
 * The hourly grouped alert: one Salesforce notification to Replayr Admins when
 * jobs need attention. New since the last check: Outcome unknown, Retries used up, Response not saved. Every
 * hour while it lasts: work not moving (the oldest queued job or due retry has waited over two hours) and a
 * failed watchdog. Test runs are left out; nothing is sent when nothing needs attention. Run by JobPoller.
 */
public with sharing class JobAlerts {
    public static final String NOTIFICATION_TYPE = 'Replayr_Alert';
    public static final String ADMIN_SET = 'Replayr_Admin';
    public static final Integer NOT_MOVING_HOURS = 2;
    private static final String NOT_SAVED = 'Response not saved';
    private static final Integer BODY_LIMIT = 750;
    private static final Integer MAX_RECIPIENTS = 500;
    private static final Integer COMMIT_LAG_MINUTES = 5;

    // How many notifications this transaction sent; lets tests see a send, which leaves no record
    @TestVisible
    private static Integer sent = 0;
    // Test clock: a test can't age a record's timestamps, so it moves "now" instead
    @TestVisible
    private static Datetime nowForTest;

    /** Thrown when an alert is due but can't be delivered, so the poll reports a failure instead of losing it. */
    public class AlertException extends Exception {
    }

    /** What needs attention in one check. */
    public class Summary {
        public Integer outcomeUnknown = 0;
        public Integer dead = 0;
        public Integer notSaved = 0;
        public Boolean notMoving = false;
        public Boolean watchdogFailed = false;

        /** @return true if anything needs attention */
        public Boolean isEmpty() {
            return outcomeUnknown + dead + notSaved == 0 && !notMoving && !watchdogFailed;
        }

        /** @return the notification text, for example "2 Outcome unknown, 1 Retries used up." */
        public String text() {
            List<String> parts = new List<String>();
            addCount(parts, outcomeUnknown, 'Outcome unknown');
            addCount(parts, dead, 'Retries used up');
            addCount(parts, notSaved, 'Response not saved');
            if (notMoving) {
                parts.add('work has not moved for over ' + NOT_MOVING_HOURS + ' hours');
            }
            if (watchdogFailed) {
                parts.add('the watchdog failed');
            }
            return String.join(parts, ', ') + '.';
        }
    }

    private static void addCount(List<String> parts, Integer count, String label) {
        if (count > 0) {
            parts.add(count + ' ' + label);
        }
    }

    /**
     * Checks for jobs needing attention since the last check, notifies Replayr Admins if any do, and moves the
     * check time forward.
     * @param watchdogRan false if this poll's watchdog failed
     * @return what was found
     */
    public static Summary check(Boolean watchdogRan) {
        Replayr_Settings__c settings = Replayr_Settings__c.getOrgDefaults();
        Datetime now = nowForTest ?? System.now();
        // Changes are counted up to a few minutes ago, so a change stamped earlier but committed after this query
        // is still seen next time; each window starts where the last one ended, with no gap or overlap
        Datetime upTo = now.addMinutes(-COMMIT_LAG_MINUTES);
        Datetime since = settings.Last_Alert_Check__c ?? upTo.addHours(-1);
        Summary summary = summarize(since, upTo, now);
        summary.watchdogFailed = watchdogRan != true;
        // Saved before the send, which can't be undone: if the send fails, this is rolled back with it and the
        // same problems are reported next hour instead of being lost or sent twice
        settings.Last_Alert_Check__c = upTo;
        // System mode on purpose: package bookkeeping in Replayr's protected setting (see JobPoller)
        Database.upsert(settings, true, AccessLevel.SYSTEM_MODE);
        if (!summary.isEmpty()) {
            notifyAdmins(summary);
        }
        return summary;
    }

    // shortcut: any later edit to a reported job (an owner change, say) reports it again in a later window;
    // add a "status changed at" field if that proves noisy. SystemModstamp is indexed, LastModifiedDate isn't
    private static Summary summarize(Datetime since, Datetime upTo, Datetime now) {
        Summary summary = new Summary();
        for (AggregateResult row : [
            SELECT Status__c status, COUNT(Id) total
            FROM Job__c
            WHERE Test_Run__c = FALSE
                AND Status__c IN (:JobWorker.OUTCOME_UNKNOWN, :JobWorker.DEAD)
                AND SystemModstamp > :since
                AND SystemModstamp <= :upTo
            WITH USER_MODE
            GROUP BY Status__c
        ]) {
            Integer total = (Integer) row.get('total');
            if ((String) row.get('status') == JobWorker.OUTCOME_UNKNOWN) {
                summary.outcomeUnknown = total;
            } else {
                summary.dead = total;
            }
        }
        String notSaved = '%' + NOT_SAVED + '%';
        summary.notSaved = [
            SELECT COUNT()
            FROM Job__c
            WHERE Test_Run__c = FALSE
                AND Status__c = :JobWorker.SUCCEEDED
                AND Result__c LIKE :notSaved
                AND SystemModstamp > :since
                AND SystemModstamp <= :upTo
            WITH USER_MODE
        ];
        summary.notMoving = isWorkNotMoving(now.addHours(-NOT_MOVING_HOURS));
        return summary;
    }

    // Two small queries rather than one with an OR across fields, which no index can serve. shortcut: a
    // backlog that takes over two hours to drain correctly also counts as not moving
    // Also the console's health panel (ConsoleHealth)
    public static Boolean isWorkNotMoving(Datetime cutoff) {
        List<Job__c> queued = [
            SELECT Id
            FROM Job__c
            WHERE Status__c = :JobWorker.QUEUED AND SystemModstamp < :cutoff AND Test_Run__c = FALSE
            WITH USER_MODE
            LIMIT 1
        ];
        if (!queued.isEmpty()) {
            return true;
        }
        return ![
                SELECT Id
                FROM Job__c
                WHERE Status__c = :JobWorker.RETRY_WAIT AND Next_Attempt_At__c < :cutoff AND Test_Run__c = FALSE
                WITH USER_MODE
                LIMIT 1
            ]
            .isEmpty();
    }

    // System mode on purpose, in these two lookups only: who holds Replayr's own Admin set and the id of Replayr's
    // own notification type are setup facts, not user data, and the integration user has no setup access
    private static void notifyAdmins(Summary summary) {
        List<String> recipients = new List<String>(admins());
        List<CustomNotificationType> types = [
            SELECT Id
            FROM CustomNotificationType
            WHERE DeveloperName = :NOTIFICATION_TYPE AND NamespacePrefix = :namespace()
            WITH SYSTEM_MODE
        ];
        // Never a silent drop: the caller rolls back the check time, so the problems are reported once someone
        // can receive them, and the missing heartbeat shows the gap meanwhile
        if (recipients.isEmpty() || types.isEmpty()) {
            throw new AlertException(
                recipients.isEmpty() ? 'No active user has the Replayr Admin permission set.' : 'The Replayr alert notification type is missing.'
            );
        }
        Messaging.CustomNotification notification = new Messaging.CustomNotification();
        notification.setNotificationTypeId(types[0].Id);
        notification.setTitle('Replayr: jobs need attention');
        notification.setBody(summary.text().abbreviate(BODY_LIMIT));
        notification.setTargetPageRef(JSON.serialize(new Map<String, Object>{
            'type' => 'standard__objectPage',
            'attributes' => new Map<String, Object>{ 'objectApiName' => String.valueOf(Job__c.SObjectType), 'actionName' => 'list' }
        }));
        // Sent in batches, within the per-send recipient limit
        for (Integer start = 0; start < recipients.size(); start += MAX_RECIPIENTS) {
            Set<String> batch = new Set<String>();
            for (Integer k = start; k < Math.min(start + MAX_RECIPIENTS, recipients.size()); k++) {
                batch.add(recipients[k]);
            }
            notification.send(batch);
            sent++;
        }
    }

    // Active users with the Admin set, directly or through a permission set group that contains it
    private static Set<String> admins() {
        Set<String> recipients = new Set<String>();
        for (Id adminId : PermissionSetHolders.of(ADMIN_SET, null)) {
            recipients.add(adminId);
        }
        return recipients;
    }

    // replayr in the package and the dev org; null where the code has no namespace
    private static String namespace() {
        String name = String.valueOf(Job__c.SObjectType);
        return name.countMatches('__') > 1 ? name.substringBefore('__') : null;
    }
}
