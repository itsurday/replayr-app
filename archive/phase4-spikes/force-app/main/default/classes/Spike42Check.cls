/**
 * Spike P4.2, never packaged: what a "check this provider" button can read from inside the
 * namespace. For one Named Credential name: does ConnectApi find it (as given, and with the org's prefix), is
 * calloutStatus Enabled, which External Credentials and principals does it use, and which of the given permission
 * sets have access to each principal (SetupEntityAccess). Returns lines to print; throws nothing.
 */
public with sharing class Spike42Check {
    public static List<String> run(String namedCredential, Set<Id> permissionSetIds) {
        List<String> lines = new List<String>{ 'running as ' + UserInfo.getUserName() };
        ConnectApi.NamedCredential found = find(namedCredential, lines);
        if (found == null) {
            return lines;
        }
        lines.add('calloutStatus=' + found.calloutStatus + ' developerName=' + found.developerName);
        for (ConnectApi.ExternalCredential ref : found.externalCredentials) {
            principals(ref.developerName, permissionSetIds, lines);
        }
        return lines;
    }

    private static ConnectApi.NamedCredential find(String name, List<String> lines) {
        for (String candidate : new List<String>{ name, 'replayr__' + name }) {
            try {
                ConnectApi.NamedCredential found = ConnectApi.NamedCredentials.getNamedCredential(candidate);
                lines.add('found as "' + candidate + '"');
                return found;
            } catch (Exception e) {
                lines.add('not found as "' + candidate + '": ' + e.getTypeName() + ': ' + e.getMessage());
            }
        }
        return null;
    }

    private static void principals(String externalCredential, Set<Id> permissionSetIds, List<String> lines) {
        try {
            ConnectApi.ExternalCredential ec = ConnectApi.NamedCredentials.getExternalCredential(externalCredential);
            lines.add('external credential ' + ec.developerName + ' principals=' + ec.principals.size());
            Set<Id> principalIds = new Set<Id>();
            for (ConnectApi.ExternalCredentialPrincipal principal : ec.principals) {
                lines.add('  principal ' + principal.principalName + ' id=' + principal.id + ' type=' + principal.principalType);
                principalIds.add(principal.id);
            }
            for (SetupEntityAccess access : [
                SELECT ParentId, SetupEntityId, SetupEntityType
                FROM SetupEntityAccess
                WHERE SetupEntityId IN :principalIds AND ParentId IN :permissionSetIds
            ]) {
                lines.add('  access: permission set ' + access.ParentId + ' -> principal ' + access.SetupEntityId + ' (' + access.SetupEntityType + ')');
            }
        } catch (Exception e) {
            lines.add('external credential ' + externalCredential + ' error ' + e.getTypeName() + ': ' + e.getMessage());
        }
    }
}
