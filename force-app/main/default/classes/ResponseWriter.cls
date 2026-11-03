/**
 * Writes an API response into Salesforce records through a Response mapping: the List Path picks the items
 * (blank: the whole body is one item), the rules ({"fields": {"Field__c": "json.path"}}) fill fields, and the
 * Operation inserts, updates or upserts, matched on the Match Field (any text, number or Id field). Update with
 * a blank Match Field writes back to the job's own record. One query finds all matches, and at most one insert
 * and one update save all items, in user mode and with partial success: a bad item is reported, never guessed,
 * and does not stop the others. A path missing from an item leaves the field unchanged; a JSON null clears it.
 * The mapping is validated here, at use, because Data Loader or the API can save anything.
 */
public inherited sharing class ResponseWriter {
    private static final Integer MAX_ITEMS = 1000;
    // Far below the 50,000 query-row limit, whose exception can't be caught and would end the worker after its callout
    private static final Integer MAX_MATCH_ROWS = 10000;
    private static final Integer MAX_MESSAGE_LENGTH = 255;
    private static final String INSERT_OPERATION = 'Insert';
    private static final String UPDATE_OPERATION = 'Update';
    private static final String UPSERT_OPERATION = 'Upsert';

    /** Thrown when the mapping or the response can't be used at all; nothing was written. */
    public class WriteException extends Exception {
    }

    /** How many items were saved, and why each other item was not (never quoting response or record data). */
    public class Outcome {
        public final Integer saved;
        public final List<String> errors;

        private Outcome(Integer saved, List<String> errors) {
            this.saved = saved;
            this.errors = errors;
        }
    }

    private class Rule {
        final Schema.DescribeFieldResult field;
        final String path;

        Rule(Schema.DescribeFieldResult field, String path) {
            this.field = field;
            this.path = path;
        }
    }

    // The checked mapping
    private class Plan {
        Schema.DescribeSObjectResult target;
        String operation;
        List<Rule> rules;
        Schema.DescribeFieldResult matchField;
        String listPath;
        Id ownRecordId;
    }

    // One response item on its way to a record; once error is set it is not written
    private class Item {
        final Integer position;
        SObject record;
        Object matchValue;
        String matchKey;
        String error;

        Item(Integer position) {
            this.position = position;
        }
    }

    /**
     * Writes the response's items as records.
     * @param mapping a Response mapping with Direction, Target Object, Operation, Match Field, List Path and Rules
     * @param responseBody the response JSON
     * @param recordId the job's record, used only to write back to it (Update with a blank Match Field)
     * @return the count saved and the errors of the items that were not
     * @throws WriteException if the mapping is invalid or the response is not usable JSON
     */
    public static Outcome write(Mapping__c mapping, String responseBody, Id recordId) {
        Plan plan = plan(mapping, recordId);
        List<String> errors = new List<String>();
        List<Item> items = build(plan, itemsOf(plan, responseBody, errors));
        if (plan.matchField != null && plan.operation != INSERT_OPERATION) {
            match(plan, items);
        }
        Integer saved = save(items);
        for (Item item : items) {
            if (item.error != null) {
                errors.add('Item ' + item.position + ': ' + item.error);
            }
        }
        return new Outcome(saved, errors);
    }

    /**
     * Checks a Response mapping without a response or a record, so it can be refused when it is saved (the console's
     * mapping editor): the Operation, the List Path, the object, each rule's field and path, and a Match Field's
     * type and rule. Not checked: whether the writing user may write the fields (judged as the integration user,
     * when it writes), and, for an Update without a Match Field, that the job's record is of the target object.
     * @param mapping the mapping, its Direction Response
     * @return the target object's API name as describe gives it
     * @throws WriteException with the reason, if the mapping can't be used
     */
    public static String check(Mapping__c mapping) {
        Plan plan = describedPlan(mapping);
        if (plan.operation != UPDATE_OPERATION || plan.matchField != null) {
            checkMatching(plan, null);
        }
        return plan.target.getName();
    }

    private static Plan plan(Mapping__c mapping, Id recordId) {
        Plan plan = describedPlan(mapping);
        checkMatching(plan, recordId);
        checkAccess(plan);
        return plan;
    }

    // Everything that needs neither a record nor the writing user's access
    private static Plan describedPlan(Mapping__c mapping) {
        if (mapping?.Direction__c != 'Response') {
            throw new WriteException('Not a Response mapping');
        }
        Plan plan = new Plan();
        plan.operation = mapping.Operation__c;
        if (plan.operation != INSERT_OPERATION && plan.operation != UPDATE_OPERATION && plan.operation != UPSERT_OPERATION) {
            throw new WriteException('A Response mapping needs an Operation: Insert, Update or Upsert');
        }
        plan.listPath = mapping.List_Path__c;
        try {
            JsonPath.get(null, plan.listPath);
            plan.target = FieldConverter.objectType(mapping.Target_Object__c);
            plan.rules = rules(plan.target, mapping.Rules__c);
            if (String.isNotBlank(mapping.Match_Field__c)) {
                plan.matchField = FieldConverter.field(plan.target.getName(), mapping.Match_Field__c);
            }
        } catch (FieldConverter.ConversionException e) {
            throw new WriteException(e.getMessage());
        } catch (JsonPath.InvalidPathException e) {
            throw new WriteException(e.getMessage());
        }
        return plan;
    }

    private static List<Rule> rules(Schema.DescribeSObjectResult target, String rulesJson) {
        Map<String, Object> fields = ruleMap(rulesJson);
        List<Rule> rules = new List<Rule>();
        Set<String> seen = new Set<String>();
        for (String fieldName : fields.keySet()) {
            Object path = fields.get(fieldName);
            if (!(path instanceof String)) {
                throw new WriteException('The rule for ' + fieldName.abbreviate(80) + ' must be a JSON path in quotes');
            }
            JsonPath.get(null, (String) path);
            Schema.DescribeFieldResult field = FieldConverter.field(target.getName(), fieldName);
            if (!seen.add(field.getName())) {
                throw new WriteException('Field ' + field.getName() + ' has more than one rule');
            }
            rules.add(new Rule(field, (String) path));
        }
        return rules;
    }

    private static Map<String, Object> ruleMap(String rulesJson) {
        String expected = 'Rules must look like {"fields": {"Field__c": "json.path"}}';
        if (String.isBlank(rulesJson) || rulesJson.contains('{!')) {
            throw new WriteException(expected + (String.isBlank(rulesJson) ? '' : ', without {!'));
        }
        Object parsed;
        try {
            parsed = JSON.deserializeUntyped(rulesJson);
        } catch (JSONException e) {
            throw new WriteException(expected);
        }
        // Only "fields" today, so further keys can be given a meaning later
        Map<String, Object> root = parsed instanceof Map<String, Object> ? (Map<String, Object>) parsed : null;
        Object fields = root?.get('fields');
        if (root?.size() != 1 || !(fields instanceof Map<String, Object>) || ((Map<String, Object>) fields).isEmpty()) {
            throw new WriteException(expected);
        }
        return (Map<String, Object>) fields;
    }

    private static void checkMatching(Plan plan, Id recordId) {
        if (plan.operation == INSERT_OPERATION) {
            return;
        }
        if (plan.matchField == null && plan.operation == UPDATE_OPERATION) {
            if (recordId == null || recordId.getSobjectType() != plan.target.getSObjectType()) {
                throw new WriteException(
                    'Update without a Match Field writes back to the job\'s record, which must be a record of ' + plan.target.getName()
                );
            }
            plan.ownRecordId = recordId;
            return;
        }
        if (plan.matchField == null) {
            throw new WriteException('Upsert needs a Match Field');
        }
        if (elementType(plan.matchField) == null || !plan.matchField.isFilterable()) {
            throw new WriteException('Match Field ' + plan.matchField.getName() + ' must be a text, number or Id field');
        }
        for (Rule rule : plan.rules) {
            if (rule.field.getName() == plan.matchField.getName()) {
                return;
            }
        }
        throw new WriteException('Match Field ' + plan.matchField.getName() + ' needs a rule giving its value');
    }

    // Describe reflects the running user's access, so a field it can't write fails the mapping once, not every item
    private static void checkAccess(Plan plan) {
        Boolean inserts = plan.operation != UPDATE_OPERATION;
        Boolean updates = plan.operation != INSERT_OPERATION;
        if ((inserts && !plan.target.isCreateable()) || (updates && !plan.target.isUpdateable())) {
            throw new WriteException('The running user cannot ' + plan.operation.toLowerCase() + ' ' + plan.target.getName() + ' records');
        }
        for (Rule rule : plan.rules) {
            // The match field is only written on insert: an update finds the record by it
            Boolean isMatch = rule.field.getName() == plan.matchField?.getName();
            if ((inserts && !rule.field.isCreateable()) || (updates && !isMatch && !rule.field.isUpdateable())) {
                throw new WriteException('The running user cannot write field ' + rule.field.getName() + ' for ' + plan.operation);
            }
        }
    }

    // Dynamic SOQL binds need a list of the column's type; List<Object> fails (tested)
    private static String elementType(Schema.DescribeFieldResult field) {
        switch on field.getType() {
            when STRING, EMAIL, PHONE, URL, PICKLIST, COMBOBOX {
                return 'String';
            }
            when ID, REFERENCE {
                return 'Id';
            }
            when DOUBLE, CURRENCY, PERCENT {
                return 'Decimal';
            }
            when INTEGER {
                return 'Integer';
            }
            when else {
                return null;
            }
        }
    }

    private static List<Object> itemsOf(Plan plan, String responseBody, List<String> errors) {
        Object root;
        try {
            root = JSON.deserializeUntyped(responseBody ?? '');
        } catch (JSONException e) {
            throw new WriteException('The response is not valid JSON');
        }
        Object found = JsonPath.get(root, plan.listPath);
        if (!JsonPath.isFound(found)) {
            throw new WriteException('List Path ' + plan.listPath.abbreviate(100) + ' is not in the response');
        }
        List<Object> all = found instanceof List<Object> ? (List<Object>) found : new List<Object>{ found };
        if (plan.ownRecordId != null && all.size() != 1) {
            throw new WriteException('Writing back to the job\'s record needs one item in the response, got ' + all.size());
        }
        if (all.size() <= MAX_ITEMS) {
            return all;
        }
        errors.add((all.size() - MAX_ITEMS) + ' items after the first ' + MAX_ITEMS + ' were not written');
        List<Object> first = new List<Object>();
        for (Integer i = 0; i < MAX_ITEMS; i++) {
            first.add(all[i]);
        }
        return first;
    }

    private static List<Item> build(Plan plan, List<Object> values) {
        List<Item> items = new List<Item>();
        for (Integer i = 0; i < values.size(); i++) {
            Item item = new Item(i + 1);
            items.add(item);
            if (!(values[i] instanceof Map<String, Object>)) {
                item.error = 'not a JSON object';
                continue;
            }
            try {
                fill(plan, item, values[i]);
            } catch (FieldConverter.ConversionException e) {
                item.error = e.getMessage();
            }
        }
        return items;
    }

    private static void fill(Plan plan, Item item, Object value) {
        item.record = plan.target.getSObjectType().newSObject(plan.ownRecordId);
        Boolean matching = plan.matchField != null && plan.operation != INSERT_OPERATION;
        for (Rule rule : plan.rules) {
            Object found = JsonPath.get(value, rule.path);
            if (!JsonPath.isFound(found)) {
                continue;
            }
            Object converted = FieldConverter.convert(found, rule.field);
            if (matching && rule.field.getName() == plan.matchField.getName()) {
                item.matchValue = converted;
                item.matchKey = key(converted, plan.matchField);
            } else {
                item.record.put(rule.field.getName(), converted);
            }
        }
        // Blank text would match every record with an empty field, or insert another blank one on each replay
        if (matching && item.matchKey == null) {
            item.error = 'no value for the Match Field ' + plan.matchField.getName();
        }
    }

    // As SOQL compares: numbers by value, text ignoring case unless the field is case-sensitive; blank is no key
    private static String key(Object value, Schema.DescribeFieldResult field) {
        if (value instanceof Decimal) {
            return ((Decimal) value).stripTrailingZeros().toPlainString();
        }
        String text = value == null ? null : String.valueOf(value);
        if (String.isBlank(text)) {
            return null;
        }
        // A fixed locale: the user's (Turkish, for one) would lower-case I differently from SOQL
        return field.isCaseSensitive() ? text : text.toLowerCase('en_US');
    }

    private static void match(Plan plan, List<Item> items) {
        String fieldName = plan.matchField.getName();
        Map<String, Item> firstByKey = new Map<String, Item>();
        List<Object> values = (List<Object>) Type.forName('List<' + elementType(plan.matchField) + '>').newInstance();
        for (Item item : items) {
            if (item.error != null) {
                continue;
            }
            if (firstByKey.containsKey(item.matchKey)) {
                item.error = 'same ' + fieldName + ' as item ' + firstByKey.get(item.matchKey).position;
                continue;
            }
            firstByKey.put(item.matchKey, item);
            values.add(item.matchValue);
        }
        Map<String, List<Id>> idsByKey = existing(plan, values);
        for (Item item : firstByKey.values()) {
            List<Id> ids = idsByKey.get(item.matchKey) ?? new List<Id>();
            if (ids.size() > 1) {
                item.error = ids.size() + ' ' + plan.target.getName() + ' records have this ' + fieldName;
            } else if (ids.size() == 1) {
                item.record.Id = ids[0];
            } else if (plan.operation == UPDATE_OPERATION) {
                item.error = 'no ' + plan.target.getName() + ' record has this ' + fieldName;
            } else {
                item.record.put(fieldName, item.matchValue);
            }
        }
    }

    private static Map<String, List<Id>> existing(Plan plan, List<Object> values) {
        Map<String, List<Id>> idsByKey = new Map<String, List<Id>>();
        if (values.isEmpty()) {
            return idsByKey;
        }
        String fieldName = plan.matchField.getName();
        // Only describe-checked names reach the query; the values are bound
        String soql =
            'SELECT ' + (fieldName == 'Id' ? 'Id' : 'Id, ' + fieldName) + ' FROM ' + plan.target.getName() +
            ' WHERE ' + fieldName + ' IN :matchValues LIMIT ' + (MAX_MATCH_ROWS + 1);
        List<SObject> rows;
        try {
            rows = Database.queryWithBinds(soql, new Map<String, Object>{ 'matchValues' => values }, AccessLevel.USER_MODE);
        } catch (QueryException e) {
            throw new WriteException('Could not search ' + plan.target.getName() + ' with the running user\'s access: ' + e.getMessage());
        }
        // Failing is safer than a partial search, which on Upsert would insert duplicates
        if (rows.size() > MAX_MATCH_ROWS) {
            throw new WriteException(
                'More than ' + MAX_MATCH_ROWS + ' ' + plan.target.getName() + ' records share these ' + fieldName + ' values; choose a more unique Match Field'
            );
        }
        for (SObject row : rows) {
            String key = key(row.get(fieldName), plan.matchField);
            if (key == null) {
                continue;
            }
            if (!idsByKey.containsKey(key)) {
                idsByKey.put(key, new List<Id>());
            }
            idsByKey.get(key).add(row.Id);
        }
        return idsByKey;
    }

    private static Integer save(List<Item> items) {
        List<Item> inserts = new List<Item>();
        List<Item> updates = new List<Item>();
        for (Item item : items) {
            if (item.error == null) {
                (item.record.Id == null ? inserts : updates).add(item);
            }
        }
        Integer saved = 0;
        if (!inserts.isEmpty()) {
            saved += recordResults(Database.insert(records(inserts), false, AccessLevel.USER_MODE), inserts);
        }
        if (!updates.isEmpty()) {
            saved += recordResults(Database.update(records(updates), false, AccessLevel.USER_MODE), updates);
        }
        return saved;
    }

    private static List<SObject> records(List<Item> items) {
        List<SObject> records = new List<SObject>();
        for (Item item : items) {
            records.add(item.record);
        }
        return records;
    }

    private static Integer recordResults(List<Database.SaveResult> results, List<Item> items) {
        Integer saved = 0;
        for (Integer i = 0; i < results.size(); i++) {
            if (results[i].isSuccess()) {
                saved++;
            } else {
                items[i].error = describe(results[i].getErrors()[0]);
            }
        }
        return saved;
    }

    // Platform messages can quote the value (for example "data value too large"), so only the status is kept.
    // Validation rule messages are kept as the admin's guidance; the same status carries trigger and flow
    // addError messages, which may hold record data, so they are shortened
    private static String describe(Database.Error error) {
        if (error.getStatusCode() == StatusCode.FIELD_CUSTOM_VALIDATION_EXCEPTION) {
            return error.getMessage().abbreviate(MAX_MESSAGE_LENGTH);
        }
        List<String> fields = error.getFields();
        return String.valueOf(error.getStatusCode()) + (fields.isEmpty() ? '' : ' (' + String.join(fields, ', ') + ')');
    }
}
