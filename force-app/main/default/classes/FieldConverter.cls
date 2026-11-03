/**
 * Turns JSON values into Salesforce field values. Object and field names typed by an admin are always
 * checked against describe results before use (no admin text ever reaches a query unchecked), and a value
 * that can't be converted gets an error naming the field and the expected type, never the value itself,
 * which may be personal data. Field access is enforced later, when records are written in user mode.
 * Package objects and fields need their namespace prefix, for example replayr__Job__c.
 */
public inherited sharing class FieldConverter {
    private static final Pattern DATE_FORMAT = Pattern.compile('\\d{4}-\\d{2}-\\d{2}');
    // A time zone is required: without one the stored value would depend on the running user's time zone
    private static final Pattern DATETIME_FORMAT = Pattern.compile(
        '\\d{4}-\\d{2}-\\d{2}T\\d{2}:\\d{2}(:\\d{2}(\\.\\d{1,9})?)?(Z|[+-]\\d{2}:?\\d{2})'
    );
    private static final Pattern TIME_FORMAT = Pattern.compile('(\\d{2}):(\\d{2})(?::(\\d{2})(?:\\.(\\d{1,3}))?)?');
    // Below this a number is far more likely epoch seconds than milliseconds (it would be before 1973)
    private static final Long MIN_EPOCH_MILLIS = 100000000000L;
    private static final Set<Schema.DisplayType> TEXT_TYPES = new Set<Schema.DisplayType>{
        Schema.DisplayType.STRING,
        Schema.DisplayType.TEXTAREA,
        Schema.DisplayType.EMAIL,
        Schema.DisplayType.PHONE,
        Schema.DisplayType.URL,
        Schema.DisplayType.PICKLIST,
        Schema.DisplayType.COMBOBOX,
        Schema.DisplayType.ENCRYPTEDSTRING
    };
    private static final Set<Schema.DisplayType> DECIMAL_TYPES = new Set<Schema.DisplayType>{
        Schema.DisplayType.DOUBLE,
        Schema.DisplayType.CURRENCY,
        Schema.DisplayType.PERCENT
    };

    // Described one object at a time and cached: the whole-org describe is costly in large orgs
    private static final Map<String, Schema.DescribeSObjectResult> OBJECTS = new Map<String, Schema.DescribeSObjectResult>();

    /** Thrown when a name is unknown or a value can't be converted. */
    public class ConversionException extends Exception {
    }

    /**
     * Finds an object by API name, checked against describe.
     * @param objectName for example Account or Order__c
     * @return the object's description
     * @throws ConversionException if no such object exists
     */
    public static Schema.DescribeSObjectResult objectType(String objectName) {
        String key = (objectName ?? '').trim().toLowerCase();
        if (!OBJECTS.containsKey(key)) {
            OBJECTS.put(key, describe(key));
        }
        Schema.DescribeSObjectResult result = OBJECTS.get(key);
        if (result == null) {
            throw new ConversionException('Unknown object: ' + (objectName ?? '').abbreviate(80));
        }
        return result;
    }

    private static Schema.DescribeSObjectResult describe(String name) {
        if (String.isEmpty(name)) {
            return null;
        }
        try {
            // DEFERRED: child relationships are only described if asked for, which this class never does
            return Schema.describeSObjects(new List<String>{ name }, SObjectDescribeOptions.DEFERRED)[0];
        } catch (InvalidParameterValueException e) {
            return null;
        }
    }

    /**
     * Finds a field on an object, both checked against describe. Relationship paths are not fields.
     * Resolve each mapping rule once, not once per record.
     * @param objectName for example Account
     * @param fieldName for example AnnualRevenue
     * @return the field's description
     * @throws ConversionException if the object or field doesn't exist
     */
    public static Schema.DescribeFieldResult field(String objectName, String fieldName) {
        Schema.DescribeSObjectResult objectType = objectType(objectName);
        Schema.SObjectField field = String.isBlank(fieldName) ? null : objectType.fields.getMap().get(fieldName.trim());
        if (field == null) {
            throw new ConversionException(
                'Unknown field on ' + objectType.getName() + ': ' + (fieldName ?? '').abbreviate(80)
            );
        }
        return field.getDescribe();
    }

    /**
     * Converts a parsed JSON value to the field's type.
     * @param value a value from JSON.deserializeUntyped (never JsonPath.NOT_FOUND: check isFound first)
     * @param field the target field
     * @return the converted value; null for a JSON null, and for blank text or an empty list sent to a non-text field
     * @throws ConversionException if the value can't be used for this field
     */
    public static Object convert(Object value, Schema.DescribeFieldResult field) {
        Schema.DisplayType fieldType = field.getType();
        Boolean blankText = value instanceof String && String.isBlank((String) value);
        if (value == null || (blankText && !TEXT_TYPES.contains(fieldType))) {
            return null;
        }
        if (TEXT_TYPES.contains(fieldType)) {
            return toText(value, field);
        }
        if (DECIMAL_TYPES.contains(fieldType)) {
            return toDecimal(value, field, field.getScale(), field.getPrecision());
        }
        return convertOther(value, field, fieldType);
    }

    private static Object convertOther(Object value, Schema.DescribeFieldResult field, Schema.DisplayType fieldType) {
        switch on fieldType {
            when BOOLEAN {
                return toBoolean(value, field);
            }
            when INTEGER {
                return toInteger(value, field);
            }
            when DATE {
                return toDate(value, field);
            }
            when DATETIME {
                return toDatetime(value, field);
            }
            when TIME {
                return toTime(value, field);
            }
            when REFERENCE, ID {
                return toId(value, field);
            }
            when MULTIPICKLIST {
                return toMultiPicklist(value, field);
            }
            when else {
                throw new ConversionException(
                    'Field ' + field.getName() + ' has a type Replayr does not map yet: ' + fieldType
                );
            }
        }
    }

    private static String toText(Object value, Schema.DescribeFieldResult field) {
        if (value instanceof Map<String, Object> || value instanceof List<Object>) {
            throw mismatch(field, 'text', value);
        }
        return checkLength(String.valueOf(value), field);
    }

    private static String checkLength(String text, Schema.DescribeFieldResult field) {
        if (field.getLength() > 0 && text.length() > field.getLength()) {
            throw new ConversionException(
                'Field ' + field.getName() + ' holds at most ' + field.getLength() + ' characters, got ' + text.length()
            );
        }
        return text;
    }

    // Rejects, rather than rounds, more decimal places than the field has, and too many digits for it
    private static Decimal toDecimal(Object value, Schema.DescribeFieldResult field, Integer scale, Integer precision) {
        Decimal amount = parseNumber(value, field);
        if (precision == 0) {
            return amount;
        }
        if (amount.setScale(scale, System.RoundingMode.DOWN) != amount) {
            throw new ConversionException('Field ' + field.getName() + ' allows ' + scale + ' decimal places');
        }
        Integer wholeDigits = amount.abs().setScale(0, System.RoundingMode.DOWN).toPlainString().length();
        if (precision > 0 && amount.abs() >= 1 && wholeDigits > precision - scale) {
            throw new ConversionException('Field ' + field.getName() + ' allows ' + (precision - scale) + ' digits before the decimal point');
        }
        return amount;
    }

    private static Decimal parseNumber(Object value, Schema.DescribeFieldResult field) {
        if (value instanceof Decimal) {
            return (Decimal) value;
        }
        if (value instanceof Integer || value instanceof Long) {
            return Decimal.valueOf(String.valueOf(value));
        }
        if (value instanceof String) {
            try {
                return Decimal.valueOf(((String) value).trim());
            } catch (TypeException e) {
                throw mismatch(field, 'a number', value);
            }
        }
        throw mismatch(field, 'a number', value);
    }

    private static Integer toInteger(Object value, Schema.DescribeFieldResult field) {
        Decimal amount = parseNumber(value, field);
        Boolean whole = amount.setScale(0, System.RoundingMode.DOWN) == amount;
        if (!whole || amount > 2147483647L || amount < -2147483648L) {
            throw mismatch(field, 'a whole number', value);
        }
        return amount.intValue();
    }

    private static Boolean toBoolean(Object value, Schema.DescribeFieldResult field) {
        if (value instanceof Boolean) {
            return (Boolean) value;
        }
        String text = value instanceof String ? ((String) value).trim().toLowerCase() : null;
        if (text == 'true' || text == 'false') {
            return text == 'true';
        }
        throw mismatch(field, 'true or false', value);
    }

    private static Date toDate(Object value, Schema.DescribeFieldResult field) {
        String text = value instanceof String ? ((String) value).trim() : null;
        if (text == null || !DATE_FORMAT.matcher(text).matches()) {
            throw mismatch(field, 'a date like 2026-10-27', value);
        }
        Date parsed;
        try {
            parsed = Date.valueOf(text);
        } catch (Exception e) {
            throw mismatch(field, 'a date like 2026-10-27', value);
        }
        // Date.valueOf rolls an impossible day such as 2026-02-30 into March; reject it instead
        if (String.valueOf(parsed) != text) {
            throw mismatch(field, 'a date like 2026-10-27', value);
        }
        return parsed;
    }

    private static Datetime toDatetime(Object value, Schema.DescribeFieldResult field) {
        if (value instanceof Integer || value instanceof Long) {
            Long millis = Long.valueOf(String.valueOf(value));
            if (millis < MIN_EPOCH_MILLIS) {
                throw mismatch(field, 'a date and time, or milliseconds (not seconds) since 1970', value);
            }
            return Datetime.newInstance(millis);
        }
        String text = value instanceof String ? ((String) value).trim() : null;
        if (text == null || !DATETIME_FORMAT.matcher(text).matches()) {
            throw mismatch(field, 'a date and time with a time zone, like 2026-10-27T14:30:00Z', value);
        }
        try {
            // JSON parsing reads ISO 8601 with Z or an offset
            return (Datetime) JSON.deserialize(JSON.serialize(text), Datetime.class);
        } catch (Exception e) {
            throw mismatch(field, 'a date and time with a time zone, like 2026-10-27T14:30:00Z', value);
        }
    }

    private static Time toTime(Object value, Schema.DescribeFieldResult field) {
        Matcher parts = value instanceof String ? TIME_FORMAT.matcher(((String) value).trim()) : null;
        if (parts == null || !parts.matches()) {
            throw mismatch(field, 'a time like 14:30:00', value);
        }
        List<Integer> hms = new List<Integer>();
        for (Integer part = 1; part <= 3; part++) {
            hms.add(parts.group(part) == null ? 0 : Integer.valueOf(parts.group(part)));
        }
        if (hms[0] > 23 || hms[1] > 59 || hms[2] > 59) {
            throw mismatch(field, 'a time like 14:30:00', value);
        }
        Integer millis = parts.group(4) == null ? 0 : Integer.valueOf(parts.group(4).rightPad(3, '0'));
        return Time.newInstance(hms[0], hms[1], hms[2], millis);
    }

    private static Id toId(Object value, Schema.DescribeFieldResult field) {
        Id recordId;
        try {
            recordId = value instanceof String ? Id.valueOf(((String) value).trim()) : null;
        } catch (StringException e) {
            recordId = null;
        }
        if (recordId == null) {
            throw mismatch(field, 'a Salesforce record Id', value);
        }
        List<Schema.SObjectType> targets = field.getReferenceTo();
        if (!targets.isEmpty() && !targets.contains(recordId.getSobjectType())) {
            throw new ConversionException(
                'Field ' + field.getName() + ' expects the Id of a record of an allowed object, got the Id of another object'
            );
        }
        return recordId;
    }

    private static String toMultiPicklist(Object value, Schema.DescribeFieldResult field) {
        if (value instanceof String) {
            return checkLength((String) value, field);
        }
        if (!(value instanceof List<Object>)) {
            throw mismatch(field, 'a list of values', value);
        }
        if (((List<Object>) value).isEmpty()) {
            return null;
        }
        List<String> items = new List<String>();
        for (Object item : (List<Object>) value) {
            if (!(item instanceof String)) {
                throw mismatch(field, 'a list of text values', value);
            }
            items.add((String) item);
        }
        return checkLength(String.join(items, ';'), field);
    }

    // Names what was expected and what kind of value arrived, never the value itself
    private static ConversionException mismatch(Schema.DescribeFieldResult field, String expected, Object value) {
        return new ConversionException('Field ' + field.getName() + ' expects ' + expected + ', got ' + kindOf(value));
    }

    private static String kindOf(Object value) {
        if (value instanceof String) {
            return 'text';
        }
        if (value instanceof Boolean) {
            return 'true/false';
        }
        if (value instanceof Map<String, Object>) {
            return 'an object';
        }
        if (value instanceof List<Object>) {
            return 'a list';
        }
        return 'a number';
    }
}
