/**
 * The console's health panel (decisions.md, ADR-021): whether Replayr's background work is set up and moving, read
 * from what the poller, the hand-off and the alerts already record. Each problem comes back as a plain warning,
 * so the panel only shows them. For Replayr Admins and Operators (Replayr_Manage_Jobs); jobs are counted in
 * user mode, as the alerts count them.
 */
public with sharing class ConsoleHealth {
    public static final String PERMISSION = 'Replayr_Manage_Jobs';
    // Hourly, plus time for a slow run
    @TestVisible
    private static final Integer POLLER_LATE_MINUTES = 90;
    // The CronTrigger states in which the poller still fires (BLOCKED: waiting for its own previous run)
    private static final Set<String> FIRING_STATES = new Set<String>{ 'WAITING', 'ACQUIRED', 'EXECUTING', 'BLOCKED' };
    private static final String GUIDE = ' (Replayr admin guide).';

    /** What the panel shows. Times are null when the thing never happened. */
    public class Health {
        @AuraEnabled
        public Datetime pollerLastRun;
        /** Null when the user can't see scheduled jobs (View Setup and Configuration); the heartbeat still shows a stopped poller. */
        @AuraEnabled
        public Boolean pollerScheduled;
        @AuraEnabled
        public String pollerOwner;
        @AuraEnabled
        public String handOffUser;
        @AuraEnabled
        public Datetime handOffLastRun;
        /** When the job waiting longest in Queued was last changed. */
        @AuraEnabled
        public Datetime oldestQueued;
        @AuraEnabled
        public Integer outcomeUnknown = 0;
        @AuraEnabled
        public Integer retriesUsedUp = 0;
        @AuraEnabled
        public Datetime lastAlertCheck;
        @AuraEnabled
        public Datetime lastPurge;
        @AuraEnabled
        public List<String> warnings = new List<String>();
    }

    /**
     * Reads the health of Replayr's background work.
     * @return the health, with a warning for each problem found
     */
    @AuraEnabled
    public static Health read() {
        if (!FeatureManagement.checkPermission(PERMISSION)) {
            throw ConsoleError.of('You need the Replayr Admin or Replayr Operator permission set.');
        }
        try {
            Replayr_Settings__c settings = Replayr_Settings__c.getOrgDefaults();
            Health health = new Health();
            health.lastAlertCheck = settings.Last_Alert_Check__c;
            health.lastPurge = settings.Last_Purge_Started__c;
            readPoller(health, settings.Poller_Last_Run__c);
            readHandOff(health, settings.Hand_Off_User__c, settings.Hand_Off_Last_Run__c);
            readJobs(health);
            return health;
        } catch (Exception e) {
            // Only the type: a query error can name fields and objects
            throw ConsoleError.of('Replayr couldn\'t read its health (' + e.getTypeName() + ').');
        }
    }

    private static void readPoller(Health health, Datetime lastRun) {
        health.pollerLastRun = lastRun;
        if (lastRun == null) {
            health.warnings.add(
                'The poller hasn\'t finished a run yet. It runs hourly: if it was scheduled over an hour ago, it isn\'t running. Schedule it as Replayr\'s integration user' + GUIDE
            );
        } else if (lastRun < System.now().addMinutes(-POLLER_LATE_MINUTES)) {
            health.warnings.add(
                'The poller hasn\'t finished a run for over ' + POLLER_LATE_MINUTES + ' minutes: it stopped, or part of it is failing.'
            );
        }
        List<CronTrigger> pollers;
        try {
            pollers = [SELECT OwnerId, State FROM CronTrigger WHERE CronJobDetail.Name = :JobPoller.JOB_NAME WITH USER_MODE LIMIT 1];
        } catch (Exception e) {
            // Scheduled jobs need View Setup and Configuration, even to read; most Operators lack it, which is not a
            // problem to warn about. pollerScheduled stays null and the panel says the schedule isn't visible
            return;
        }
        if (pollers.isEmpty()) {
            health.pollerScheduled = false;
            health.warnings.add('The poller isn\'t scheduled. Schedule it as Replayr\'s integration user' + GUIDE);
            return;
        }
        CronTrigger poller = pollers[0];
        health.pollerScheduled = FIRING_STATES.contains(poller.State);
        health.pollerOwner = nameOf(poller.OwnerId);
        if (!health.pollerScheduled) {
            health.warnings.add('The poller is scheduled but won\'t run (state ' + poller.State + '). Schedule it again' + GUIDE);
        }
        if (!WorkWaiting.isIntegrationUser(poller.OwnerId)) {
            health.warnings.add(
                'The poller runs as ' + health.pollerOwner + ', not an active Replayr integration user, so its work can\'t call out. Schedule it again as the integration user' + GUIDE
            );
        }
    }

    private static void readHandOff(Health health, String userId, Datetime lastRun) {
        health.handOffLastRun = lastRun;
        if (String.isBlank(userId)) {
            health.warnings.add('The event trigger hasn\'t run yet: it runs at the first send or replay once its run-as user is set' + GUIDE);
            return;
        }
        health.handOffUser = nameOf(userId);
        if (!WorkWaiting.isIntegrationUser(userId)) {
            health.warnings.add(
                'The event trigger runs as ' + health.handOffUser + ', not an active Replayr integration user, so new work waits for the hourly poller. Set its run-as user' + GUIDE
            );
        }
    }

    // A failure here (such as a field removed from a trimmed permission set) costs only the job figures
    private static void readJobs(Health health) {
        try {
            countJobs(health);
        } catch (Exception e) {
            health.warnings.add('Job figures aren\'t available to you (' + e.getTypeName() + '): check your Replayr permission set.');
        }
    }

    private static void countJobs(Health health) {
        for (AggregateResult row : [
            SELECT Status__c status, COUNT(Id) total
            FROM Job__c
            WHERE Test_Run__c = FALSE AND Status__c IN (:JobWorker.OUTCOME_UNKNOWN, :JobWorker.DEAD)
            WITH USER_MODE
            GROUP BY Status__c
        ]) {
            Integer total = (Integer) row.get('total');
            if ((String) row.get('status') == JobWorker.OUTCOME_UNKNOWN) {
                health.outcomeUnknown = total;
            } else {
                health.retriesUsedUp = total;
            }
        }
        if (health.outcomeUnknown + health.retriesUsedUp > 0) {
            health.warnings.add('Jobs need a person: ' + health.outcomeUnknown + ' Outcome unknown, ' + health.retriesUsedUp + ' Retries used up.');
        }
        List<Job__c> oldest = [
            SELECT SystemModstamp
            FROM Job__c
            WHERE Status__c = :JobWorker.QUEUED AND Test_Run__c = FALSE
            WITH USER_MODE
            ORDER BY SystemModstamp ASC
            LIMIT 1
        ];
        health.oldestQueued = oldest.isEmpty() ? null : oldest[0].SystemModstamp;
        // The same rule as the "work not moving" alert
        if (JobAlerts.isWorkNotMoving(System.now().addHours(-JobAlerts.NOT_MOVING_HOURS))) {
            health.warnings.add('Work hasn\'t moved for over ' + JobAlerts.NOT_MOVING_HOURS + ' hours: jobs are waiting and no chain is sending them.');
        }
    }

    // The name, or the Id when the user can't see that user
    private static String nameOf(String userId) {
        List<User> users = [SELECT Name FROM User WHERE Id = :userId WITH USER_MODE];
        return users.isEmpty() ? userId : users[0].Name;
    }
}
