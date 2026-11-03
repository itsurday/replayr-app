/**
 * Test helper: a dedicated test user holding Replayr's own permission sets. Tests create their data and run
 * the code under test as this user, so they never depend on who runs them: a clean org (the package build
 * org, CI, a customer sandbox) grants no access to Replayr's fields otherwise. Permission set assignments
 * only take effect inside System.runAs, so assigning them to the running user would not work.
 */
@IsTest
public with sharing class ReplayrTestAccess {
    private static final List<String> PERMISSION_SETS = new List<String>{ 'Replayr_Admin', 'Replayr_Integration_User' };

    /**
     * Creates the test user. Call first in every @TestSetup, then insert test data inside System.runAs(runner()).
     * @return the new user
     */
    public static User createRunner() {
        User runner = newUser(minimalProfileId(), username('runner'));
        // Setup-object DML in its own runAs block, so test data inserted afterwards avoids mixed DML
        System.runAs(new User(Id = UserInfo.getUserId())) {
            insert runner;
            List<PermissionSetAssignment> assignments = new List<PermissionSetAssignment>();
            for (PermissionSet permissionSet : [SELECT Id FROM PermissionSet WHERE Name IN :PERMISSION_SETS]) {
                assignments.add(new PermissionSetAssignment(AssigneeId = runner.Id, PermissionSetId = permissionSet.Id));
            }
            insert assignments;
        }
        return runner;
    }

    /**
     * @return the test user created by createRunner()
     */
    public static User runner() {
        String name = username('runner');
        return [SELECT Id FROM User WHERE Username = :name];
    }

    /**
     * Builds an unsaved user on a minimal profile, with no permission sets.
     * @param profileId the profile
     * @param username a username that is unique in this org's tests
     * @return the user
     */
    public static User newUser(Id profileId, String username) {
        return new User(
            Username = username,
            LastName = 'Replayr Test',
            Email = 'replayr.test@example.com',
            Alias = username.left(8),
            ProfileId = profileId,
            TimeZoneSidKey = 'GMT',
            LocaleSidKey = 'en_US',
            EmailEncodingKey = 'UTF-8',
            LanguageLocaleKey = 'en_US'
        );
    }

    /**
     * @return the Id of a profile that grants nothing to Replayr's objects
     */
    public static Id minimalProfileId() {
        return [
            SELECT Id
            FROM Profile
            WHERE Name IN ('Minimum Access - Salesforce', 'Standard User')
            ORDER BY Name
            LIMIT 1
        ]
        .Id;
    }

    /**
     * Usernames are unique across all orgs, so include this org's Id.
     * @param role a short label
     * @return a username unique to this org
     */
    public static String username(String role) {
        return 'replayr.' + role + '.' + UserInfo.getOrganizationId() + '@example.com.test';
    }
}
