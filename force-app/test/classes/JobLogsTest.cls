@IsTest
private with sharing class JobLogsTest {
    @TestSetup
    static void setup() {
        ReplayrTestAccess.createRunner();
    }

    @IsTest
    static void shortensTextToTheFieldLimit() {
        Assert.isNull(JobLogs.shorten(null), 'Null stays null');
        Assert.areEqual('short', JobLogs.shorten('short'), 'Short text unchanged');
        String exact = 'x'.repeat(JobLogs.TEXT_LIMIT);
        Assert.areEqual(exact, JobLogs.shorten(exact), 'Text at the limit unchanged');
        String shortened = JobLogs.shorten('y'.repeat(1000));
        Assert.areEqual(JobLogs.TEXT_LIMIT, shortened.length(), 'Long text cut to the limit');
        Assert.isTrue(shortened.endsWith('...'), 'Cut is marked');
    }

    @IsTest
    static void buildsALogRowThatSavesEvenWithALongMessage() {
        System.runAs(ReplayrTestAccess.runner()) {
            Provider__c provider = new Provider__c(Name = 'P', Named_Credential__c = 'N');
            insert provider;
            Endpoint__c endpoint = new Endpoint__c(Name = 'E', Provider__c = provider.Id, Method__c = 'GET');
            insert endpoint;
            Job__c job = new Job__c(Endpoint__c = endpoint.Id);
            insert job;

            Job_Log__c log = JobLogs.newLog(job.Id, 'Failed', 500, 'z'.repeat(5000), 42);
            insert log;

            Job_Log__c saved = [SELECT Outcome__c, HTTP_Status__c, Message__c, Duration_Ms__c FROM Job_Log__c WHERE Id = :log.Id];
            Assert.areEqual('Failed', saved.Outcome__c, 'Outcome');
            Assert.areEqual(500, saved.HTTP_Status__c, 'HTTP status');
            Assert.areEqual(JobLogs.TEXT_LIMIT, saved.Message__c.length(), 'Message shortened, insert did not fail');
            Assert.areEqual(42, saved.Duration_Ms__c, 'Duration');
        }
    }
}
