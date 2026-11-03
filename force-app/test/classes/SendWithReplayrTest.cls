// The "Send with Replayr" Flow action (decisions.md, ADR-019), called as Flow calls it: one request per record
@IsTest
private with sharing class SendWithReplayrTest {
    private static final String SENDER = ReplayrTestAccess.username('sender');
    private static final String NON_SENDER = ReplayrTestAccess.username('nonsender');
    private static final Integer RECORD_COUNT = 200;

    @TestSetup
    static void setup() {
        User runner = ReplayrTestAccess.createRunner();
        User sender = ReplayrTestAccess.newUser(ReplayrTestAccess.minimalProfileId(), SENDER);
        User nonSender = ReplayrTestAccess.newUser(ReplayrTestAccess.minimalProfileId(), NON_SENDER);
        System.runAs(new User(Id = UserInfo.getUserId())) {
            insert new List<User>{ sender, nonSender };
            PermissionSet accountRead = new PermissionSet(Name = 'Replayr_Test_Account_Read', Label = 'Replayr Test Account Read');
            insert accountRead;
            insert new ObjectPermissions(ParentId = accountRead.Id, SobjectType = 'Account', PermissionsRead = true);
            insert new List<PermissionSetAssignment>{
                new PermissionSetAssignment(AssigneeId = sender.Id, PermissionSetId = [SELECT Id FROM PermissionSet WHERE Name = 'Replayr_Sender'].Id),
                new PermissionSetAssignment(AssigneeId = sender.Id, PermissionSetId = accountRead.Id),
                new PermissionSetAssignment(AssigneeId = nonSender.Id, PermissionSetId = accountRead.Id)
            };
        }
        System.runAs(runner) {
            Provider__c provider = new Provider__c(Name = 'Acme', Named_Credential__c = 'Test_API');
            insert provider;
            Endpoint__c orders = new Endpoint__c(
                Name = 'Orders',
                Key__c = 'orders',
                Provider__c = provider.Id,
                Method__c = 'POST',
                Path__c = '/orders',
                Allow_Sending__c = true
            );
            insert orders;
            insert new Mapping__c(Endpoint__c = orders.Id, Direction__c = 'Request', Target_Object__c = 'Account', Rules__c = '{"name": "{{Name}}"}');
        }
        // Owned by the sender, so it sees them whatever the org's Account sharing
        List<Account> accounts = new List<Account>();
        for (Integer i = 0; i < RECORD_COUNT; i++) {
            accounts.add(new Account(Name = 'Account ' + String.valueOf(i).leftPad(3, '0'), OwnerId = sender.Id));
        }
        insert accounts;
    }

    private static User user(String username) {
        return [SELECT Id FROM User WHERE Username = :username];
    }

    private static List<SendWithReplayr.Request> requests(String key, List<Account> accounts) {
        List<SendWithReplayr.Request> requests = new List<SendWithReplayr.Request>();
        for (Account account : accounts) {
            SendWithReplayr.Request request = new SendWithReplayr.Request();
            request.endpointKey = key;
            request.recordId = account.Id;
            requests.add(request);
        }
        return requests;
    }

    private static List<Account> accounts() {
        return [SELECT Id FROM Account ORDER BY Name];
    }

    private static Integer jobCount() {
        System.runAs(ReplayrTestAccess.runner()) {
            return [SELECT COUNT() FROM Job__c];
        }
        return null;
    }

    @IsTest
    static void sendsTwoHundredRecordsAndStartsTheHandOff() {
        List<SendWithReplayr.Request> requests = requests('orders', accounts());
        List<SendWithReplayr.Result> results;
        System.runAs(user(SENDER)) {
            Test.startTest();
            results = SendWithReplayr.send(requests);
            Assert.isTrue(WorkWaiting.published, 'The work-waiting event was published');
            Test.stopTest();
        }

        Assert.areEqual(RECORD_COUNT, results.size(), 'One result per record');
        Set<Id> jobIds = new Set<Id>();
        for (SendWithReplayr.Result result : results) {
            Assert.isNull(result.error, 'No error expected: ' + result.error);
            jobIds.add(result.jobId);
        }
        Assert.areEqual(RECORD_COUNT, jobIds.size(), 'A distinct job per record');
        Assert.areEqual(RECORD_COUNT, jobCount(), 'All saved');
    }

    @IsTest
    static void failsTheFlowWithoutTheSenderPermissionSet() {
        List<SendWithReplayr.Request> requests = requests('orders', new List<Account>{ accounts()[0] });
        System.runAs(user(NON_SENDER)) {
            try {
                SendWithReplayr.send(requests);
                Assert.fail('Expected a SendException');
            } catch (SendWithReplayr.SendException e) {
                Assert.areEqual(JobCreation.NO_PERMISSION, e.getMessage(), 'Names the missing permission set');
            }
        }
        Assert.areEqual(0, jobCount(), 'Nothing saved');
    }

    @IsTest
    static void reportsAnErrorForARecordThatCantBeSentAndSendsTheRest() {
        List<SendWithReplayr.Request> requests = requests('orders', new List<Account>{ accounts()[0] });
        requests.addAll(requests('nope', new List<Account>{ accounts()[1] }));
        requests.addAll(requests(' ', new List<Account>{ accounts()[2] }));
        requests.add(null);
        List<SendWithReplayr.Result> results;
        System.runAs(user(SENDER)) {
            results = SendWithReplayr.send(requests);
            Assert.isTrue(WorkWaiting.published, 'One job was made, so the hand-off starts');
        }

        Assert.areEqual(4, results.size(), 'One result per request, the missing one included');
        Assert.isNotNull(results[0].jobId, 'The good record is sent');
        Assert.isNull(results[0].error, 'No error for it');
        Assert.areEqual(JobCreation.CANT_SEND, results[1].error, 'The unknown key, in the general message');
        Assert.isNull(results[1].jobId, 'No job for it');
        Assert.areEqual('Name the endpoint by its key.', results[2].error, 'A blank key');
        Assert.areEqual('Name the endpoint by its key.', results[3].error, 'A missing request');
    }

    @IsTest
    static void refusesMoreThanTwoHundredRecordsInOneCall() {
        List<Account> accounts = accounts();
        accounts.add(accounts[0]);
        List<SendWithReplayr.Result> results;
        System.runAs(user(SENDER)) {
            results = SendWithReplayr.send(requests('orders', accounts));
            Assert.isFalse(WorkWaiting.published, 'Nothing to start');
        }

        Assert.areEqual(RECORD_COUNT + 1, results.size(), 'One result per record');
        for (SendWithReplayr.Result result : results) {
            Assert.areEqual('Send at most 200 records at a time.', result.error, 'Each record says why');
        }
        Assert.areEqual(0, jobCount(), 'Nothing saved');
    }

    // Calling the action directly in a test skips the Apex class access check, so the grant is checked here
    @IsTest
    static void theSenderAndAdminSetsGrantTheAction() {
        Set<String> granting = new Set<String>();
        for (SetupEntityAccess access : [
            SELECT Parent.Name
            FROM SetupEntityAccess
            WHERE SetupEntityId IN (SELECT Id FROM ApexClass WHERE Name = 'SendWithReplayr')
        ]) {
            granting.add(access.Parent.Name);
        }

        Assert.isTrue(granting.contains('Replayr_Sender'), 'Sender grants the action: ' + granting);
        Assert.isTrue(granting.contains('Replayr_Admin'), 'Admin grants the action: ' + granting);
    }

    @IsTest
    static void returnsNothingForNoRecords() {
        System.runAs(user(SENDER)) {
            Assert.isTrue(SendWithReplayr.send(new List<SendWithReplayr.Request>()).isEmpty(), 'Empty in, empty out');
            Assert.isTrue(SendWithReplayr.send(null).isEmpty(), 'Null in, empty out');
        }
    }
}
