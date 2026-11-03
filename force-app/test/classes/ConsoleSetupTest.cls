@IsTest
private with sharing class ConsoleSetupTest {
    private static final String OPERATOR = ReplayrTestAccess.username('operator');

    @TestSetup
    static void setup() {
        ReplayrTestAccess.createRunner();
        System.runAs(new User(Id = UserInfo.getUserId())) {
            User operator = ReplayrTestAccess.newUser(ReplayrTestAccess.minimalProfileId(), OPERATOR);
            insert operator;
            insert new PermissionSetAssignment(AssigneeId = operator.Id, PermissionSetId = [SELECT Id FROM PermissionSet WHERE Name = 'Replayr_Operator'].Id);
        }
        System.runAs(ReplayrTestAccess.runner()) {
            Provider__c acme = new Provider__c(Name = 'Acme', Named_Credential__c = 'Acme_API', Key__c = 'acme');
            Provider__c billing = new Provider__c(Name = 'Billing', Named_Credential__c = 'Billing_API');
            insert new List<Provider__c>{ billing, acme };
            insert new List<Endpoint__c>{
                new Endpoint__c(Name = 'Orders', Provider__c = acme.Id, Method__c = 'POST', Path__c = '/orders', Key__c = 'acme-orders', Allow_Sending__c = true),
                new Endpoint__c(Name = 'Items', Provider__c = acme.Id, Method__c = 'GET', Path__c = '/items', Retry_Safe__c = true)
            };
        }
    }

    private static User operator() {
        return [SELECT Id FROM User WHERE Username = :OPERATOR];
    }

    @IsTest
    static void listsProvidersAndTheirEndpointsByName() {
        ConsoleSetup.Setup shown;
        System.runAs(operator()) {
            shown = ConsoleSetup.providers();
        }

        Assert.areEqual(2, shown.providers.size(), 'Both providers');
        Assert.isFalse(shown.cut, 'Nothing cut');
        ConsoleSetup.ProviderRow acme = shown.providers[0];
        Assert.areEqual('Acme', acme.name, 'By name');
        Assert.areEqual('Acme_API', acme.namedCredential, 'Its Named Credential');
        Assert.areEqual('acme', acme.key, 'Its key');
        Assert.areEqual(2, acme.endpoints.size(), 'Its endpoints');
        Assert.areEqual('Items', acme.endpoints[0].name, 'Endpoints by name');
        Assert.isTrue(acme.endpoints[0].retrySafe, 'Retry-safe shown');
        Assert.areEqual('POST', acme.endpoints[1].method, 'Method shown');
        Assert.isTrue(acme.endpoints[1].allowSending, 'Open to flows shown');
        Assert.areEqual(0, shown.providers[1].endpoints.size(), 'A provider with no endpoints yet');
    }

    @IsTest
    static void offersNewOnlyToThoseWhoMayCreate() {
        ConsoleSetup.Setup asOperator;
        System.runAs(operator()) {
            asOperator = ConsoleSetup.providers();
        }
        ConsoleSetup.Setup asAdmin;
        System.runAs(ReplayrTestAccess.runner()) {
            asAdmin = ConsoleSetup.providers();
        }

        Assert.isFalse(asOperator.canCreateProviders, 'Operators view setup only');
        Assert.isFalse(asOperator.canCreateEndpoints, 'Operators view setup only');
        Assert.isTrue(asAdmin.canCreateProviders, 'Admins create providers');
        Assert.isTrue(asAdmin.canCreateEndpoints, 'Admins create endpoints');
    }

    @IsTest
    static void refusesUsersWithoutReplayrAdminOrOperator() {
        User nobody = ReplayrTestAccess.newUser(ReplayrTestAccess.minimalProfileId(), ReplayrTestAccess.username('nobody'));
        System.runAs(new User(Id = UserInfo.getUserId())) {
            insert nobody;
        }
        System.runAs(nobody) {
            try {
                ConsoleSetup.providers();
                Assert.fail('Expected AuraHandledException');
            } catch (AuraHandledException e) {
                Assert.isTrue(e.getMessage().contains('Replayr Operator'), e.getMessage());
            }
        }
    }
}
