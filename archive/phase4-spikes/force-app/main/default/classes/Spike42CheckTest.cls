/**
 * Spike P4.2: runs Spike42Check as a Replayr Admin and as an Operator, each on a minimal profile, so without
 * "View Setup and Configuration". ConnectApi needs real org data, hence SeeAllData. Each test fails on purpose with
 * what that user could read, so the result shows in the test output.
 */
@IsTest(SeeAllData=true)
private class Spike42CheckTest {
    private static List<String> asHolderOf(String permissionSet) {
        return asHolderOf(permissionSet, false);
    }

    private static List<String> asHolderOf(String permissionSet, Boolean viewSetup) {
        Profile minimal = [SELECT Id FROM Profile WHERE Name = 'Minimum Access - Salesforce' LIMIT 1];
        User person = new User(
            Username = 'spike42.' + permissionSet + '.' + System.now().getTime() + '@example.com',
            LastName = 'Spike42',
            Email = 'spike42@example.com',
            Alias = 'spk42',
            ProfileId = minimal.Id,
            TimeZoneSidKey = 'GMT',
            LocaleSidKey = 'en_US',
            EmailEncodingKey = 'UTF-8',
            LanguageLocaleKey = 'en_US'
        );
        insert person;
        insert new PermissionSetAssignment(AssigneeId = person.Id, PermissionSetId = [SELECT Id FROM PermissionSet WHERE Name = :permissionSet].Id);
        if (viewSetup) {
            // View Setup needs View Roles too
            PermissionSet extra = new PermissionSet(Name = 'Spike42_View_Setup', Label = 'Spike42 View Setup', PermissionsViewSetup = true, PermissionsViewRoles = true);
            insert extra;
            insert new PermissionSetAssignment(AssigneeId = person.Id, PermissionSetId = extra.Id);
        }
        List<String> lines = new List<String>();
        System.runAs(person) {
            // Read as this person, as the button would: the integration user's assignments, then each probe alone
            Set<Id> integrationSets = new Set<Id>();
            try {
                for (PermissionSetAssignment a : [
                    SELECT PermissionSetId, PermissionSetGroupId
                    FROM PermissionSetAssignment
                    WHERE Assignee.Username LIKE 'replayr.integration.%'
                ]) {
                    integrationSets.add(a.PermissionSetId);
                }
                lines.add('PermissionSetAssignment of the integration user, as this person: ' + integrationSets.size() + ' sets');
            } catch (Exception e) {
                lines.add('PermissionSetAssignment error ' + e.getTypeName() + ': ' + e.getMessage());
            }
            lines.addAll(Spike42Check.run('Httpbin_API', integrationSets));
            try {
                lines.add('SOQL NamedCredential rows=' + [SELECT COUNT() FROM NamedCredential]);
            } catch (Exception e) {
                lines.add('SOQL NamedCredential error ' + e.getTypeName() + ': ' + e.getMessage());
            }
            try {
                lines.add(
                    'SOQL SetupEntityAccess on principals, alone: ' +
                    [SELECT COUNT() FROM SetupEntityAccess WHERE SetupEntityType = 'ExternalCredentialParameter' AND ParentId IN :integrationSets] +
                    ' rows'
                );
            } catch (Exception e) {
                lines.add('SOQL SetupEntityAccess error ' + e.getTypeName() + ': ' + e.getMessage());
            }
        }
        return lines;
    }

    @IsTest
    static void asAReplayrAdminWithoutViewSetup() {
        Assert.fail(String.join(asHolderOf('Replayr_Admin'), ' | '));
    }

    @IsTest
    static void asAReplayrAdminWithOnlyViewSetupAdded() {
        Assert.fail(String.join(asHolderOf('Replayr_Admin', true), ' | '));
    }

    @IsTest
    static void asAReplayrOperatorWithoutViewSetup() {
        Assert.fail(String.join(asHolderOf('Replayr_Operator'), ' | '));
    }
}
