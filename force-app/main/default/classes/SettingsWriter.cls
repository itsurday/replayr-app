/**
 * Writes Replayr's org-wide setting one writer's fields at a time. The poller's heartbeat and purge time, the
 * hand-off's run record and the console's retention share one row: writing back a whole copy read earlier would
 * undo another writer's change made meanwhile, so each writes only what it owns.
 * System mode on purpose: package bookkeeping in Replayr's own protected setting, which a person or the
 * integration user can't be granted write access to.
 */
public inherited sharing class SettingsWriter {
    /**
     * @param values the fields to write and their values; every other field is left as it is
     */
    public static void write(Map<Schema.SObjectField, Object> values) {
        Id rowId = Replayr_Settings__c.getOrgDefaults().Id;
        // A new org-wide row when there is none yet; otherwise only the given fields of the existing one
        Replayr_Settings__c changes = rowId == null
            ? new Replayr_Settings__c(SetupOwnerId = UserInfo.getOrganizationId())
            : new Replayr_Settings__c(Id = rowId);
        for (Schema.SObjectField field : values.keySet()) {
            changes.put(field, values.get(field));
        }
        Database.upsert(changes, true, AccessLevel.SYSTEM_MODE);
    }
}
