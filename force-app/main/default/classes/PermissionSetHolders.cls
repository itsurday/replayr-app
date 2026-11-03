/**
 * Which active users hold one of Replayr's permission sets, directly or through a permission set group that
 * contains it. Automated Process never counts, even if a set was assigned to it (possible through the API, P0.5):
 * it can't use credentials, own Replayr's jobs or read alerts. Read in system mode on purpose: only admins can
 * read permission set assignments, and the callers (the alert sender, the work-waiting hand-off, job creation)
 * run as other users. inherited sharing, not with sharing: the queries filter through User (Assignee.IsActive), which
 * has record sharing, so with sharing could hide holders from someone in an org whose User sharing is Private.
 */
public inherited sharing class PermissionSetHolders {
    /**
     * @param setName the permission set's API name, without the namespace
     * @param amongUserIds only these users, or null for all
     * @return the holders' Ids
     */
    public static Set<Id> of(String setName, Set<Id> amongUserIds) {
        Set<Id> groupIds = new Set<Id>();
        String namespace = namespace();
        for (PermissionSetGroupComponent component : [
            SELECT PermissionSetGroupId
            FROM PermissionSetGroupComponent
            WHERE PermissionSet.Name = :setName AND PermissionSet.NamespacePrefix = :namespace
            WITH SYSTEM_MODE
        ]) {
            groupIds.add(component.PermissionSetGroupId);
        }
        List<PermissionSetAssignment> assignments = amongUserIds == null
            ? [
                SELECT AssigneeId
                FROM PermissionSetAssignment
                WHERE Assignee.IsActive = TRUE
                    AND Assignee.UserType != 'AutomatedProcess'
                    AND ((PermissionSet.Name = :setName AND PermissionSet.NamespacePrefix = :namespace) OR PermissionSetGroupId IN :groupIds)
                WITH SYSTEM_MODE
            ]
            : [
                SELECT AssigneeId
                FROM PermissionSetAssignment
                WHERE Assignee.IsActive = TRUE
                    AND Assignee.UserType != 'AutomatedProcess'
                    AND AssigneeId IN :amongUserIds
                    AND ((PermissionSet.Name = :setName AND PermissionSet.NamespacePrefix = :namespace) OR PermissionSetGroupId IN :groupIds)
                WITH SYSTEM_MODE
            ];
        Set<Id> holders = new Set<Id>();
        for (PermissionSetAssignment assignment : assignments) {
            holders.add(assignment.AssigneeId);
        }
        return holders;
    }

    // replayr in the package and the dev org; null where the code has no namespace
    private static String namespace() {
        String name = String.valueOf(Job__c.SObjectType);
        return name.countMatches('__') > 1 ? name.substringBefore('__') : null;
    }
}
