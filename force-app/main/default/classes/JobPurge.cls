/**
 * The daily purge: deletes finished jobs (Succeeded, Failed; test runs included)
 * whose last change is older than the retention period, with their log rows, and empties them from the recycle
 * bin. Jobs that are still open, Outcome unknown or Retries used up are never purged: they need a person. Started
 * by the hourly JobPoller once a day, so it runs as the integration user; 200 jobs per batch.
 */
public with sharing class JobPurge implements Database.Batchable<SObject> {
    public static final Integer DEFAULT_RETENTION_DAYS = 30;
    public static final Integer BATCH_SIZE = 200;
    private static final Set<String> FINISHED = new Set<String>{ JobWorker.SUCCEEDED, JobWorker.FAILED };
    // Jobs plus their log rows per batch: each is deleted and then emptied from the bin, two of the 10,000 DML
    // rows, with room left over
    @TestVisible
    private static Integer rowBudget = 4500;

    private final Datetime cutoff;

    /**
     * @param retentionDays days to keep finished jobs; blank or below 1 means the default
     */
    public JobPurge(Decimal retentionDays) {
        this(System.now().addDays(-keptDays(retentionDays)));
    }

    // Tests can't age a record's timestamps, so they move the cutoff instead
    @TestVisible
    private JobPurge(Datetime cutoff) {
        this.cutoff = cutoff;
    }

    @TestVisible
    private static Integer keptDays(Decimal retentionDays) {
        return retentionDays == null || retentionDays < 1 ? DEFAULT_RETENTION_DAYS : retentionDays.intValue();
    }

    /**
     * @param context the batch context (unused)
     * @return the finished jobs last changed before the cutoff
     */
    public Database.QueryLocator start(Database.BatchableContext context) {
        return Database.getQueryLocator([
            SELECT Id
            FROM Job__c
            WHERE Status__c IN :FINISHED AND SystemModstamp < :cutoff
            WITH USER_MODE
        ]);
    }

    /**
     * Deletes one batch. The jobs are read again, locked: one replayed since the batch started is no longer
     * finished and is kept.
     * @param context the batch context (unused)
     * @param scope up to BATCH_SIZE jobs
     */
    public void execute(Database.BatchableContext context, List<Job__c> scope) {
        List<Job__c> stillFinished = [
            SELECT Id
            FROM Job__c
            WHERE Id IN :scope AND Status__c IN :FINISHED AND SystemModstamp < :cutoff
            WITH USER_MODE
            FOR UPDATE
        ];
        List<Job__c> toDelete = withinRowBudget(stillFinished);
        if (toDelete.isEmpty()) {
            return;
        }
        delete as user toDelete;
        // Results ignored on purpose: rows that fail to leave the bin go after the platform's 15 days anyway
        Database.emptyRecycleBin(toDelete);
    }

    // Log rows go with their job (master-detail) and count toward the 10,000 DML rows, as does emptying the bin,
    // so each row counts twice. Jobs beyond the budget wait for the next day's purge, so one job with an unusual
    // number of logs can't fail the whole batch. shortcut: a single job with more logs than the budget is never
    // purged (thousands of replays); trim its logs by hand or add log deletion if that ever happens
    private static List<Job__c> withinRowBudget(List<Job__c> jobs) {
        Map<Id, Integer> logCounts = new Map<Id, Integer>();
        for (AggregateResult row : [
            SELECT Job__c job, COUNT(Id) total
            FROM Job_Log__c
            WHERE Job__c IN :jobs
            WITH USER_MODE
            GROUP BY Job__c
        ]) {
            logCounts.put((Id) row.get('job'), (Integer) row.get('total'));
        }
        List<Job__c> chosen = new List<Job__c>();
        Integer budget = rowBudget;
        for (Job__c job : jobs) {
            Integer rows = 1 + (logCounts.get(job.Id) ?? 0);
            if (rows <= budget) {
                chosen.add(job);
                budget -= rows;
            }
        }
        return chosen;
    }

    /**
     * Nothing to do at the end.
     * @param context the batch context (unused)
     */
    public void finish(Database.BatchableContext context) {
        return;
    }
}
