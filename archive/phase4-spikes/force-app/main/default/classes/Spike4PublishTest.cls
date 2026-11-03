// Spike P4.1: can a user with no access to the event publish it from Apex?
@IsTest
private class Spike4PublishTest {
    @IsTest
    static void userWithoutEventAccessCantPublish() {
        User nobody = ReplayrTestAccess.newUser(ReplayrTestAccess.minimalProfileId(), ReplayrTestAccess.username('spike4'));
        insert nobody;
        Database.SaveResult result;
        Boolean canCreate;
        System.runAs(nobody) {
            canCreate = Schema.SObjectType.Spike4_Wake__e.isCreateable();
            result = EventBus.publish(new Spike4_Wake__e());
        }
        System.debug(LoggingLevel.ERROR, 'SPIKE4 createable=' + canCreate + ' published=' + result.isSuccess() + ' errors=' + result.getErrors());
        Assert.isFalse(canCreate, 'The minimal user has no Create on the event');
        // Result 2026-11-01: refused, "Access to entity ... denied" (CANNOT_INSERT_UPDATE_ACTIVATE_ENTITY)
        Assert.isFalse(result.isSuccess(), 'Publishing needs Create on the event, even from Apex');
        Assert.areEqual(StatusCode.CANNOT_INSERT_UPDATE_ACTIVATE_ENTITY, result.getErrors()[0].getStatusCode(), 'Refused for access');
    }
}
