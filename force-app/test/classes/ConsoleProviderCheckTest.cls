@IsTest
private with sharing class ConsoleProviderCheckTest {
    // A principal Id that exists nowhere (key prefix 0pu)
    private static final Id PRINCIPAL = Id.valueOf('0pu' + '0'.repeat(11) + '1');
    // The customer's own set granting Read on User External Credential (setup())
    private static final String READ_SET = 'Replayr_Test_UEC_Read';

    // Stands in for ConnectApi and the principal-access query, which need real credentials
    private class FakePlatform extends ConsoleProviderCheck.Platform {
        Exception failure;
        Boolean unreadable = false;
        ConsoleProviderCheck.Credential credential = new ConsoleProviderCheck.Credential();
        ConsoleProviderCheck.ExternalCredentialInfo info = new ConsoleProviderCheck.ExternalCredentialInfo();
        // The permission sets that grant the principal; null for none
        Set<Id> granting;

        FakePlatform() {
            credential.calloutsEnabled = true;
            credential.externalCredentials.add('Acme_Auth');
            info.principalIds.add(PRINCIPAL);
        }

        public override ConsoleProviderCheck.Credential namedCredential(String name) {
            if (failure != null) {
                throw failure;
            }
            return credential;
        }

        public override ConsoleProviderCheck.ExternalCredentialInfo externalCredential(String name) {
            if (unreadable) {
                throw new ConsoleProviderCheck.NotFoundException();
            }
            return info;
        }

        public override Set<Id> setsGranting(Set<Id> principalIds, Set<Id> permissionSetIds) {
            Set<Id> granted = new Set<Id>(permissionSetIds);
            granted.retainAll(granting ?? new Set<Id>());
            return granted;
        }
    }

    @TestSetup
    static void setup() {
        User runner = ReplayrTestAccess.createRunner();
        System.runAs(new User(Id = UserInfo.getUserId())) {
            // The customer's own set: Replayr's Integration User set can't carry this Read once packaged
            PermissionSet readSet = new PermissionSet(Name = READ_SET, Label = 'Replayr Test UEC Read');
            insert readSet;
            insert new ObjectPermissions(ParentId = readSet.Id, SobjectType = 'UserExternalCredential', PermissionsRead = true);
            insert new PermissionSetAssignment(AssigneeId = runner.Id, PermissionSetId = readSet.Id);
        }
        System.runAs(runner) {
            insert new Provider__c(Name = 'Acme', Named_Credential__c = 'Acme_API');
        }
    }

    private static Id integrationSet() {
        return [SELECT Id FROM PermissionSet WHERE Name = :WorkWaiting.INTEGRATION_SET].Id;
    }

    private static Id readSet() {
        return [SELECT Id FROM PermissionSet WHERE Name = :READ_SET].Id;
    }

    // The fake grants the principal through Replayr's Integration User set, which every integration user holds
    private static FakePlatform granted() {
        FakePlatform fake = new FakePlatform();
        fake.granting = new Set<Id>{ integrationSet() };
        return fake;
    }

    private static ConsoleProviderCheck.Result check(FakePlatform fake) {
        ConsoleProviderCheck.platform = fake;
        ConsoleProviderCheck.Result result;
        System.runAs(ReplayrTestAccess.runner()) {
            result = ConsoleProviderCheck.check([SELECT Id FROM Provider__c LIMIT 1].Id);
        }
        return result;
    }

    private static String states(ConsoleProviderCheck.Result result) {
        List<String> states = new List<String>();
        for (ConsoleProviderCheck.Finding finding : result.findings) {
            states.add(finding.state);
        }
        return String.join(states, ',');
    }

    private static String texts(ConsoleProviderCheck.Result result) {
        List<String> texts = new List<String>();
        for (ConsoleProviderCheck.Finding finding : result.findings) {
            texts.add(finding.text);
        }
        return String.join(texts, ' | ');
    }

    @IsTest
    static void passesWhenEverythingIsInPlace() {
        ConsoleProviderCheck.Result result = check(granted());

        Assert.isTrue(result.checked, 'Checked');
        Assert.areEqual('passed,passed,passed,passed', states(result), texts(result));
        Assert.isTrue(texts(result).contains('Named Credential "Acme_API" exists.'), texts(result));
    }

    @IsTest
    static void saysWhoCantRunItWithoutViewSetupAndReadsNothingElse() {
        FakePlatform fake = granted();
        fake.failure = new ConsoleProviderCheck.SetupAccessException();
        ConsoleProviderCheck.platform = fake;
        Id providerId = [SELECT Id FROM Provider__c LIMIT 1].Id;
        ConsoleProviderCheck.Result result;
        Integer queries;
        System.runAs(ReplayrTestAccess.runner()) {
            Integer before = Limits.getQueries();
            result = ConsoleProviderCheck.check(providerId);
            queries = Limits.getQueries() - before;
        }

        Assert.isFalse(result.checked, 'Nothing checked');
        Assert.areEqual(ConsoleProviderCheck.NEEDS_VIEW_SETUP, result.message, 'Says what is needed');
        Assert.areEqual(0, result.findings.size(), 'No findings');
        // Only the provider itself: who the integration users are, and their permissions, are never read
        Assert.areEqual(1, queries, 'Queries before the View Setup gate');
    }

    @IsTest
    static void oneUnreadableExternalCredentialCostsOnlyItsOwnFinding() {
        FakePlatform fake = granted();
        fake.unreadable = true;

        ConsoleProviderCheck.Result result = check(fake);

        Assert.areEqual('passed,passed,passed,notChecked', states(result), texts(result));
        Assert.isTrue(texts(result).contains('couldn\'t be read'), texts(result));
    }


    @IsTest
    static void saysWhenTheNamedCredentialIsMissingOrHidden() {
        FakePlatform fake = granted();
        fake.failure = new ConsoleProviderCheck.NotFoundException();

        ConsoleProviderCheck.Result result = check(fake);

        Assert.areEqual('failed', states(result), texts(result));
        Assert.isTrue(texts(result).contains('was found, or you can\'t access it'), 'Both possibilities named: ' + texts(result));
    }

    @IsTest
    static void namesWhatIsWrongAndWhoLacksAccess() {
        FakePlatform fake = new FakePlatform();
        fake.credential.calloutsEnabled = false;

        ConsoleProviderCheck.Result result = check(fake);

        Assert.areEqual('passed,failed,passed,failed', states(result), texts(result));
        Assert.isTrue(texts(result).contains('tick Enabled for Callouts'), texts(result));
        String runner = [SELECT Name FROM User WHERE Id = :ReplayrTestAccess.runner().Id].Name;
        Assert.isTrue(texts(result).contains(runner), 'Names the integration user without access: ' + texts(result));
    }

    @IsTest
    static void cantCheckPrincipalsOfAnOlderNamedCredential() {
        FakePlatform fake = granted();
        fake.credential.externalCredentials.clear();

        ConsoleProviderCheck.Result result = check(fake);

        Assert.areEqual('passed,passed,passed,notChecked', states(result), texts(result));
    }

    @IsTest
    static void saysAnOAuthCredentialMayStillNeedAuthenticating() {
        FakePlatform fake = granted();
        fake.info.needsAuthentication = true;

        ConsoleProviderCheck.Result result = check(fake);

        Assert.areEqual('passed,passed,passed,passed,notChecked', states(result), texts(result));
        Assert.isTrue(texts(result).contains('checks permissions only'), texts(result));
    }

    @IsTest
    static void failsAnExternalCredentialWithNoPrincipal() {
        FakePlatform fake = granted();
        fake.info.principalIds.clear();

        ConsoleProviderCheck.Result result = check(fake);

        Assert.areEqual('passed,passed,passed,failed', states(result), texts(result));
        Assert.isTrue(texts(result).contains('has no principal'), texts(result));
    }

    @IsTest
    static void looksThroughPermissionSetGroups() {
        // An integration user who holds the Integration User set only through a group
        User grouped = ReplayrTestAccess.newUser(ReplayrTestAccess.minimalProfileId(), ReplayrTestAccess.username('grouped'));
        System.runAs(new User(Id = UserInfo.getUserId())) {
            insert grouped;
            PermissionSetGroup bundle = new PermissionSetGroup(DeveloperName = 'Replayr_Test_Bundle', MasterLabel = 'Replayr Test Bundle');
            insert bundle;
            insert new List<PermissionSetGroupComponent>{
                new PermissionSetGroupComponent(PermissionSetGroupId = bundle.Id, PermissionSetId = integrationSet()),
                new PermissionSetGroupComponent(PermissionSetGroupId = bundle.Id, PermissionSetId = readSet())
            };
            Test.calculatePermissionSetGroup(bundle.Id);
            insert new PermissionSetAssignment(AssigneeId = grouped.Id, PermissionSetGroupId = bundle.Id);
        }

        ConsoleProviderCheck.Result result = check(granted());

        // Without looking into the group, its member would have no access to the principal nor Read on the object
        Assert.areEqual('passed,passed,passed,passed', states(result), texts(result));
    }

    @IsTest
    static void aSubscribersOwnCredentialLeavesItsDetailsToSetup() {
        // A subscriber's own credential, which package code finds only by SOQL (beta check B8)
        FakePlatform fake = granted();
        fake.credential.summaryOnly = true;
        fake.credential.calloutsEnabled = false;
        fake.credential.externalCredentials.clear();

        ConsoleProviderCheck.Result result = check(fake);

        // Exists, the integration user's Read, then one finding for what only Setup shows (not "callouts disabled")
        Assert.areEqual('passed,passed,notChecked', states(result), texts(result));
        Assert.isTrue(texts(result).contains('enabled for callouts'), texts(result));
        Assert.isTrue(texts(result).contains('Allowed Namespaces for Callouts'), texts(result));
    }

    @IsTest
    static void theRealSubscriberLookupNeedsViewSetupThenFindsNoUnknownCredential() {
        ConsoleProviderCheck.Platform real = new ConsoleProviderCheck.Platform();
        // The runner's minimal profile and Replayr sets don't grant View Setup: refused before any query
        System.runAs(ReplayrTestAccess.runner()) {
            Assert.isFalse(real.holdsViewSetup(), 'The runner lacks View Setup');
            try {
                real.subscriberOwn('Replayr_Test_No_Such_Credential');
                Assert.fail('Expected SetupAccessException');
            } catch (ConsoleProviderCheck.SetupAccessException e) {
                Assert.isInstanceOfType(e, ConsoleProviderCheck.SetupAccessException.class, 'Refused for lack of View Setup');
            }
        }
        // The org admin running the tests holds it; only the found path needs a real credential (beta check B8)
        Assert.isTrue(real.holdsViewSetup(), 'The running admin holds View Setup');
        try {
            real.subscriberOwn('Replayr_Test_No_Such_Credential');
            Assert.fail('Expected NotFoundException');
        } catch (ConsoleProviderCheck.NotFoundException e) {
            Assert.isInstanceOfType(e, ConsoleProviderCheck.NotFoundException.class, 'An unknown name is not found');
        }
    }

    @IsTest
    static void failsAnIntegrationUserWhoCantReadUserExternalCredentials() {
        // Holds Replayr's Integration User set but not the customer's Read set
        User bare = ReplayrTestAccess.newUser(ReplayrTestAccess.minimalProfileId(), ReplayrTestAccess.username('bare'));
        System.runAs(new User(Id = UserInfo.getUserId())) {
            insert bare;
            insert new PermissionSetAssignment(AssigneeId = bare.Id, PermissionSetId = integrationSet());
        }

        ConsoleProviderCheck.Result result = check(granted());

        Assert.areEqual('passed,passed,failed,passed', states(result), texts(result));
        Assert.isTrue(texts(result).contains('Give it Read on User External Credentials'), texts(result));
    }

    // The real ConnectApi calls can't run here: ConnectApi refuses tests without SeeAllData, and CI orgs have no
    // credentials. They were run against real credentials in replayr-dev
    @IsTest
    static void theRealPrincipalQueryFindsNoAccessToAnUnknownPrincipal() {
        ConsoleProviderCheck.Platform real = new ConsoleProviderCheck.Platform();
        Set<Id> sets = new Set<Id>{ integrationSet() };
        Id adminSet = [SELECT Id FROM PermissionSet WHERE Name = 'Replayr_Admin'].Id;
        Id checkClass = [SELECT Id FROM ApexClass WHERE Name = 'ConsoleProviderCheck'].Id;
        System.runAs(ReplayrTestAccess.runner()) {
            try {
                real.namedCredential('Replayr_Test_No_Such_Credential');
                Assert.fail('Expected an exception');
            } catch (UnsupportedOperationException e) {
                Assert.isTrue(e.getMessage().contains('SeeAllData'), e.getMessage());
            }
            Assert.areEqual(0, real.setsGranting(new Set<Id>{ PRINCIPAL }, sets).size(), 'No access to an unknown principal');
            // The positive path, on an access record that exists everywhere: the Admin set's access to this class
            Assert.areEqual(new Set<Id>{ adminSet }, real.setsGranting(new Set<Id>{ checkClass }, new Set<Id>{ adminSet, sets.iterator().next() }), 'The granting set found');
        }
    }

    @IsTest
    static void refusesUsersWithoutReplayrAdminOrOperatorAndUnknownProviders() {
        User nobody = ReplayrTestAccess.newUser(ReplayrTestAccess.minimalProfileId(), ReplayrTestAccess.username('nobody'));
        System.runAs(new User(Id = UserInfo.getUserId())) {
            insert nobody;
        }
        Id providerId = [SELECT Id FROM Provider__c LIMIT 1].Id;
        ConsoleProviderCheck.platform = granted();
        System.runAs(nobody) {
            try {
                ConsoleProviderCheck.check(providerId);
                Assert.fail('Expected AuraHandledException');
            } catch (AuraHandledException e) {
                Assert.isTrue(e.getMessage().contains('Replayr Operator'), e.getMessage());
            }
        }
        System.runAs(ReplayrTestAccess.runner()) {
            delete [SELECT Id FROM Provider__c];
            try {
                ConsoleProviderCheck.check(providerId);
                Assert.fail('Expected AuraHandledException');
            } catch (AuraHandledException e) {
                Assert.isTrue(e.getMessage().startsWith('Provider not found'), e.getMessage());
            }
        }
    }
}
