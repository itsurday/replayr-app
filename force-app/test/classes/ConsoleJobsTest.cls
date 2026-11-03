@IsTest
private with sharing class ConsoleJobsTest {
    private static final String OPERATOR = ReplayrTestAccess.username('operator');
    // A provider's own masked name, not one of Redactor's built-in names
    private static final String MASKED_NAME = 'acme_ref';
    private static final String MASKED_VALUE = '9341';
    // Any Id: the calls it is used in are refused first. Looked up before System.runAs, as the user may not query
    private static Id someId;

    @TestSetup
    static void setup() {
        ReplayrTestAccess.createRunner();
        System.runAs(new User(Id = UserInfo.getUserId())) {
            User operator = ReplayrTestAccess.newUser(ReplayrTestAccess.minimalProfileId(), OPERATOR);
            insert operator;
            insert new PermissionSetAssignment(AssigneeId = operator.Id, PermissionSetId = [SELECT Id FROM PermissionSet WHERE Name = 'Replayr_Operator'].Id);
        }
        System.runAs(ReplayrTestAccess.runner()) {
            Provider__c provider = new Provider__c(Name = 'Acme', Named_Credential__c = 'Test_API', Masked_Names__c = MASKED_NAME);
            insert provider;
            insert new List<Endpoint__c>{
                new Endpoint__c(Name = 'Orders', Provider__c = provider.Id, Method__c = 'POST', Path__c = '/orders'),
                new Endpoint__c(Name = 'Items', Provider__c = provider.Id, Method__c = 'PUT', Path__c = '/items')
            };
        }
    }

    private static Id endpointNamed(String name) {
        return [SELECT Id FROM Endpoint__c WHERE Name = :name].Id;
    }

    private static Job__c newJob(Id endpointId, String status, Boolean retrySafe) {
        return new Job__c(Endpoint__c = endpointId, Status__c = status, Method__c = 'POST', Path__c = '/orders', Retry_Safe__c = retrySafe, Attempts__c = 1);
    }

    // System mode: people can't set Test Run, Not Replayable or the request body
    private static void save(List<Job__c> jobs) {
        System.runAs(ReplayrTestAccess.runner()) {
            Database.insert(jobs, true, AccessLevel.SYSTEM_MODE);
        }
    }

    private static ConsoleJobs.JobQuery query(String filter, Id endpointId, Boolean includeTestRuns) {
        ConsoleJobs.JobQuery query = new ConsoleJobs.JobQuery();
        query.filter = filter;
        query.endpointId = endpointId;
        query.includeTestRuns = includeTestRuns;
        return query;
    }

    private static User operator() {
        return [SELECT Id FROM User WHERE Username = :OPERATOR];
    }

    private static void assertRefused(String expected, Callable action) {
        try {
            action.call(null, null);
            Assert.fail('Expected AuraHandledException');
        } catch (AuraHandledException e) {
            Assert.isTrue(e.getMessage().contains(expected), e.getMessage());
        }
    }

    // Lets assertRefused run each entry point
    private class EntryPoint implements Callable {
        final String name;
        EntryPoint(String name) {
            this.name = name;
        }
        public Object call(String action, Map<String, Object> args) {
            switch on name {
                when 'list' {
                    return ConsoleJobs.listJobs('all', null, false, null, null);
                }
                when 'detail' {
                    return ConsoleJobs.detail(someId);
                }
                when 'unknownFilter' {
                    return ConsoleJobs.listPage(query('everything', null, false));
                }
                when 'badOutcome' {
                    return ConsoleJobs.resolve(new List<Id>{ someId }, 'Queued', 'note');
                }
                when 'blankNote' {
                    return ConsoleJobs.resolve(new List<Id>{ someId }, 'Failed', ' ');
                }
                when 'halfCursor' {
                    ConsoleJobs.JobQuery half = query('all', null, false);
                    half.beforeCreated = System.now();
                    return ConsoleJobs.listPage(half);
                }
                when else {
                    return ConsoleJobs.replay(new List<Id>{ someId }, false);
                }
            }
        }
    }

    @IsTest
    static void refusesUsersWithoutReplayrAdminOrOperator() {
        User nobody = ReplayrTestAccess.newUser(ReplayrTestAccess.minimalProfileId(), ReplayrTestAccess.username('nobody'));
        System.runAs(new User(Id = UserInfo.getUserId())) {
            insert nobody;
        }
        someId = endpointNamed('Orders');
        System.runAs(nobody) {
            assertRefused('Replayr Operator', new EntryPoint('list'));
            assertRefused('Replayr Operator', new EntryPoint('detail'));
            // JobActions' own message, passed on
            assertRefused('permission', new EntryPoint('replay'));
        }
    }

    // The console's permission and read access to what the list shows, trimmed in one of two ways
    private static User trimmedUser(Boolean readsMaskedNames, Boolean seesAllProviders) {
        User trimmed = ReplayrTestAccess.newUser(ReplayrTestAccess.minimalProfileId(), ReplayrTestAccess.username('trimmed'));
        System.runAs(new User(Id = UserInfo.getUserId())) {
            insert trimmed;
            PermissionSet access = new PermissionSet(Name = 'Replayr_Test_Trimmed', Label = 'Replayr Test Trimmed');
            insert access;
            List<SObject> grants = new List<SObject>{
                new SetupEntityAccess(ParentId = access.Id, SetupEntityId = [SELECT Id FROM CustomPermission WHERE DeveloperName = :JobActions.PERMISSION].Id),
                new ObjectPermissions(ParentId = access.Id, SobjectType = String.valueOf(Job__c.SObjectType), PermissionsRead = true, PermissionsViewAllRecords = true),
                new ObjectPermissions(ParentId = access.Id, SobjectType = String.valueOf(Endpoint__c.SObjectType), PermissionsRead = true),
                new ObjectPermissions(ParentId = access.Id, SobjectType = String.valueOf(Provider__c.SObjectType), PermissionsRead = true, PermissionsViewAllRecords = seesAllProviders)
            };
            List<Schema.SObjectField> fields = new List<Schema.SObjectField>{
                Job__c.Status__c, Job__c.Attempts__c, Job__c.HTTP_Status__c, Job__c.Result__c, Job__c.Record_Id__c, Job__c.Retry_Safe__c,
                Job__c.Not_Replayable__c, Job__c.Test_Run__c, Job__c.Next_Attempt_At__c, Job__c.Endpoint__c
            };
            if (readsMaskedNames) {
                fields.add(Provider__c.Masked_Names__c);
            }
            for (Schema.SObjectField field : fields) {
                Schema.DescribeFieldResult describe = field.getDescribe();
                // Required fields are always readable and take no permission
                if (!describe.isPermissionable()) {
                    continue;
                }
                String objectName = String.valueOf(describe.getSObjectType());
                grants.add(new FieldPermissions(ParentId = access.Id, SobjectType = objectName, Field = objectName + '.' + describe.getName(), PermissionsRead = true));
            }
            insert grants;
            insert new PermissionSetAssignment(AssigneeId = trimmed.Id, PermissionSetId = access.Id);
        }
        save(new List<Job__c>{ newJob(endpointNamed('Orders'), 'Failed', true) });
        return trimmed;
    }

    @IsTest
    static void listsJobsForSomeoneWithJustEnoughAccess() {
        // The control for the two tests below: these grants alone are enough
        System.runAs(trimmedUser(true, true)) {
            Assert.areEqual(1, ConsoleJobs.listJobs('all', null, false, null, null).rows.size(), 'Listed through the console action');
        }
    }

    @IsTest
    static void failsClosedForSomeoneWhoCantReadTheMaskedNames() {
        System.runAs(trimmedUser(false, true)) {
            assertRefused('read jobs', new EntryPoint('list'));
        }
    }

    @IsTest
    static void failsClosedWhenSharingHidesTheProvider() {
        // Providers are Private: without View All the provider, and so its masked names, can't be read
        System.runAs(trimmedUser(true, false)) {
            assertRefused('read jobs', new EntryPoint('list'));
        }
    }

    @IsTest
    static void refusesAnUnknownFilterOrOutcome() {
        someId = endpointNamed('Orders');
        System.runAs(operator()) {
            assertRefused('Unknown filter', new EntryPoint('unknownFilter'));
            assertRefused('Unknown page', new EntryPoint('halfCursor'));
            // JobActions' own messages, passed on
            assertRefused('Succeeded or Failed', new EntryPoint('badOutcome'));
            assertRefused('Say why', new EntryPoint('blankNote'));
        }
    }

    @IsTest
    static void pagesThroughJobsNeedingAPersonNewestFirst() {
        Id orders = endpointNamed('Orders');
        List<Job__c> jobs = new List<Job__c>();
        for (Integer i = 0; i < 200; i++) {
            jobs.add(newJob(orders, i < 70 ? 'Outcome_Unknown' : i < 120 ? 'Dead' : 'Succeeded', true));
        }
        save(jobs);

        Set<Id> seen = new Set<Id>();
        List<Integer> pageSizes = new List<Integer>();
        System.runAs(operator()) {
            Test.startTest();
            ConsoleJobs.JobQuery next = query('needsPerson', null, false);
            ConsoleJobs.JobPage page = ConsoleJobs.listPage(next);
            while (true) {
                pageSizes.add(page.rows.size());
                for (ConsoleJobs.Row row : page.rows) {
                    Assert.isTrue(row.status == 'Outcome_Unknown' || row.status == 'Dead', row.status);
                    Assert.isTrue(seen.add(row.id), 'No job twice');
                }
                if (!page.hasMore) {
                    break;
                }
                ConsoleJobs.Row last = page.rows[page.rows.size() - 1];
                next.beforeCreated = last.createdDate;
                next.beforeId = last.id;
                page = ConsoleJobs.listPage(next);
            }
            Test.stopTest();
        }

        Assert.areEqual(120, seen.size(), 'Every job needing a person, once');
        Assert.areEqual(new List<Integer>{ ConsoleJobs.PAGE_SIZE, ConsoleJobs.PAGE_SIZE, 20 }, pageSizes, 'Pages of 50');
    }

    @IsTest
    static void filtersByEndpointAndLeavesTestRunsOutUnlessAsked() {
        Job__c order = newJob(endpointNamed('Orders'), 'Failed', true);
        Job__c item = newJob(endpointNamed('Items'), 'Failed', true);
        Job__c testRun = newJob(endpointNamed('Orders'), 'Failed', true);
        testRun.Test_Run__c = true;
        save(new List<Job__c>{ order, item, testRun });

        System.runAs(operator()) {
            List<ConsoleJobs.Row> rows = ConsoleJobs.listPage(query('failed', endpointNamed('Orders'), false)).rows;
            Assert.areEqual(1, rows.size(), 'Only Orders, no test run');
            Assert.areEqual(order.Id, rows[0].id, 'The real Orders job');
            Assert.areEqual('Orders', rows[0].endpoint, 'Endpoint name shown');
            Assert.areEqual('Failed', rows[0].statusLabel, 'Status label shown');

            Assert.areEqual(3, ConsoleJobs.listPage(query('all', null, true)).rows.size(), 'Test runs on request');
        }
    }

    @IsTest
    static void marksWhichJobsCanBeReplayed() {
        Job__c succeeded = newJob(endpointNamed('Orders'), 'Succeeded', true);
        Job__c queued = newJob(endpointNamed('Orders'), 'Queued', true);
        Job__c incomplete = newJob(endpointNamed('Orders'), 'Failed', true);
        incomplete.Not_Replayable__c = true;
        Job__c testRun = newJob(endpointNamed('Orders'), 'Succeeded', true);
        testRun.Test_Run__c = true;
        save(new List<Job__c>{ succeeded, queued, incomplete, testRun });

        Map<Id, Boolean> replayable = new Map<Id, Boolean>();
        System.runAs(operator()) {
            for (ConsoleJobs.Row row : ConsoleJobs.listPage(query('all', null, true)).rows) {
                replayable.put(row.id, row.replayable);
            }
        }

        Assert.isTrue(replayable.get(succeeded.Id), 'A finished job');
        Assert.isFalse(replayable.get(queued.Id), 'Not finished');
        Assert.isFalse(replayable.get(incomplete.Id), 'Its stored request is incomplete');
        Assert.isFalse(replayable.get(testRun.Id), 'A test run');
    }

    @IsTest
    static void withholdsBodiesItCantMask() {
        Job__c xml = newJob(endpointNamed('Orders'), 'Failed', true);
        xml.Request_Body__c = '<order><' + MASKED_NAME + '>' + MASKED_VALUE + '</' + MASKED_NAME + '></order>';
        Job__c nested = newJob(endpointNamed('Orders'), 'Failed', true);
        nested.Request_Body__c = '{"payload": "{\\"' + MASKED_NAME + '\\": \\"' + MASKED_VALUE + '\\"}"}';
        save(new List<Job__c>{ xml, nested });

        System.runAs(ReplayrTestAccess.runner()) {
            for (Job__c job : new List<Job__c>{ xml, nested }) {
                ConsoleJobs.Detail detail = ConsoleJobs.detail(job.Id);
                Assert.isNull(detail.requestBody, 'Withheld');
                Assert.isNotNull(detail.requestBodyWithheld, 'With the reason');
                Assert.isFalse(JSON.serialize(detail).contains(MASKED_VALUE), 'Nowhere');
            }
        }
        Assert.isTrue(ConsoleJobs.isMaskable(null), 'No body: nothing to hide');
        Assert.isTrue(ConsoleJobs.isMaskable('[{"a": [1, "x"]}]'), 'Plain JSON');
    }

    @IsTest
    static void masksWhatItShowsAndShowsBodiesOnlyToAdmins() {
        Job__c job = newJob(endpointNamed('Orders'), 'Failed', true);
        job.Path__c = '/orders?' + MASKED_NAME + '=' + MASKED_VALUE + '&ok=1';
        job.Result__c = 'HTTP 400: ' + MASKED_NAME + '=' + MASKED_VALUE;
        job.Request_Body__c = '{"' + MASKED_NAME + '": "' + MASKED_VALUE + '", "name": "Acme"}';
        save(new List<Job__c>{ job });
        System.runAs(ReplayrTestAccess.runner()) {
            insert JobLogs.newLog(job.Id, 'Failed', 400, 'Rejected ' + MASKED_NAME + '=' + MASKED_VALUE, 120L);
        }

        ConsoleJobs.Detail asOperator;
        System.runAs(operator()) {
            asOperator = ConsoleJobs.detail(job.Id);
        }
        ConsoleJobs.Detail asAdmin;
        System.runAs(ReplayrTestAccess.runner()) {
            asAdmin = ConsoleJobs.detail(job.Id);
        }

        String shown = JSON.serialize(asOperator) + JSON.serialize(asAdmin);
        Assert.isFalse(shown.contains(MASKED_VALUE), 'Masked everywhere: ' + shown);
        Assert.isTrue(asOperator.path.contains('ok=1'), 'The rest of the path kept: ' + asOperator.path);
        Assert.areEqual(1, asOperator.attempts.size(), 'The attempt shown');
        Assert.areEqual(400, asOperator.attempts[0].httpStatus, 'With its status');
        Assert.isFalse(asOperator.requestBodyReadable, 'Operators may not read request bodies');
        Assert.isNull(asOperator.requestBody, 'So none is returned');
        Assert.isTrue(asAdmin.requestBodyReadable, 'Admins may');
        Assert.isTrue(asAdmin.requestBody.contains('"name": "Acme"'), 'Masked, not hidden: ' + asAdmin.requestBody);
    }

    @IsTest
    static void saysWhenAJobCantBeFound() {
        Job__c job = newJob(endpointNamed('Orders'), 'Failed', true);
        save(new List<Job__c>{ job });
        System.runAs(ReplayrTestAccess.runner()) {
            delete job;
        }

        System.runAs(operator()) {
            try {
                ConsoleJobs.detail(job.Id);
                Assert.fail('Expected AuraHandledException');
            } catch (AuraHandledException e) {
                Assert.isTrue(e.getMessage().startsWith('Job not found'), e.getMessage());
            }
        }
    }

    @IsTest
    static void replaysAndResolvesThroughJobActions() {
        Job__c safe = newJob(endpointNamed('Orders'), 'Failed', true);
        Job__c risky = newJob(endpointNamed('Orders'), 'Failed', false);
        Job__c unknown = newJob(endpointNamed('Orders'), 'Outcome_Unknown', false);
        save(new List<Job__c>{ safe, risky, unknown });

        List<ConsoleJobs.ActionResult> replayed;
        List<ConsoleJobs.ActionResult> resolved;
        System.runAs(operator()) {
            replayed = ConsoleJobs.replay(new List<Id>{ safe.Id, risky.Id }, false);
            resolved = ConsoleJobs.resolve(new List<Id>{ unknown.Id }, 'Failed', 'Checked with Acme: never arrived.');
        }

        Assert.isTrue(replayed[0].done, replayed[0].message);
        Assert.isFalse(replayed[1].done, 'Not Retry-safe and not confirmed');
        Assert.areEqual(JobActions.DUPLICATE_RISK, replayed[1].message, 'The risk is the message');
        Assert.isTrue(resolved[0].done, resolved[0].message);
        System.runAs(ReplayrTestAccess.runner()) {
            Assert.areEqual('Queued', [SELECT Status__c FROM Job__c WHERE Id = :safe.Id].Status__c, 'Replayed');
            Assert.areEqual('Failed', [SELECT Status__c FROM Job__c WHERE Id = :unknown.Id].Status__c, 'Resolved');
        }
    }
}
