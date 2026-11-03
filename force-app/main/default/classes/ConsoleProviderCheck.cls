/**
 * The console's "check this provider" button (decisions.md, ADR-023 and spike P4.2): is the provider's
 * Named Credential there, are its callouts enabled, and can Replayr's integration user use it (Read on
 * UserExternalCredential, and access to a principal of each External Credential, through a permission set held
 * directly or in a group). Reading credentials needs "View Setup and Configuration": anyone without it is told so,
 * and nothing is checked. It reads only; each finding is a plain sentence, passed, failed or not checkable.
 */
public with sharing class ConsoleProviderCheck {
    public static final String PASSED = 'passed';
    public static final String FAILED = 'failed';
    public static final String NOT_CHECKED = 'notChecked';
    @TestVisible
    private static final String NEEDS_VIEW_SETUP =
        'Checking a provider needs the View Setup and Configuration permission. Ask a Salesforce administrator to run the check.';
    private static final String USER_EXTERNAL_CREDENTIAL = 'UserExternalCredential';

    // The platform calls, replaced in tests: ConnectApi works only on real org data
    @TestVisible
    private static Platform platform = new Platform();

    /** One finding. */
    public class Finding {
        @AuraEnabled
        public String state;
        @AuraEnabled
        public String text;

        Finding(String state, String text) {
            this.state = state;
            this.text = text;
        }
    }

    /** What the check found. */
    public class Result {
        /** False when nothing could be checked; message says why. */
        @AuraEnabled
        public Boolean checked = false;
        @AuraEnabled
        public String message;
        @AuraEnabled
        public List<Finding> findings = new List<Finding>();
    }

    /** A Named Credential as the check needs it. */
    public class Credential {
        public Boolean calloutsEnabled = false;
        public List<String> externalCredentials = new List<String>();
        /** A subscriber's own credential, found only by SOQL: its callout switch and External Credentials are unknown. */
        public Boolean summaryOnly = false;
    }

    /** An External Credential: its principals, and whether a login or token is needed besides the permission. */
    public class ExternalCredentialInfo {
        public Set<Id> principalIds = new Set<Id>();
        public Boolean needsAuthentication = false;
    }

    /** The person lacks View Setup and Configuration. */
    public class SetupAccessException extends Exception {
    }

    /** No such Named Credential, or the person can't access it (ConnectApi doesn't say which). */
    public class NotFoundException extends Exception {
    }

    /** ConnectApi and the principal-access query, behind one seam so tests can stand in for them. */
    // with sharing: its query runs as the person checking, like the rest of the check
    public virtual with sharing class Platform {
        public virtual Credential namedCredential(String name) {
            try {
                ConnectApi.NamedCredential found = ConnectApi.NamedCredentials.getNamedCredential(name);
                Credential credential = new Credential();
                // Compared as the platform's own values, never as text (String.valueOf of the protocol is "OAuth")
                credential.calloutsEnabled = found.calloutStatus == ConnectApi.CalloutStatus.Enabled;
                for (ConnectApi.ExternalCredential ref : found.externalCredentials) {
                    credential.externalCredentials.add(ref.developerName);
                }
                return credential;
            } catch (NoAccessException e) {
                throw new SetupAccessException();
            } catch (ConnectApi.ConnectApiException e) {
                // From package code ConnectApi sees only Replayr's namespace, by name or in its list, so a
                // subscriber's own credential is missed (beta check B8); SOQL names the namespace itself
                return subscriberOwn(name);
            }
        }

        @TestVisible
        private Credential subscriberOwn(String name) {
            // The View Setup gate, explicit here: ConnectApi may have said "not found" rather than "no access"
            // for a credential it can't see, and the check reads integration users' access after this
            if (!holdsViewSetup()) {
                throw new SetupAccessException();
            }
            List<NamedCredential> found;
            try {
                found = [SELECT Id FROM NamedCredential WHERE DeveloperName = :name AND NamespacePrefix = NULL WITH USER_MODE LIMIT 1];
            } catch (QueryException e) {
                throw new NotFoundException();
            }
            if (found.isEmpty()) {
                throw new NotFoundException();
            }
            Credential credential = new Credential();
            credential.summaryOnly = true;
            return credential;
        }

        // A profile's permissions are in its own permission set, so this covers profiles and permission sets.
        // Fails closed: without View Setup the query itself is refused
        @TestVisible
        private Boolean holdsViewSetup() {
            try {
                return [
                        SELECT COUNT()
                        FROM PermissionSetAssignment
                        WHERE AssigneeId = :UserInfo.getUserId() AND PermissionSet.PermissionsViewSetup = TRUE
                        WITH USER_MODE
                    ] > 0;
            } catch (SecurityException e) {
                return false;
            } catch (QueryException e) {
                return false;
            }
        }

        public virtual ExternalCredentialInfo externalCredential(String name) {
            ConnectApi.ExternalCredential found = ConnectApi.NamedCredentials.getExternalCredential(name);
            ExternalCredentialInfo info = new ExternalCredentialInfo();
            info.needsAuthentication = found.authenticationProtocol == ConnectApi.CredentialAuthenticationProtocol.Oauth;
            for (ConnectApi.ExternalCredentialPrincipal principal : found.principals) {
                info.principalIds.add(principal.id);
                info.needsAuthentication |= principal.principalType == ConnectApi.CredentialPrincipalType.PerUserPrincipal;
            }
            return info;
        }

        // The permission sets, among those given, with access to any of the principals
        public virtual Set<Id> setsGranting(Set<Id> principalIds, Set<Id> permissionSetIds) {
            Set<Id> granting = new Set<Id>();
            for (SetupEntityAccess access : [
                SELECT ParentId
                FROM SetupEntityAccess
                WHERE SetupEntityId IN :principalIds AND ParentId IN :permissionSetIds
                WITH SYSTEM_MODE
            ]) {
                granting.add(access.ParentId);
            }
            return granting;
        }
    }

    /**
     * Checks one provider.
     * @param providerId the provider
     * @return the findings, or why nothing could be checked
     */
    @AuraEnabled
    public static Result check(Id providerId) {
        if (!FeatureManagement.checkPermission(JobActions.PERMISSION)) {
            throw ConsoleError.of('You need the Replayr Admin or Replayr Operator permission set.');
        }
        List<Provider__c> providers = [SELECT Named_Credential__c FROM Provider__c WHERE Id = :providerId WITH USER_MODE];
        if (providers.isEmpty()) {
            throw ConsoleError.of('Provider not found, or you can\'t see it.');
        }
        try {
            return checkCredential(providers[0].Named_Credential__c);
        } catch (Exception e) {
            // Only the type: a query error can name fields and objects
            throw ConsoleError.of('Replayr couldn\'t check this provider (' + e.getTypeName() + ').');
        }
    }

    private static Result checkCredential(String name) {
        Result result = new Result();
        Credential credential;
        // Must stay first: this read is the View Setup gate. Without that permission it fails here, before any of
        // the system-mode reads below of who the integration users are and what they may do
        try {
            credential = platform.namedCredential(name);
        } catch (SetupAccessException e) {
            result.message = NEEDS_VIEW_SETUP;
            return result;
        } catch (NotFoundException e) {
            result.checked = true;
            result.findings.add(
                new Finding(FAILED, 'No Named Credential "' + name + '" was found, or you can\'t access it. Check the API name on this provider, and that it exists in Setup, Named Credentials.')
            );
            return result;
        }
        result.checked = true;
        result.findings.add(new Finding(PASSED, 'Named Credential "' + name + '" exists.'));
        if (credential.summaryOnly) {
            // Its callout switch can't be read either; checkIntegrationUsers says what to check in Setup
            checkIntegrationUsers(credential, result);
            return result;
        }
        result.findings.add(
            credential.calloutsEnabled
                ? new Finding(PASSED, 'Callouts are enabled.')
                : new Finding(FAILED, 'Callouts are not enabled: in Setup, Named Credentials, edit "' + name + '" and tick Enabled for Callouts.')
        );
        checkIntegrationUsers(credential, result);
        return result;
    }

    // Replayr's background work runs as the integration user, so each one must be able to use the credential
    private static void checkIntegrationUsers(Credential credential, Result result) {
        Set<Id> users = PermissionSetHolders.of(WorkWaiting.INTEGRATION_SET, null);
        if (users.isEmpty()) {
            result.findings.add(new Finding(FAILED, 'No active user holds the Replayr Integration User permission set, so nothing can call this provider.'));
            return;
        }
        Map<Id, Set<Id>> setsByUser = permissionSetsOf(users);
        Set<Id> allSets = new Set<Id>();
        for (Set<Id> sets : setsByUser.values()) {
            allSets.addAll(sets);
        }
        result.findings.add(verdict(missing(setsByUser, readersOfUserExternalCredential(allSets)), 'can read User External Credentials (needed to call out)', 'Give it Read on User External Credentials, in a permission set it holds.'));
        if (credential.summaryOnly) {
            result.findings.add(
                new Finding(
                    NOT_CHECKED,
                    'Replayr can\'t read the details of your own Named Credentials, so these aren\'t checked. In Setup, check that it is enabled for callouts, that "replayr" is in its Allowed Namespaces for Callouts, and that a permission set the integration user holds gives access to its External Credential\'s principal.'
                )
            );
            return;
        }
        if (credential.externalCredentials.isEmpty()) {
            result.findings.add(new Finding(NOT_CHECKED, 'This Named Credential has no External Credential (an older kind), so there is no principal access to check.'));
            return;
        }
        for (String name : credential.externalCredentials) {
            checkPrincipalAccess(name, setsByUser, allSets, result);
        }
    }

    private static void checkPrincipalAccess(String name, Map<Id, Set<Id>> setsByUser, Set<Id> allSets, Result result) {
        ExternalCredentialInfo info;
        try {
            info = platform.externalCredential(name);
        } catch (Exception e) {
            // One unreadable External Credential (hidden or removed) costs only its own finding
            result.findings.add(new Finding(NOT_CHECKED, 'External Credential "' + name + '" couldn\'t be read (' + e.getTypeName() + '), so its principal access isn\'t checked.'));
            return;
        }
        if (info.principalIds.isEmpty()) {
            result.findings.add(new Finding(FAILED, 'External Credential "' + name + '" has no principal: add one in Setup, then give the integration user access to it.'));
            return;
        }
        Set<Id> granting = platform.setsGranting(info.principalIds, allSets);
        result.findings.add(
            verdict(missing(setsByUser, granting), 'has access to a principal of External Credential "' + name + '"', 'Add principal access to a permission set it holds.')
        );
        // A permission says nothing about whether someone has logged in
        if (info.needsAuthentication) {
            result.findings.add(
                new Finding(NOT_CHECKED, 'External Credential "' + name + '" uses OAuth or a per-user login: this checks permissions only, not that it has been authenticated.')
            );
        }
    }

    // Each user's permission sets, those in its permission set groups included (access is granted on the sets)
    private static Map<Id, Set<Id>> permissionSetsOf(Set<Id> users) {
        Map<Id, Set<Id>> setsByUser = new Map<Id, Set<Id>>();
        Map<Id, Set<Id>> groupsByUser = new Map<Id, Set<Id>>();
        for (PermissionSetAssignment assignment : [
            SELECT AssigneeId, PermissionSetId, PermissionSetGroupId
            FROM PermissionSetAssignment
            WHERE AssigneeId IN :users
            WITH SYSTEM_MODE
        ]) {
            setOf(setsByUser, assignment.AssigneeId).add(assignment.PermissionSetId);
            if (assignment.PermissionSetGroupId != null) {
                setOf(groupsByUser, assignment.AssigneeId).add(assignment.PermissionSetGroupId);
            }
        }
        Map<Id, Set<Id>> setsByGroup = new Map<Id, Set<Id>>();
        for (Set<Id> groupIds : groupsByUser.values()) {
            for (Id groupId : groupIds) {
                setsByGroup.put(groupId, new Set<Id>());
            }
        }
        if (setsByGroup.isEmpty()) {
            return setsByUser;
        }
        for (PermissionSetGroupComponent component : [
            SELECT PermissionSetGroupId, PermissionSetId
            FROM PermissionSetGroupComponent
            WHERE PermissionSetGroupId IN :setsByGroup.keySet()
            WITH SYSTEM_MODE
        ]) {
            setsByGroup.get(component.PermissionSetGroupId).add(component.PermissionSetId);
        }
        for (Id userId : groupsByUser.keySet()) {
            for (Id groupId : groupsByUser.get(userId)) {
                setOf(setsByUser, userId).addAll(setsByGroup.get(groupId));
            }
        }
        return setsByUser;
    }

    private static Set<Id> readersOfUserExternalCredential(Set<Id> sets) {
        Set<Id> readers = new Set<Id>();
        for (ObjectPermissions permission : [
            SELECT ParentId
            FROM ObjectPermissions
            WHERE SobjectType = :USER_EXTERNAL_CREDENTIAL AND PermissionsRead = TRUE AND ParentId IN :sets
            WITH SYSTEM_MODE
        ]) {
            readers.add(permission.ParentId);
        }
        return readers;
    }

    // The users none of whose permission sets is among those given
    private static Set<Id> missing(Map<Id, Set<Id>> setsByUser, Set<Id> granting) {
        Set<Id> missing = new Set<Id>();
        for (Id userId : setsByUser.keySet()) {
            Set<Id> held = setsByUser.get(userId).clone();
            held.retainAll(granting);
            if (held.isEmpty()) {
                missing.add(userId);
            }
        }
        return missing;
    }

    private static Finding verdict(Set<Id> missing, String what, String fix) {
        if (missing.isEmpty()) {
            return new Finding(PASSED, 'The integration user ' + what + '.');
        }
        List<String> names = new List<String>();
        for (User person : [SELECT Name FROM User WHERE Id IN :missing WITH USER_MODE ORDER BY Name]) {
            names.add(person.Name);
        }
        // The count when the names can't be read
        String who = names.isEmpty() ? missing.size() + (missing.size() == 1 ? ' user' : ' users') : String.join(names, ', ');
        return new Finding(FAILED, 'Not every integration user ' + what + ': ' + who + '. ' + fix);
    }

    private static Set<Id> setOf(Map<Id, Set<Id>> byKey, Id key) {
        if (!byKey.containsKey(key)) {
            byKey.put(key, new Set<Id>());
        }
        return byKey.get(key);
    }
}
