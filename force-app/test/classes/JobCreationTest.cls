@IsTest
private with sharing class JobCreationTest {
    private static final String SENDER = ReplayrTestAccess.username('sender');
    private static final String NON_SENDER = ReplayrTestAccess.username('nonsender');
    private static final Integer RECORD_COUNT = 200;
    // Four merges of a 32,000-character description: bodies near the 131,072-character maximum
    private static final String BIG_TEMPLATE = '"{{Description}}{{Description}}{{Description}}{{Description}}"';

    @TestSetup
    static void setup() {
        User runner = ReplayrTestAccess.createRunner();
        User sender = ReplayrTestAccess.newUser(ReplayrTestAccess.minimalProfileId(), SENDER);
        User nonSender = ReplayrTestAccess.newUser(ReplayrTestAccess.minimalProfileId(), NON_SENDER);
        System.runAs(new User(Id = UserInfo.getUserId())) {
            insert new List<User>{ sender, nonSender };
            Id accountRead = accountReadPermissionSet();
            Id senderSet = [SELECT Id FROM PermissionSet WHERE Name = 'Replayr_Sender'].Id;
            insert new List<PermissionSetAssignment>{
                new PermissionSetAssignment(AssigneeId = sender.Id, PermissionSetId = senderSet),
                new PermissionSetAssignment(AssigneeId = sender.Id, PermissionSetId = accountRead),
                new PermissionSetAssignment(AssigneeId = nonSender.Id, PermissionSetId = accountRead)
            };
        }
        System.runAs(runner) {
            // Private, and the senders can't see it: the endpoint is found by key all the same
            Provider__c provider = new Provider__c(Name = 'Acme', Named_Credential__c = 'Test_API');
            insert provider;
            Endpoint__c orders = endpoint(provider.Id, 'orders', 'POST', '/orders');
            orders.Retry_Safe__c = true;
            Endpoint__c ping = endpoint(provider.Id, 'ping', 'GET', '/ping');
            Endpoint__c twice = endpoint(provider.Id, 'twice', 'POST', '/twice');
            Endpoint__c big = endpoint(provider.Id, 'big', 'POST', '/big');
            Endpoint__c phone = endpoint(provider.Id, 'phone', 'POST', '/phone');
            Endpoint__c providers = endpoint(provider.Id, 'providers', 'POST', '/providers');
            Endpoint__c writeBack = endpoint(provider.Id, 'writeback', 'POST', '/writeback');
            Endpoint__c matched = endpoint(provider.Id, 'matched', 'POST', '/matched');
            Endpoint__c badJson = endpoint(provider.Id, 'badjson', 'POST', '/badjson');
            Endpoint__c otherObject = endpoint(provider.Id, 'otherobject', 'POST', '/otherobject');
            insert new List<Endpoint__c>{ orders, ping, twice, big, phone, providers, writeBack, matched, badJson, otherObject };
            insert new List<Mapping__c>{
                request(orders.Id, '{"name": "{{Name}}", "about": "{{Description}}"}'),
                request(twice.Id, '{"name": "{{Name}}"}'),
                request(twice.Id, '{"other": "{{Name}}"}'),
                request(big.Id, BIG_TEMPLATE),
                // The senders can't read Phone
                request(phone.Id, '{"phone": "{{Phone}}"}'),
                // The senders can't read providers at all
                new Mapping__c(Endpoint__c = providers.Id, Direction__c = 'Request', Target_Object__c = 'Provider__c', Rules__c = '{"n": "{{Name}}"}'),
                request(writeBack.Id, '{"name": "{{Name}}"}'),
                // Writes the response back to the sent record, as the integration user
                response(writeBack.Id, null),
                request(matched.Id, '{"name": "{{Name}}"}'),
                // Writes to whichever record the response names, not the sent one
                response(matched.Id, 'Name'),
                // The closing brace is missing: each built body is invalid JSON
                request(badJson.Id, '{"name": "{{Name}}"'),
                request(otherObject.Id, '{"name": "{{Name}}"}')
            };
            Mapping__c contactWriteBack = response(otherObject.Id, null);
            // ResponseWriter writes back only to a record of this object, so an Account is never written
            contactWriteBack.Target_Object__c = 'Contact';
            insert contactWriteBack;
        }
        // Owned by the sender, so it sees them whatever the org's Account sharing
        List<Account> accounts = new List<Account>();
        String description = 'x'.repeat(32000);
        for (Integer i = 0; i < RECORD_COUNT; i++) {
            accounts.add(new Account(Name = 'Account ' + String.valueOf(i).leftPad(3, '0'), Description = description, OwnerId = sender.Id));
        }
        insert accounts;
    }

    private static Id accountReadPermissionSet() {
        PermissionSet permissionSet = new PermissionSet(Name = 'Replayr_Test_Account_Read', Label = 'Replayr Test Account Read');
        insert permissionSet;
        insert new ObjectPermissions(ParentId = permissionSet.Id, SobjectType = 'Account', PermissionsRead = true);
        insert new FieldPermissions(ParentId = permissionSet.Id, SobjectType = 'Account', Field = 'Account.Description', PermissionsRead = true);
        return permissionSet.Id;
    }

    private static Endpoint__c endpoint(Id providerId, String key, String method, String path) {
        return new Endpoint__c(Name = key, Key__c = key, Provider__c = providerId, Method__c = method, Path__c = path, Allow_Sending__c = true);
    }

    private static Mapping__c request(Id endpointId, String template) {
        return new Mapping__c(Endpoint__c = endpointId, Direction__c = 'Request', Target_Object__c = 'Account', Rules__c = template);
    }

    private static Mapping__c response(Id endpointId, String matchField) {
        return new Mapping__c(
            Endpoint__c = endpointId,
            Direction__c = 'Response',
            Target_Object__c = 'Account',
            Operation__c = 'Update',
            Match_Field__c = matchField,
            Rules__c = '{"fields": {"Description": "about"}}'
        );
    }

    // Edit on Account for the sender, on top of its read; assignments take effect inside System.runAs
    private static void grantAccountEdit() {
        System.runAs(new User(Id = UserInfo.getUserId())) {
            PermissionSet permissionSet = new PermissionSet(Name = 'Replayr_Test_Account_Edit', Label = 'Replayr Test Account Edit');
            insert permissionSet;
            insert new ObjectPermissions(ParentId = permissionSet.Id, SobjectType = 'Account', PermissionsRead = true, PermissionsEdit = true);
            insert new PermissionSetAssignment(AssigneeId = user(SENDER).Id, PermissionSetId = permissionSet.Id);
        }
    }

    private static User user(String username) {
        return [SELECT Id FROM User WHERE Username = :username];
    }

    private static List<JobCreation.Request> requests(String key, List<Account> accounts) {
        List<JobCreation.Request> requests = new List<JobCreation.Request>();
        for (Account account : accounts) {
            requests.add(new JobCreation.Request(key, account.Id));
        }
        return requests;
    }

    private static List<Account> accounts() {
        return [SELECT Id, Name FROM Account ORDER BY Name];
    }

    private static Id providerId() {
        System.runAs(ReplayrTestAccess.runner()) {
            return [SELECT Id FROM Provider__c].Id;
        }
        return null;
    }

    // Read as the runner: only Replayr's permission sets grant access to Job fields
    private static Map<Id, Job__c> jobs() {
        System.runAs(ReplayrTestAccess.runner()) {
            return new Map<Id, Job__c>(
                [SELECT Id, Status__c, Method__c, Path__c, Retry_Safe__c, Record_Id__c, Request_Body__c, OwnerId FROM Job__c]
            );
        }
        return null;
    }

    @IsTest
    static void queuesOneJobPerRecordIn200RecordBulk() {
        List<Account> accounts = accounts();
        User sender = user(SENDER);
        List<JobCreation.Result> results;
        Integer queries;
        System.runAs(sender) {
            Test.startTest();
            results = JobCreation.create(requests('orders', accounts));
            queries = Limits.getQueries();
            Test.stopTest();
        }

        Assert.areEqual(RECORD_COUNT, results.size(), 'One result per request');
        Map<Id, Job__c> jobs = jobs();
        Assert.areEqual(RECORD_COUNT, jobs.size(), 'One job per record');
        for (Integer i = 0; i < RECORD_COUNT; i++) {
            Assert.isNull(results[i].error, 'No error expected: ' + results[i].error);
            Job__c job = jobs.get(results[i].jobId);
            Assert.areEqual(String.valueOf(accounts[i].Id), job.Record_Id__c, 'Results are in request order');
            Assert.isTrue(job.Request_Body__c.startsWith('{"name": "' + accounts[i].Name + '"'), 'Body built from the record');
            Assert.areEqual('Queued', job.Status__c, 'Queued for the worker');
            Assert.areEqual('POST', job.Method__c, 'Method copied from the endpoint');
            Assert.areEqual('/orders', job.Path__c, 'Path copied from the endpoint');
            Assert.isTrue(job.Retry_Safe__c, 'Retry-safe copied from the endpoint');
            Assert.areEqual(sender.Id, job.OwnerId, 'Owned by the sender');
        }
        // One endpoint query and one per chunk of 20 records
        Assert.isTrue(queries <= 11, 'Queries stay bounded, used ' + queries);
    }

    @IsTest
    static void savesLargeBodiesInSeveralBatches() {
        List<JobCreation.Request> requests = requests('big', accounts());
        List<JobCreation.Result> results;
        Integer saves;
        System.runAs(user(SENDER)) {
            Test.startTest();
            Integer before = Limits.getDmlStatements();
            results = JobCreation.create(requests);
            saves = Limits.getDmlStatements() - before;
            Test.stopTest();
        }

        for (JobCreation.Result result : results) {
            Assert.isNull(result.error, 'No error expected: ' + result.error);
            Assert.isNotNull(result.jobId, 'A job for every record');
        }
        // Each unit of 20 bodies (JobCreation.CHUNK_SIZE) passes SAVE_AT_LENGTH, so each is saved before the next
        // is built. Counts only DML inside create(); update it if create() ever does other DML
        Assert.areEqual(RECORD_COUNT / 20, saves, 'Large bodies are saved in batches, not held all at once');
        Assert.areEqual(128002, jobs().get(results[0].jobId).Request_Body__c.length(), 'The whole body is stored');
    }

    @IsTest
    static void refusesEveryRecordWithoutThePermission() {
        // Read first: the sender owns the accounts, so the non-sender may not see them
        List<JobCreation.Request> requests = requests('orders', accounts());
        List<JobCreation.Result> results;
        System.runAs(user(NON_SENDER)) {
            results = JobCreation.create(requests);
        }

        Assert.areEqual(RECORD_COUNT, results.size(), 'One result per request');

        for (JobCreation.Result result : results) {
            Assert.areEqual(JobCreation.NO_PERMISSION, result.error, 'Names the missing permission');
            Assert.isNull(result.jobId, 'No job');
        }
        Assert.areEqual(0, jobs().size(), 'Nothing queued');
    }

    @IsTest
    static void reportsAnErrorPerRecordAndQueuesTheRest() {
        Account account = accounts()[0];
        Id providerId = providerId();
        List<JobCreation.Request> requests = new List<JobCreation.Request>{
            new JobCreation.Request(' ', account.Id),
            new JobCreation.Request('nope', account.Id),
            new JobCreation.Request('twice', account.Id),
            new JobCreation.Request('orders', providerId),
            new JobCreation.Request('orders', null),
            new JobCreation.Request('ORDERS', account.Id),
            new JobCreation.Request('orders', account.Id),
            new JobCreation.Request('ping', null)
        };
        List<JobCreation.Result> results;
        System.runAs(user(SENDER)) {
            results = JobCreation.create(requests);
        }

        Assert.areEqual('Name the endpoint by its key.', results[0].error, 'Blank key');
        // The endpoint's setup is the admin's, so the sender gets one message for all of it
        Assert.areEqual(JobCreation.CANT_SEND, results[1].error, 'Unknown key');
        Assert.areEqual(JobCreation.CANT_SEND, results[2].error, 'Ambiguous mapping');
        Assert.areEqual(JobCreation.CANT_SEND, results[3].error, 'Wrong object');
        Assert.areEqual(JobCreation.CANT_SEND, results[4].error, 'No record');
        for (Integer i = 0; i < 5; i++) {
            Assert.isNull(results[i].jobId, 'No job for a refused request');
        }
        for (Integer i = 5; i < 8; i++) {
            Assert.isNull(results[i].error, 'Key ignores case; the same record twice gets two jobs; a GET needs no record');
            Assert.isNotNull(results[i].jobId, 'Queued');
        }
        Map<Id, Job__c> jobs = jobs();
        Assert.areEqual(3, jobs.size(), 'Only the accepted requests are queued');
        Assert.isNull(jobs.get(results[7].jobId).Request_Body__c, 'No mapping, no body');
        Assert.areEqual('GET', jobs.get(results[7].jobId).Method__c, 'Method copied');
    }

    @IsTest
    static void refusesRecordsWhoseMergedFieldTheSenderCantRead() {
        List<Account> accounts = accounts();
        List<JobCreation.Request> requests = requests('phone', new List<Account>{ accounts[0], accounts[1] });
        requests.add(new JobCreation.Request('orders', accounts[2].Id));
        List<JobCreation.Result> results;
        System.runAs(user(SENDER)) {
            results = JobCreation.create(requests);
        }

        Assert.areEqual(JobCreation.CANT_SEND, results[0].error, 'Phone is not readable by the sender; the template stays hidden');
        Assert.areEqual(results[0].error, results[1].error, 'The same error for every record of that endpoint');
        Assert.isNull(results[0].jobId, 'No job');
        Assert.isNotNull(results[2].jobId, 'Another endpoint in the same call still goes ahead');
    }

    @IsTest
    static void refusesARecordTheSenderCantSeeWhenThereIsNoBody() {
        Id providerId = providerId();
        List<JobCreation.Result> results;
        System.runAs(user(SENDER)) {
            results = JobCreation.create(new List<JobCreation.Request>{ new JobCreation.Request('ping', providerId) });
        }

        // A Response mapping could later write to it as the integration user
        Assert.isNotNull(results[0].error, 'The sender can\'t read providers');
        Assert.isNull(results[0].jobId, 'No job');
    }

    @IsTest
    static void queuesAJobForAVisibleRecordWhenThereIsNoBody() {
        Account account = accounts()[0];
        List<JobCreation.Result> results;
        System.runAs(user(SENDER)) {
            results = JobCreation.create(new List<JobCreation.Request>{ new JobCreation.Request('ping', account.Id) });
        }

        Assert.isNull(results[0].error, 'No error expected: ' + results[0].error);
        Assert.areEqual(String.valueOf(account.Id), jobs().get(results[0].jobId).Record_Id__c, 'Record kept for a Response mapping');
    }

    @IsTest
    static void keepsEachResultWithItsOwnRequestWhenEndpointsAreMixed() {
        List<Account> accounts = accounts();
        List<JobCreation.Request> requests = new List<JobCreation.Request>();
        // 45 requests across two endpoints, more than one chunk each, with some records sent twice
        for (Integer i = 0; i < 45; i++) {
            requests.add(new JobCreation.Request(Math.mod(i, 2) == 0 ? 'orders' : 'ping', accounts[Math.mod(i, 30)].Id));
        }
        List<JobCreation.Result> results;
        System.runAs(user(SENDER)) {
            results = JobCreation.create(requests);
        }

        Map<Id, Job__c> jobs = jobs();
        Assert.areEqual(45, jobs.size(), 'One job per request, repeats included');
        for (Integer i = 0; i < 45; i++) {
            Job__c job = jobs.get(results[i].jobId);
            Assert.areEqual(String.valueOf(requests[i].recordId), job.Record_Id__c, 'Record of request ' + i);
            Assert.areEqual(requests[i].endpointKey == 'orders' ? '/orders' : '/ping', job.Path__c, 'Endpoint of request ' + i);
            Assert.areEqual(requests[i].endpointKey == 'orders', job.Request_Body__c != null, 'Body only from a mapping, request ' + i);
        }
    }

    @IsTest
    static void refusesARecordOfAnObjectTheSenderCantReadWhenThereIsABody() {
        List<JobCreation.Result> results;
        Id providerId = providerId();
        System.runAs(user(SENDER)) {
            results = JobCreation.create(new List<JobCreation.Request>{ new JobCreation.Request('providers', providerId) });
        }

        Assert.areEqual(JobCreation.CANT_SEND, results[0].error, 'MergeTemplate\'s detail stays hidden from the sender');
        Assert.isNull(results[0].jobId, 'No job');
        Assert.areEqual(0, jobs().size(), 'Nothing queued');
    }

    // The loop uses up queries on purpose
    @SuppressWarnings('PMD.OperationWithLimitsInLoop, PMD.UnusedLocalVariable')
    @IsTest
    static void refusesWorkThatWouldUseTheCallersQueries() {
        List<JobCreation.Request> requests = requests('orders', new List<Account>{ accounts()[0] });
        List<JobCreation.Result> results;
        System.runAs(user(SENDER)) {
            Test.startTest();
            // Leaves exactly the 20 queries kept free once the endpoint lookup has run
            while (Limits.getQueries() < Limits.getLimitQueries() - 21) {
                Integer burned = [SELECT COUNT() FROM User WHERE Id = :UserInfo.getUserId()];
            }
            results = JobCreation.create(requests);
            Test.stopTest();
        }

        Assert.areEqual(JobCreation.TOO_MUCH, results[0].error, 'Refused rather than hitting the query limit');
        Assert.isNull(results[0].jobId, 'No job');
    }

    @IsTest
    static void refusesWriteBackToRecordsTheSenderCantEdit() {
        List<Account> accounts = accounts();
        List<JobCreation.Result> results;
        System.runAs(user(SENDER)) {
            results = JobCreation.create(requests('writeback', accounts));
        }

        for (JobCreation.Result result : results) {
            Assert.areEqual(JobCreation.CANT_SEND, result.error, 'Read access is not enough when the response writes back');
            Assert.isNull(result.jobId, 'No job');
        }
        Assert.areEqual(0, jobs().size(), 'Nothing queued');
    }

    @IsTest
    static void queuesWriteBackForRecordsTheSenderCanEdit() {
        grantAccountEdit();
        List<Account> accounts = accounts();
        List<JobCreation.Result> results;
        System.runAs(user(SENDER)) {
            results = JobCreation.create(requests('writeback', accounts));
        }

        for (JobCreation.Result result : results) {
            Assert.isNull(result.error, 'The sender owns and can edit the records: ' + result.error);
            Assert.isNotNull(result.jobId, 'Queued');
        }
    }

    @IsTest
    static void needsNoEditAccessWhenTheResponseIsMatchedOnAField() {
        List<JobCreation.Result> results;
        System.runAs(user(SENDER)) {
            results = JobCreation.create(requests('matched', new List<Account>{ accounts()[0] }));
        }

        Assert.isNull(results[0].error, 'The response picks its own records, not the sent one: ' + results[0].error);
        Assert.isNotNull(results[0].jobId, 'Queued');
    }

    @IsTest
    static void needsNoEditAccessWhenTheWriteBackIsForAnotherObject() {
        List<JobCreation.Result> results;
        System.runAs(user(SENDER)) {
            results = JobCreation.create(requests('otherobject', new List<Account>{ accounts()[0] }));
        }

        Assert.isNull(results[0].error, 'A Contact write-back never touches the Account: ' + results[0].error);
        Assert.isNotNull(results[0].jobId, 'Queued');
    }

    @IsTest
    static void tellsTheSenderWhenARecordWithABodyIsGone() {
        List<Account> accounts = accounts();
        // Deleted, so the user-mode read finds nothing whatever the org's sharing
        delete accounts[1];
        List<JobCreation.Result> results;
        System.runAs(user(SENDER)) {
            results = JobCreation.create(requests('orders', new List<Account>{ accounts[0], accounts[1] }));
        }

        Assert.isNull(results[0].error, 'The visible record goes ahead: ' + results[0].error);
        Assert.areEqual(JobCreation.CANT_SEND, results[1].error, 'The general message: it mustn\'t reveal which records exist');
        Assert.isNull(results[1].jobId, 'No job');
    }

    @IsTest
    static void hidesTemplateProblemsInBuiltBodiesFromTheSender() {
        List<JobCreation.Result> results;
        System.runAs(user(SENDER)) {
            results = JobCreation.create(requests('badjson', new List<Account>{ accounts()[0] }));
        }

        Assert.areEqual(JobCreation.CANT_SEND, results[0].error, 'MergeTemplate\'s per-record text describes the template');
        Assert.isNull(results[0].jobId, 'No job');
    }

    @IsTest
    static void jobsBelongToTheIntegrationUserOnceTheHandOffRecordedIt() {
        User runner = ReplayrTestAccess.runner();
        // As the work-waiting trigger records it
        upsert new Replayr_Settings__c(SetupOwnerId = UserInfo.getOrganizationId(), Hand_Off_User__c = runner.Id);
        List<JobCreation.Result> results;
        System.runAs(user(SENDER)) {
            results = JobCreation.create(requests('orders', new List<Account>{ accounts()[0] }));
        }

        Assert.areEqual(runner.Id, jobs().get(results[0].jobId).OwnerId, 'Not the sender: an ordinary user who may leave');
    }

    @IsTest
    static void theSenderOwnsJobsWhenTheRecordedUserIsNotTheIntegrationUser() {
        // As recorded when an admin names the wrong user in the subscriber config
        upsert new Replayr_Settings__c(SetupOwnerId = UserInfo.getOrganizationId(), Hand_Off_User__c = user(NON_SENDER).Id);
        List<JobCreation.Result> results;
        System.runAs(user(SENDER)) {
            results = JobCreation.create(requests('orders', new List<Account>{ accounts()[0] }));
        }

        Assert.areEqual(user(SENDER).Id, jobs().get(results[0].jobId).OwnerId, 'Not a user without the Integration User set');
    }

    @IsTest
    static void theSenderOwnsJobsWhenTheRecordedUserCantOwnThem() {
        // An Id that is no user here: as good as an inactive or Automated Process user
        upsert new Replayr_Settings__c(SetupOwnerId = UserInfo.getOrganizationId(), Hand_Off_User__c = 'not an id');
        List<JobCreation.Result> results;
        System.runAs(user(SENDER)) {
            results = JobCreation.create(requests('orders', new List<Account>{ accounts()[0] }));
        }

        Assert.isNull(results[0].error, 'Still sent: ' + results[0].error);
        Assert.areEqual(user(SENDER).Id, jobs().get(results[0].jobId).OwnerId, 'Falls back to the sender');
    }

    @IsTest
    static void refusesAnEndpointNotOpenedToFlowsAndTheApi() {
        System.runAs(ReplayrTestAccess.runner()) {
            Endpoint__c orders = [SELECT Id FROM Endpoint__c WHERE Key__c = 'orders'];
            orders.Allow_Sending__c = false;
            update orders;
        }
        List<JobCreation.Result> results;
        System.runAs(user(SENDER)) {
            results = JobCreation.create(requests('orders', new List<Account>{ accounts()[0] }));
        }

        Assert.areEqual(JobCreation.CANT_SEND, results[0].error, 'An admin hasn\'t chosen this endpoint for senders');
        Assert.isNull(results[0].jobId, 'No job');
    }

    @IsTest
    static void refusesNoRequestsOrTooMany() {
        List<JobCreation.Request> tooMany = new List<JobCreation.Request>();
        for (Integer i = 0; i <= JobCreation.MAX_REQUESTS; i++) {
            tooMany.add(new JobCreation.Request('orders', null));
        }
        System.runAs(user(SENDER)) {
            for (List<JobCreation.Request> requests : new List<List<JobCreation.Request>>{ null, new List<JobCreation.Request>(), tooMany }) {
                try {
                    JobCreation.create(requests);
                    Assert.fail('Expected a CreationException');
                } catch (JobCreation.CreationException e) {
                    Assert.isTrue(e.getMessage().contains('between 1 and 200'), e.getMessage());
                }
            }
        }
    }
}
