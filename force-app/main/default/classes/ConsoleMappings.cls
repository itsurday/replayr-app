/**
 * The console's mapping editor: an endpoint's mappings, and saving one after the same checks a
 * job would make, so a broken template or rule is refused with its reason when saved (decisions.md, ADR-024).
 * For Replayr Admins and Operators to read (Replayr_Manage_Jobs); saving is in user mode, so only those who may
 * edit mappings (Replayr Admins) can. An endpoint has at most one Request and one Response mapping, as sending and
 * the worker require.
 */
public with sharing class ConsoleMappings {
    public static final String REQUEST = 'Request';
    public static final String RESPONSE = 'Response';

    /** One mapping, as stored. */
    public class MappingRow {
        @AuraEnabled
        public Id id;
        @AuraEnabled
        public String direction;
        @AuraEnabled
        public String targetObject;
        @AuraEnabled
        public String operation;
        @AuraEnabled
        public String matchField;
        @AuraEnabled
        public String listPath;
        /** The Request template, or the Response rules as JSON. */
        @AuraEnabled
        public String rules;
    }

    /** An endpoint's mappings. */
    public class Mappings {
        @AuraEnabled
        public List<MappingRow> rows = new List<MappingRow>();
        /** Whether the person may create and edit mappings (Replayr Admins). */
        @AuraEnabled
        public Boolean canEdit = false;
    }

    /** A Request mapping to save: a new one for the endpoint when id is null. */
    public class RequestMapping {
        public Id id;
        public Id endpointId;
        public String targetObject;
        public String template;
    }

    /** One Response rule: a field and the JSON path, within an item, it is filled from. */
    public class Rule {
        @AuraEnabled
        public String field;
        @AuraEnabled
        public String path;
    }

    /** A Response mapping to save: a new one for the endpoint when id is null. */
    public class ResponseMapping {
        public Id id;
        public Id endpointId;
        public String targetObject;
        public String operation;
        public String matchField;
        public String listPath;
        public List<Rule> rules;
    }

    /** Rules proposed from a sample reply (MappingProposal). */
    public class Proposal {
        /** The List Path proposed or chosen; blank when the whole reply is one item, or a candidate must be chosen. */
        @AuraEnabled
        public String listPath;
        /** Lists found at the nearest level, when there was more than one: choose one and ask again. */
        @AuraEnabled
        public List<String> listPathCandidates;
        @AuraEnabled
        public List<Rule> rules = new List<Rule>();
        /** Paths in the sample matched to no field. */
        @AuraEnabled
        public List<String> unmatched;
    }

    /**
     * Lists an endpoint's mappings, Request first.
     * @param endpointId the endpoint
     * @return its mappings
     */
    @AuraEnabled
    public static Mappings mappings(Id endpointId) {
        requirePermission();
        try {
            Mappings result = new Mappings();
            for (Mapping__c mapping : [
                SELECT Id, Direction__c, Target_Object__c, Operation__c, Match_Field__c, List_Path__c, Rules__c
                FROM Mapping__c
                WHERE Endpoint__c = :endpointId
                WITH USER_MODE
                ORDER BY Direction__c, CreatedDate
            ]) {
                result.rows.add(toRow(mapping));
            }
            result.canEdit = Schema.SObjectType.Mapping__c.isCreateable() && Schema.SObjectType.Mapping__c.isUpdateable();
            return result;
        } catch (Exception e) {
            // Only the type: a query error can name fields and objects
            throw ConsoleError.of('Replayr couldn\'t read mappings (' + e.getTypeName() + '): check your Replayr permission set.');
        }
    }

    /**
     * The console's Request mapping save. Plain parameters, not a RequestMapping: in real orgs a custom Apex class
     * parameter was seen to fail ("An internal server error has occurred") before any Apex ran (docs/apex-notes.md).
     * @param id the mapping; null for a new one
     * @param endpointId the endpoint, for a new one
     * @param targetObject the object the template reads
     * @param template the template
     * @return the mapping's Id
     */
    @AuraEnabled
    public static Id saveRequest(Id id, Id endpointId, String targetObject, String template) {
        RequestMapping mapping = new RequestMapping();
        mapping.id = id;
        mapping.endpointId = endpointId;
        mapping.targetObject = targetObject;
        mapping.template = template;
        return saveRequestMapping(mapping);
    }

    /**
     * Saves a Request mapping once its template passes the checks a job makes.
     * @param mapping the mapping
     * @return the mapping's Id
     */
    public static Id saveRequestMapping(RequestMapping mapping) {
        requirePermission();
        if (mapping == null || (mapping.id == null && mapping.endpointId == null)) {
            throw ConsoleError.of('Say which endpoint the mapping is for.');
        }
        String objectName;
        try {
            objectName = MergeTemplate.check(mapping.template, mapping.targetObject);
        } catch (MergeTemplate.MergeException e) {
            // Its messages are about the template and the object's fields, written for the admin
            throw ConsoleError.of('Not saved: ' + e.getMessage());
        }
        if (mapping.id == null) {
            requireNone(mapping.endpointId, REQUEST);
            return save(new Mapping__c(Endpoint__c = mapping.endpointId, Direction__c = REQUEST, Target_Object__c = objectName, Rules__c = mapping.template));
        }
        requireDirection(mapping.id, REQUEST);
        return save(new Mapping__c(Id = mapping.id, Target_Object__c = objectName, Rules__c = mapping.template));
    }

    /**
     * The console's Response mapping save. Plain parameters and the rules as JSON, for the reason on saveRequest.
     * @param id the mapping; null for a new one
     * @param endpointId the endpoint, for a new one
     * @param targetObject the object written to
     * @param operation the write (Insert, Update, Upsert)
     * @param matchField the field that finds the record to update or upsert
     * @param listPath the JSON path of the reply's list; blank for the whole reply
     * @param rulesJson the table's rows, as [{"field": ..., "path": ...}]
     * @return the mapping's Id
     */
    @AuraEnabled
    public static Id saveResponse(Id id, Id endpointId, String targetObject, String operation, String matchField, String listPath, String rulesJson) {
        // Before reading the rules, so someone without access learns nothing from a parse error
        requirePermission();
        ResponseMapping mapping = new ResponseMapping();
        mapping.id = id;
        mapping.endpointId = endpointId;
        mapping.targetObject = targetObject;
        mapping.operation = operation;
        mapping.matchField = matchField;
        mapping.listPath = listPath;
        mapping.rules = rulesOf(rulesJson);
        return saveResponseMapping(mapping);
    }

    // The table's rows as sent; anything that isn't a list of rules is refused rather than half read
    private static List<Rule> rulesOf(String rulesJson) {
        if (String.isBlank(rulesJson)) {
            return new List<Rule>();
        }
        try {
            return (List<Rule>) JSON.deserialize(rulesJson, List<Rule>.class);
        } catch (JSONException e) {
            throw ConsoleError.of('Not saved: the rules couldn\'t be read.');
        } catch (TypeException e) {
            throw ConsoleError.of('Not saved: the rules couldn\'t be read.');
        }
    }

    /**
     * Saves a Response mapping once it passes the checks the worker makes (ResponseWriter.check).
     * @param mapping the mapping, its rules as rows
     * @return the mapping's Id
     */
    public static Id saveResponseMapping(ResponseMapping mapping) {
        requirePermission();
        if (mapping == null || (mapping.id == null && mapping.endpointId == null)) {
            throw ConsoleError.of('Say which endpoint the mapping is for.');
        }
        Mapping__c checked = new Mapping__c(
            Direction__c = RESPONSE,
            Target_Object__c = mapping.targetObject,
            Operation__c = mapping.operation,
            Match_Field__c = String.isBlank(mapping.matchField) ? null : mapping.matchField.trim(),
            List_Path__c = String.isBlank(mapping.listPath) ? null : mapping.listPath.trim(),
            Rules__c = rulesJson(mapping.rules)
        );
        try {
            checked.Target_Object__c = ResponseWriter.check(checked);
        } catch (ResponseWriter.WriteException e) {
            // Its messages are about the mapping's object, fields and paths, written for the admin
            throw ConsoleError.of('Not saved: ' + e.getMessage());
        }
        Mapping__c record = new Mapping__c(
            Target_Object__c = checked.Target_Object__c,
            Operation__c = checked.Operation__c,
            Match_Field__c = checked.Match_Field__c,
            List_Path__c = checked.List_Path__c,
            Rules__c = checked.Rules__c
        );
        if (mapping.id == null) {
            requireNone(mapping.endpointId, RESPONSE);
            record.Endpoint__c = mapping.endpointId;
            record.Direction__c = RESPONSE;
        } else {
            // The direction and endpoint never change on an edit
            requireDirection(mapping.id, RESPONSE);
            record.Id = mapping.id;
        }
        return save(record);
    }

    /**
     * Proposes rules from a sample reply, for the editor to fill its table with.
     * @param sampleJson a sample of the API's reply
     * @param targetObject the object the rules write to
     * @param listPath the List Path to use; '' for the whole reply; null to find it
     * @return the proposal
     */
    @AuraEnabled
    public static Proposal propose(String sampleJson, String targetObject, String listPath) {
        requirePermission();
        try {
            MappingProposal found = MappingProposal.fromSample(sampleJson, FieldConverter.objectType(targetObject).getName(), listPath);
            Proposal proposal = new Proposal();
            proposal.listPath = found.listPath;
            proposal.listPathCandidates = found.listPathCandidates;
            proposal.unmatched = found.unmatched;
            Map<String, String> fields = found.fields;
            for (String field : fields.keySet()) {
                proposal.rules.add(rule(field, fields.get(field)));
            }
            return proposal;
        } catch (MappingProposal.ProposalException e) {
            throw ConsoleError.of(e.getMessage());
        } catch (FieldConverter.ConversionException e) {
            throw ConsoleError.of(e.getMessage());
        }
    }

    // The table's rows as stored: {"fields": {"Field__c": "json.path"}}. Fully empty rows are dropped; a half-filled
    // row or a field given twice is refused, as a JSON object would silently keep only one of the two
    private static String rulesJson(List<Rule> rows) {
        Map<String, String> fields = new Map<String, String>();
        Set<String> seen = new Set<String>();
        // Not ?? in the for header: Code Analyzer v5's Graph Engine can't load a class with that; recheck on upgrade
        List<Rule> given = rows ?? new List<Rule>();
        for (Rule row : given) {
            String field = row?.field?.trim();
            String path = row?.path?.trim();
            if (String.isBlank(field) && String.isBlank(path)) {
                continue;
            }
            if (String.isBlank(field) || String.isBlank(path)) {
                throw ConsoleError.of('Not saved: each rule needs a field and a JSON path.');
            }
            // Field names ignore case, as describe does
            if (!seen.add(field.toLowerCase())) {
                throw ConsoleError.of('Not saved: field ' + field.abbreviate(80) + ' has more than one rule.');
            }
            fields.put(field, path);
        }
        return fields.isEmpty() ? null : JSON.serialize(new Map<String, Object>{ 'fields' => fields });
    }

    private static Rule rule(String field, String path) {
        Rule rule = new Rule();
        rule.field = field;
        rule.path = path;
        return rule;
    }

    // A second mapping of one direction would make sending (Request) or the worker (Response) refuse the endpoint.
    // The endpoint is locked first, so two saves at once can't both find none and both insert one
    private static void requireNone(Id endpointId, String direction) {
        if ([SELECT Id FROM Endpoint__c WHERE Id = :endpointId WITH USER_MODE LIMIT 1 FOR UPDATE].isEmpty()) {
            throw ConsoleError.of('Endpoint not found, or you can\'t see it.');
        }
        if (![SELECT Id FROM Mapping__c WHERE Endpoint__c = :endpointId AND Direction__c = :direction WITH USER_MODE LIMIT 1].isEmpty()) {
            throw ConsoleError.of('This endpoint already has a ' + direction + ' mapping: edit that one.');
        }
    }

    private static void requireDirection(Id mappingId, String direction) {
        List<Mapping__c> existing = [SELECT Direction__c FROM Mapping__c WHERE Id = :mappingId WITH USER_MODE];
        if (existing.isEmpty() || existing[0].Direction__c != direction) {
            throw ConsoleError.of('Mapping not found, or not a ' + direction + ' mapping.');
        }
    }

    // User mode: only those who may create or edit mappings save one. A validation rule's message is shown;
    // other failures only by type, as their messages can name fields
    private static Id save(Mapping__c record) {
        try {
            Database.upsert(record, true, AccessLevel.USER_MODE);
            return record.Id;
        } catch (DmlException e) {
            if (e.getDmlType(0) == StatusCode.FIELD_CUSTOM_VALIDATION_EXCEPTION) {
                throw ConsoleError.of('Not saved: ' + e.getDmlMessage(0));
            }
            throw ConsoleError.of('Not saved (' + e.getDmlType(0) + '). Saving mappings needs the Replayr Admin permission set.');
        } catch (Exception e) {
            throw ConsoleError.of('Not saved (' + e.getTypeName() + '). Saving mappings needs the Replayr Admin permission set.');
        }
    }

    private static MappingRow toRow(Mapping__c mapping) {
        MappingRow row = new MappingRow();
        row.id = mapping.Id;
        row.direction = mapping.Direction__c;
        row.targetObject = mapping.Target_Object__c;
        row.operation = mapping.Operation__c;
        row.matchField = mapping.Match_Field__c;
        row.listPath = mapping.List_Path__c;
        row.rules = mapping.Rules__c;
        return row;
    }

    private static void requirePermission() {
        if (!FeatureManagement.checkPermission(JobActions.PERMISSION)) {
            throw ConsoleError.of('You need the Replayr Admin or Replayr Operator permission set.');
        }
    }
}
