@IsTest
private with sharing class ConsoleSettingsTest {
    private static final String OPERATOR = ReplayrTestAccess.username('operator');

    @TestSetup
    static void setup() {
        ReplayrTestAccess.createRunner();
        System.runAs(new User(Id = UserInfo.getUserId())) {
            User operator = ReplayrTestAccess.newUser(ReplayrTestAccess.minimalProfileId(), OPERATOR);
            insert operator;
            insert new PermissionSetAssignment(AssigneeId = operator.Id, PermissionSetId = [SELECT Id FROM PermissionSet WHERE Name = 'Replayr_Operator'].Id);
        }
    }

    private static String refusal(Integer days) {
        try {
            ConsoleSettings.saveRetention(days);
            Assert.fail('Expected AuraHandledException');
        } catch (AuraHandledException e) {
            return e.getMessage();
        }
        return null;
    }

    @IsTest
    static void showsTheDefaultUntilRetentionIsSet() {
        ConsoleSettings.Settings shown;
        System.runAs(ReplayrTestAccess.runner()) {
            shown = ConsoleSettings.read();
        }

        Assert.areEqual(JobPurge.DEFAULT_RETENTION_DAYS, shown.retentionDays, 'The purge\'s default');
        Assert.areEqual(ConsoleSettings.MAX_RETENTION_DAYS, shown.maxRetentionDays, 'The range shown');
    }

    @IsTest
    static void savesRetentionTheWayThePurgeReadsIt() {
        ConsoleSettings.Settings saved;
        System.runAs(ReplayrTestAccess.runner()) {
            saved = ConsoleSettings.saveRetention(90);
        }

        Assert.areEqual(90, saved.retentionDays, 'Returned as saved');
        Assert.areEqual(90, Replayr_Settings__c.getOrgDefaults().Retention_Days__c, 'In the protected setting the purge reads');
    }

    @IsTest
    static void aRetentionSavedIsNotUndoneByTheOtherWritersOfTheSetting() {
        System.runAs(ReplayrTestAccess.runner()) {
            ConsoleSettings.saveRetention(90);
        }
        // The poller's heartbeat and the hand-off write their own fields only
        SettingsWriter.write(new Map<Schema.SObjectField, Object>{ Replayr_Settings__c.Poller_Last_Run__c => System.now() });
        SettingsWriter.write(new Map<Schema.SObjectField, Object>{ Replayr_Settings__c.Hand_Off_User__c => UserInfo.getUserId() });

        Replayr_Settings__c row = Replayr_Settings__c.getOrgDefaults();
        Assert.areEqual(90, row.Retention_Days__c, 'Still 90');
        Assert.isNotNull(row.Poller_Last_Run__c, 'The heartbeat written');
        Assert.areEqual(1, [SELECT COUNT() FROM Replayr_Settings__c], 'One org-wide row');
    }

    @IsTest
    static void refusesDaysOutsideTheRange() {
        System.runAs(ReplayrTestAccess.runner()) {
            for (Integer days : new List<Integer>{ null, 0, -5, ConsoleSettings.MAX_RETENTION_DAYS + 1 }) {
                Assert.isTrue(refusal(days).contains('to ' + ConsoleSettings.MAX_RETENTION_DAYS + ' days'), 'Refused: ' + days);
            }
            Assert.areEqual(ConsoleSettings.MAX_RETENTION_DAYS, ConsoleSettings.saveRetention(ConsoleSettings.MAX_RETENTION_DAYS).retentionDays, 'The top of the range');
        }
        Assert.areEqual(ConsoleSettings.MAX_RETENTION_DAYS, Replayr_Settings__c.getOrgDefaults().Retention_Days__c, 'Only the valid value saved');
    }

    @IsTest
    static void setsBackgroundWorkOffThroughTheHandOff() {
        Boolean published;
        System.runAs(ReplayrTestAccess.runner()) {
            Test.startTest();
            published = ConsoleSettings.startBackgroundWork();
            Test.stopTest();
        }
        Test.getEventBus().deliver();

        Assert.isTrue(published, 'Published');
        // The trigger ran (as Automated Process in a test) and recorded itself
        Assert.isNotNull(Replayr_Settings__c.getOrgDefaults().Hand_Off_Last_Run__c, 'The hand-off ran');
    }

    @IsTest
    static void isForReplayrAdminsOnly() {
        User operator = [SELECT Id FROM User WHERE Username = :OPERATOR];
        System.runAs(operator) {
            for (Integer attempt = 0; attempt < 3; attempt++) {
                try {
                    if (attempt == 0) {
                        ConsoleSettings.read();
                    } else if (attempt == 1) {
                        ConsoleSettings.saveRetention(60);
                    } else {
                        ConsoleSettings.startBackgroundWork();
                    }
                    Assert.fail('Expected AuraHandledException');
                } catch (AuraHandledException e) {
                    Assert.isTrue(e.getMessage().contains('Replayr Admin'), e.getMessage());
                }
            }
        }
        Assert.isNull(Replayr_Settings__c.getOrgDefaults().Retention_Days__c, 'Nothing saved');
    }
}
