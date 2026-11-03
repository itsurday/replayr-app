/**
 * Reads a value at a path in parsed JSON (the result of JSON.deserializeUntyped), such as
 * data.orders[0].customer.email. Keys are separated by dots, list positions are [n], and an empty path
 * is the whole document. Nothing at the path returns NOT_FOUND, never an exception, and is distinct from
 * a JSON null: a missing value leaves a field unchanged, a null clears it.
 * Known limit: a key containing a dot or a square bracket cannot be addressed.
 */
public inherited sharing class JsonPath {
    /**
     * Returned when nothing is at the path. Compare with ===, and branch on isFound() in the same transaction:
     * never store, serialize or pass it to async code, where it stops matching and serializes as {}.
     */
    public static final Object NOT_FOUND = new Missing();

    // Same as List_Path__c; checked before the regex, which could otherwise hit an uncatchable limit
    private static final Integer MAX_PATH_LENGTH = 255;
    // A key is anything but . [ ]; then any number of [n]. Only the first segment may start with [n]
    private static final Pattern SEGMENT = Pattern.compile('([^.\\[\\]]*)((?:\\[\\d{1,9}\\])*)');
    private static final Pattern INDEX = Pattern.compile('\\[(\\d{1,9})\\]');

    /** Thrown when a path is not written in the supported form. */
    public class InvalidPathException extends Exception {
    }

    private class Missing {
    }

    /**
     * Reads the value at a path.
     * @param root parsed JSON: a Map<String, Object>, a List<Object> or a primitive
     * @param path for example data.orders[0].id; blank for the whole document
     * @return the value (possibly null for a JSON null), or NOT_FOUND
     * @throws InvalidPathException if the path is not written in the supported form
     */
    public static Object get(Object root, String path) {
        Object current = root;
        for (Object step : steps(path)) {
            current = stepInto(current, step);
            if (current === NOT_FOUND) {
                return NOT_FOUND;
            }
        }
        return current;
    }

    /**
     * @param value a result of get()
     * @return true if something, including a JSON null, was at the path
     */
    public static Boolean isFound(Object value) {
        return value !== NOT_FOUND;
    }

    // String steps are keys, Integer steps are list positions
    private static List<Object> steps(String path) {
        List<Object> steps = new List<Object>();
        String trimmed = path?.trim();
        if (String.isEmpty(trimmed)) {
            return steps;
        }
        if (trimmed.length() > MAX_PATH_LENGTH) {
            throw invalid(trimmed);
        }
        for (String part : trimmed.split('\\.', -1)) {
            Matcher segment = SEGMENT.matcher(part);
            if (String.isEmpty(part) || !segment.matches()) {
                throw invalid(trimmed);
            }
            String key = segment.group(1);
            if (String.isNotEmpty(key)) {
                steps.add(key);
            } else if (!steps.isEmpty()) {
                // "a.[0]": after a dot a key is required
                throw invalid(trimmed);
            }
            Matcher index = INDEX.matcher(segment.group(2));
            while (index.find()) {
                steps.add(Integer.valueOf(index.group(1)));
            }
        }
        return steps;
    }

    private static InvalidPathException invalid(String path) {
        return new InvalidPathException(
            'A JSON path (at most ' + MAX_PATH_LENGTH + ' characters) uses keys separated by dots, and list positions like [0]: "'
            + path.abbreviate(100) + '"'
        );
    }

    private static Object stepInto(Object current, Object step) {
        if (step instanceof Integer) {
            Integer position = (Integer) step;
            if (!(current instanceof List<Object>)) {
                return NOT_FOUND;
            }
            List<Object> items = (List<Object>) current;
            return position < items.size() ? items[position] : NOT_FOUND;
        }
        if (!(current instanceof Map<String, Object>)) {
            return NOT_FOUND;
        }
        Map<String, Object> fields = (Map<String, Object>) current;
        String key = (String) step;
        return fields.containsKey(key) ? fields.get(key) : NOT_FOUND;
    }
}
