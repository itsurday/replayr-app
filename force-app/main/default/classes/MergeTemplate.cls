/**
 * Builds request bodies from a JSON template with {{Field}} and {{Parent.Field}} merge fields, one body per
 * record. A merge field inside a JSON string is merged as escaped text (a missing value is empty text); a bare
 * merge field is merged as a JSON value (number, true/false, quoted text or date, or null). A merge field may
 * instead be one IF, for example {{IF(ISBLANK(Phone), MobilePhone, 'none')}}: tests are Field = 'text',
 * Field != 'text', ISBLANK(Field) and NOT(ISBLANK(Field)); the compared value, then and else are each a field
 * or 'text'. Numbers compare by value; other values as text ignoring case, as in formulas, using the merged text
 * form (dates 2026-10-27, date/times in GMT like 2026-10-27T10:00:00.000Z, checkboxes true/false); a blank value
 * equals '', and ISBLANK is also true for text of only spaces. Field names are
 * checked against describe before they reach the query, and records are read in user mode.
 * Any {! is rejected, in the template and in each finished body: with "Allow Formulas in HTTP Body" on a
 * Named Credential, the platform would replace {!$Credential...} with a stored secret and send it.
 */
public inherited sharing class MergeTemplate {
    // Same as Job__c.Request_Body__c, where the body is stored
    private static final Integer MAX_BODY_LENGTH = 131072;
    // A flow hands records over 200 at a time; also bounds the heap held by the results
    private static final Integer MAX_RECORDS = 200;
    // A record's error when the running user can't see it
    private static final String NOT_FOUND = 'Record not found, or not shared with the running user';
    // Compound and binary values serialize as objects or huge strings, not as one JSON value
    private static final Set<Schema.DisplayType> UNMERGEABLE = new Set<Schema.DisplayType>{
        Schema.DisplayType.ADDRESS,
        Schema.DisplayType.LOCATION,
        Schema.DisplayType.BASE64
    };
    private static final Pattern PLACEHOLDER = Pattern.compile('\\{\\{(.*?)\\}\\}');
    // Up to five relationships, then a field: the SOQL limit for parent relationships
    private static final String PATH = '[A-Za-z]\\w*(?:\\.[A-Za-z]\\w*){0,5}';
    private static final Pattern FIELD_PATH = Pattern.compile(PATH);
    // A field or 'text'. The text can't hold ' or braces, which would end it or the merge field, nor a
    // backslash, so that an escape can be added later without changing existing mappings ('' is the planned one)
    private static final String OPERAND = '(\'[^\'{}\\\\]*\'|' + PATH + ')';
    private static final Pattern PLAIN_NUMBER = Pattern.compile('-?\\d+(\\.\\d+)?');
    private static final Pattern IF_START = Pattern.compile('(?i)IF\\s*\\(.*');
    // One IF, no nesting (decisions.md, ADR-007). Groups: 1 ISBLANK field, 2 NOT(ISBLANK) field,
    // 3 compared field, 4 = or !=, 5 compared operand, 6 then, 7 else
    private static final Pattern IF_FORM = Pattern.compile(
        '(?i)IF\\s*\\(\\s*(?:ISBLANK\\s*\\(\\s*(' + PATH + ')\\s*\\)'
        + '|NOT\\s*\\(\\s*ISBLANK\\s*\\(\\s*(' + PATH + ')\\s*\\)\\s*\\)'
        + '|(' + PATH + ')\\s*(!=|=)\\s*' + OPERAND + ')'
        + '\\s*,\\s*' + OPERAND + '\\s*,\\s*' + OPERAND + '\\s*\\)'
    );
    private static final Integer QUOTE = 34;
    private static final Integer BACKSLASH = 92;

    /** Thrown when the template or the records can't be used at all. */
    public class MergeException extends Exception {
    }

    /** One record's body, or the reason it couldn't be built (which never holds record data). */
    public class Result {
        public final String body;
        public final String error;

        private Result(String body, String error) {
            this.body = body;
            this.error = error;
        }
    }

    // A field (relationship names, then the field name, as describe spells them) or a 'text' literal
    private class Operand {
        final List<String> names;
        final String literal;

        Operand(List<String> names, String literal) {
            this.names = names;
            this.literal = literal;
        }

        Object read(SObject record) {
            if (names == null) {
                return literal;
            }
            SObject current = record;
            for (Integer i = 0; i < names.size() - 1 && current != null; i++) {
                current = current.getSObject(names[i]);
            }
            return current?.get(names[names.size() - 1]);
        }
    }

    private enum Check {
        BLANK,
        NOT_BLANK,
        EQUALS,
        NOT_EQUALS
    }

    // A merge field, or an IF: when the check holds the value, otherwise the other value
    private class Placeholder {
        final Boolean asText;
        final Operand value;
        final Check test;
        final Operand left;
        final Operand right;
        final Operand otherwise;

        Placeholder(Boolean asText, Operand value) {
            this(asText, null, null, null, value, null);
        }

        Placeholder(Boolean asText, Check test, Operand left, Operand right, Operand value, Operand otherwise) {
            this.asText = asText;
            this.test = test;
            this.left = left;
            this.right = right;
            this.value = value;
            this.otherwise = otherwise;
        }

        Object read(SObject record) {
            return test == null || holds(record) ? value.read(record) : otherwise.read(record);
        }

        Boolean holds(SObject record) {
            switch on test {
                when BLANK {
                    return isBlank(left.read(record));
                }
                when NOT_BLANK {
                    return !isBlank(left.read(record));
                }
                when EQUALS {
                    return same(left.read(record), right.read(record));
                }
                when else {
                    return !same(left.read(record), right.read(record));
                }
            }
        }

        List<Operand> operands() {
            return new List<Operand>{ value, left, right, otherwise };
        }
    }

    /**
     * Builds one body per record, with a single query for all of them.
     * @param template the JSON template
     * @param recordIds records of one object, at most 200
     * @return a result per record Id: a body, or an error for that record only
     * @throws MergeException if the template is invalid, the Ids are of more than one object or too many, or
     *         the running user can't read the object or a merged field
     */
    public static Map<Id, Result> render(String template, Set<Id> recordIds) {
        Map<Id, Result> results = new Map<Id, Result>();
        if (recordIds == null || recordIds.isEmpty()) {
            return results;
        }
        if (recordIds.size() > MAX_RECORDS) {
            throw new MergeException('At most ' + MAX_RECORDS + ' records per call, got ' + recordIds.size());
        }
        Schema.DescribeSObjectResult objectType = objectOf(recordIds);
        List<Object> parts = parse(template, objectType);
        Map<Id, SObject> records = query(objectType, parts, recordIds);
        for (Id recordId : recordIds) {
            SObject record = records.get(recordId);
            results.put(
                recordId,
                record == null ? new Result(null, NOT_FOUND) : build(parts, record)
            );
        }
        return results;
    }

    /**
     * Checks a template against an object without reading any record, so a mapping can be refused when it is saved
     * rather than when every job fails (the console's mapping editor): the object, the merge fields and {!, as
     * render checks them before its query, and that the template makes JSON (a sample body with an empty value in
     * each quoted merge field and null in each bare one). Not checked: whether the sender may read the fields,
     * which render checks as that user.
     * @param template the JSON template
     * @param objectName the object the template is for, for example Account
     * @return the object's API name as describe gives it
     * @throws MergeException with the reason, if the object is unknown or the template invalid
     */
    public static String check(String template, String objectName) {
        Schema.DescribeSObjectResult objectType;
        try {
            objectType = FieldConverter.objectType(objectName);
        } catch (FieldConverter.ConversionException e) {
            throw new MergeException(e.getMessage());
        }
        List<String> sample = new List<String>();
        for (Object part : parse(template, objectType)) {
            sample.add(part instanceof String ? (String) part : (((Placeholder) part).asText ? '' : 'null'));
        }
        // Each sample value is valid where it stands, so a problem here is the template's own
        String problem = problemWith(String.join(sample, ''));
        if (problem != null) {
            throw new MergeException(problem);
        }
        return objectType.getName();
    }

    private static Schema.DescribeSObjectResult objectOf(Set<Id> recordIds) {
        Set<Schema.SObjectType> types = new Set<Schema.SObjectType>();
        for (Id recordId : recordIds) {
            if (recordId == null) {
                throw new MergeException('A record Id is missing');
            }
            try {
                types.add(recordId.getSobjectType());
            } catch (SObjectException e) {
                throw new MergeException('A record Id belongs to no object in this org');
            }
        }
        if (types.size() > 1) {
            throw new MergeException('All records must be of one object');
        }
        return FieldConverter.objectType(String.valueOf(new List<Schema.SObjectType>(types)[0]));
    }

    // Literal text stays a String; each merge field becomes a Placeholder
    private static List<Object> parse(String template, Schema.DescribeSObjectResult objectType) {
        if (String.isBlank(template)) {
            throw new MergeException('The request template is empty');
        }
        if (template.contains('{!')) {
            throw new MergeException('The request template contains {!, which is not allowed. Use {{Field}} merge fields');
        }
        List<Object> parts = new List<Object>();
        Matcher placeholders = PLACEHOLDER.matcher(template);
        Integer literalStart = 0;
        Boolean inString = false;
        while (placeholders.find()) {
            String literal = template.substring(literalStart, placeholders.start());
            inString = endsInString(literal, inString);
            parts.add(checkLiteral(literal));
            parts.add(placeholder(objectType, placeholders.group(1), inString));
            literalStart = placeholders.end();
        }
        parts.add(checkLiteral(template.substring(literalStart)));
        return parts;
    }

    private static Placeholder placeholder(Schema.DescribeSObjectResult objectType, String content, Boolean asText) {
        String trimmed = content.trim();
        if (!IF_START.matcher(trimmed).matches()) {
            return new Placeholder(asText, new Operand(resolve(objectType, trimmed), null));
        }
        Matcher form = IF_FORM.matcher(trimmed);
        if (!form.matches()) {
            throw new MergeException(
                'Not a valid IF: {{' + trimmed.abbreviate(80) + '}}. Use IF(test, then, else); the test is Field = \'text\', '
                + 'Field != \'text\', ISBLANK(Field) or NOT(ISBLANK(Field)); then and else are fields or \'text\''
            );
        }
        Operand whenTrue = operand(objectType, form.group(6));
        Operand otherwise = operand(objectType, form.group(7));
        if (form.group(1) != null) {
            return new Placeholder(asText, Check.BLANK, operand(objectType, form.group(1)), null, whenTrue, otherwise);
        }
        if (form.group(2) != null) {
            return new Placeholder(asText, Check.NOT_BLANK, operand(objectType, form.group(2)), null, whenTrue, otherwise);
        }
        Check comparison = form.group(4) == '=' ? Check.EQUALS : Check.NOT_EQUALS;
        return new Placeholder(
            asText, comparison, operand(objectType, form.group(3)), operand(objectType, form.group(5)), whenTrue, otherwise
        );
    }

    private static Operand operand(Schema.DescribeSObjectResult objectType, String text) {
        return text.startsWith('\'')
            ? new Operand(null, text.substring(1, text.length() - 1))
            : new Operand(resolve(objectType, text), null);
    }

    // A stray }} is fine: nested JSON objects end that way
    private static String checkLiteral(String literal) {
        if (literal.contains('{{')) {
            throw new MergeException('The request template has a {{ that is not part of a {{Field}} merge field');
        }
        return literal;
    }

    // Follows JSON quoting, including escaped quotes, to tell whether the text ends inside a string.
    // charAt, not getChars: getChars treats backslash sequences as escapes (tested: 'a\\"' gives 97, 34)
    private static Boolean endsInString(String text, Boolean startsInString) {
        Boolean inString = startsInString;
        Boolean escaped = false;
        for (Integer i = 0; i < text.length(); i++) {
            Integer code = text.charAt(i);
            if (escaped) {
                escaped = false;
            } else if (inString && code == BACKSLASH) {
                escaped = true;
            } else if (code == QUOTE) {
                inString = !inString;
            }
        }
        if (escaped) {
            // The backslash would escape the merged value's first character
            throw new MergeException('The request template has a backslash just before a {{Field}} merge field');
        }
        return inString;
    }

    private static List<String> resolve(Schema.DescribeSObjectResult objectType, String path) {
        String trimmed = path.trim();
        if (!FIELD_PATH.matcher(trimmed).matches()) {
            throw new MergeException('Not a merge field: {{' + path.abbreviate(80) + '}}. Use {{Field}} or {{Parent.Field}}');
        }
        List<String> names = trimmed.split('\\.');
        List<String> canonical = new List<String>();
        Schema.DescribeSObjectResult current = objectType;
        try {
            for (Integer i = 0; i < names.size() - 1; i++) {
                Schema.DescribeFieldResult lookup = relationship(current, names[i]);
                canonical.add(lookup.getRelationshipName());
                current = FieldConverter.objectType(String.valueOf(lookup.getReferenceTo()[0]));
            }
            Schema.DescribeFieldResult field = FieldConverter.field(current.getName(), names[names.size() - 1]);
            if (UNMERGEABLE.contains(field.getType())) {
                throw new MergeException(
                    'Field ' + field.getName() + ' is an address, location or file field; merge its parts, such as BillingCity'
                );
            }
            canonical.add(field.getName());
        } catch (FieldConverter.ConversionException e) {
            throw new MergeException(e.getMessage() + ' (in {{' + trimmed + '}})');
        }
        return canonical;
    }

    // shortcut: finds a relationship by the usual naming (Account -> AccountId, Parent__r -> Parent__c);
    // the rare standard relationships named otherwise are rejected. Upgrade if an admin needs one.
    private static Schema.DescribeFieldResult relationship(Schema.DescribeSObjectResult objectType, String name) {
        String fieldName = name.endsWithIgnoreCase('__r') ? name.left(name.length() - 1) + 'c' : name + 'Id';
        Schema.DescribeFieldResult lookup = objectType.fields.getMap().get(fieldName)?.getDescribe();
        if (lookup == null || !name.equalsIgnoreCase(lookup.getRelationshipName())) {
            throw new MergeException('Unknown relationship on ' + objectType.getName() + ': ' + name);
        }
        if (lookup.getReferenceTo().size() != 1) {
            throw new MergeException(
                'Relationship ' + name + ' on ' + objectType.getName() + ' can point to several objects, which merge fields do not support'
            );
        }
        return lookup;
    }

    private static Map<Id, SObject> query(Schema.DescribeSObjectResult objectType, List<Object> parts, Set<Id> recordIds) {
        Map<String, String> fields = new Map<String, String>{ 'id' => 'Id' };
        for (Object part : parts) {
            if (!(part instanceof Placeholder)) {
                continue;
            }
            for (Operand operand : ((Placeholder) part).operands()) {
                if (operand?.names != null) {
                    String path = String.join(operand.names, '.');
                    fields.put(path.toLowerCase(), path);
                }
            }
        }
        // Only describe-checked names reach the query; the Ids are bound
        String soql = 'SELECT ' + String.join(fields.values(), ', ') + ' FROM ' + objectType.getName() + ' WHERE Id IN :recordIds';
        try {
            return new Map<Id, SObject>(
                Database.queryWithBinds(soql, new Map<String, Object>{ 'recordIds' => recordIds }, AccessLevel.USER_MODE)
            );
        } catch (QueryException e) {
            throw new MergeException('Could not read ' + objectType.getName() + ' with the running user\'s access: ' + e.getMessage());
        }
    }

    private static Result build(List<Object> parts, SObject record) {
        List<String> pieces = new List<String>();
        Integer length = 0;
        for (Object part : parts) {
            String piece;
            if (part instanceof String) {
                piece = (String) part;
            } else {
                Placeholder placeholder = (Placeholder) part;
                Object value = placeholder.read(record);
                piece = placeholder.asText ? asText(value) : JSON.serialize(value);
            }
            length += piece.length();
            // Stop before joining a body that can't be stored, to spare the heap
            if (length > MAX_BODY_LENGTH) {
                return new Result(null, 'The request body is longer than the ' + MAX_BODY_LENGTH + ' characters that can be stored');
            }
            pieces.add(piece);
        }
        String body = String.join(pieces, '');
        String problem = problemWith(body);
        return problem == null ? new Result(body, null) : new Result(null, problem);
    }

    private static Boolean isBlank(Object value) {
        return value == null || (value instanceof String && String.isBlank((String) value));
    }

    // Numbers by value (100 = 100.00) when one side is a number field and the other a number or plain number
    // text such as 100 or -2.5; everything else as text, ignoring case as formulas do. Blank equals ''.
    private static Boolean same(Object left, Object right) {
        Decimal leftNumber = toNumber(left);
        Decimal rightNumber = toNumber(right);
        Boolean anyNumberField = !(left instanceof String) || !(right instanceof String);
        if (anyNumberField && leftNumber != null && rightNumber != null) {
            return !(leftNumber < rightNumber) && !(leftNumber > rightNumber);
        }
        return asText(left).equalsIgnoreCase(asText(right));
    }

    // Record fields give Decimal, Integer or Long, never Double (latitude included, tested)
    private static Decimal toNumber(Object value) {
        if (value instanceof Decimal || value instanceof Integer || value instanceof Long) {
            return Decimal.valueOf(String.valueOf(value));
        }
        Boolean plain = value instanceof String && PLAIN_NUMBER.matcher((String) value).matches();
        return plain ? Decimal.valueOf((String) value) : null;
    }

    // JSON.serialize escapes quotes, backslashes and control characters; its outer quotes are dropped
    private static String asText(Object value) {
        if (value == null) {
            return '';
        }
        String json = JSON.serialize(value);
        return json.startsWith('"') ? json.substring(1, json.length() - 1) : json;
    }

    // Messages never quote the body, which holds record data
    private static String problemWith(String body) {
        if (body.contains('{!')) {
            return 'A merged value contains {!, which is not allowed in a request body';
        }
        try {
            JSON.deserializeUntyped(body);
        } catch (JSONException e) {
            return 'The request body is not valid JSON; check the template\'s quotes and commas';
        }
        return null;
    }
}
