@IsTest
private with sharing class JsonPathTest {
    private static final String SAMPLE =
        '{"data": {"orders": [' +
        '{"id": "A1", "total": 99.5, "paid": true, "customer": {"email": "a@example.com", "first-name": "Ann"}},' +
        '{"id": "A2", "total": 10, "paid": false, "note": null}' +
        ']}, "matrix": [[1, 2], [3, 4]], "count": 2}';

    private static Object sample() {
        return JSON.deserializeUntyped(SAMPLE);
    }

    @IsTest
    static void readsNestedKeysAndListPositions() {
        Object root = sample();

        Assert.areEqual('A1', JsonPath.get(root, 'data.orders[0].id'), 'Key in a list item');
        Assert.areEqual('a@example.com', JsonPath.get(root, 'data.orders[0].customer.email'), 'Deep key');
        Assert.areEqual('Ann', JsonPath.get(root, 'data.orders[0].customer.first-name'), 'Key with a dash');
        Assert.areEqual(99.5, JsonPath.get(root, 'data.orders[0].total'), 'Decimal');
        Assert.areEqual(true, JsonPath.get(root, 'data.orders[0].paid'), 'Boolean');
        Assert.areEqual(3, JsonPath.get(root, 'matrix[1][0]'), 'List inside a list');
        Assert.areEqual(2, ((List<Object>) JsonPath.get(root, 'data.orders')).size(), 'A whole list');
    }

    @IsTest
    static void blankPathIsTheWholeDocument() {
        Object root = sample();

        Assert.areEqual(root, JsonPath.get(root, ''), 'Empty path');
        Assert.areEqual(root, JsonPath.get(root, null), 'Null path');
    }

    @IsTest
    static void readsFromADocumentThatIsAList() {
        Object root = JSON.deserializeUntyped('[{"id": "X"}, {"id": "Y"}]');

        Assert.areEqual('Y', JsonPath.get(root, '[1].id'), 'Root list position, then key');
    }

    @IsTest
    static void nothingThereIsNotFoundNotAnError() {
        Object root = sample();
        List<String> missingPaths = new List<String>{
            'data.missing',
            'data.orders[5].id',
            'data.orders.id',
            'data[0]',
            'count.value',
            'data.orders[0].customer.email.domain',
            'matrix[0][9]'
        };

        for (String path : missingPaths) {
            Object value = JsonPath.get(root, path);
            Assert.isTrue(value === JsonPath.NOT_FOUND, 'Not found: ' + path);
            Assert.isFalse(JsonPath.isFound(value), 'isFound is false: ' + path);
        }
    }

    @IsTest
    static void aJsonNullIsFoundAndDifferentFromMissing() {
        Object root = sample();

        Object explicitNull = JsonPath.get(root, 'data.orders[1].note');
        Object missing = JsonPath.get(root, 'data.orders[0].note');

        Assert.isNull(explicitNull, 'A JSON null reads as null');
        Assert.isTrue(JsonPath.isFound(explicitNull), 'A JSON null was found');
        Assert.isFalse(JsonPath.isFound(missing), 'A missing key was not found');
    }

    @IsTest
    static void rejectsPathsNotInTheSupportedForm() {
        List<String> invalidPaths = new List<String>{
            'a..b',
            'a.',
            '.a',
            '.',
            'a[x]',
            'a[-1]',
            'a[1234567890]',
            'a]',
            'a[0]b',
            '[0]x',
            'a[]',
            'a[0',
            'a.[0]'
        };

        for (String path : invalidPaths) {
            try {
                JsonPath.get(sample(), path);
                Assert.fail('Expected InvalidPathException for ' + path);
            } catch (JsonPath.InvalidPathException e) {
                Assert.isTrue(e.getMessage().contains('"' + path + '"'), 'Names the path: ' + e.getMessage());
            }
        }
    }

    @IsTest
    static void rejectsOverlongPathsBeforeParsingAndKeepsTheMessageShort() {
        String overlong = 'a' + '[0]'.repeat(100000);

        try {
            JsonPath.get(sample(), overlong);
            Assert.fail('Expected InvalidPathException');
        } catch (JsonPath.InvalidPathException e) {
            Assert.isTrue(e.getMessage().length() <= 255, 'Message fits a 255-character field: ' + e.getMessage().length());
        }
    }

    @IsTest
    static void keysMayHoldAnyCharacterButDotsAndBrackets() {
        Object root = JSON.deserializeUntyped('{"$id": 1, "@type": "x", "first name": "Ann", "naïve": true, "7": "seven"}');

        Assert.areEqual(1, JsonPath.get(root, '$id'), 'Dollar sign');
        Assert.areEqual('x', JsonPath.get(root, '@type'), 'At sign');
        Assert.areEqual('Ann', JsonPath.get(root, 'first name'), 'Inner space');
        Assert.areEqual(true, JsonPath.get(root, 'naïve'), 'Accented letter');
        Assert.areEqual('seven', JsonPath.get(root, '7'), 'A digit-only key is a key, not a list position');
        Assert.areEqual('Ann', JsonPath.get(root, '  first name  '), 'Surrounding whitespace is ignored');
    }

    @IsTest
    static void edgeCasesAreNotFoundRatherThanErrors() {
        Object root = sample();

        Assert.isFalse(JsonPath.isFound(JsonPath.get(root, 'data.orders[1].note.x')), 'Step into a JSON null');
        Assert.isFalse(JsonPath.isFound(JsonPath.get(null, 'a')), 'Null document');
        Assert.isFalse(JsonPath.isFound(JsonPath.get(root, 'matrix[999999999]')), 'Largest allowed position');
        Assert.isFalse(JsonPath.isFound(JsonPath.get(root, 'data.orders.0')), 'A digit key on a list');
    }

    @IsTest
    static void largeWholeNumbersAreLongs() {
        Object value = JsonPath.get(JSON.deserializeUntyped('{"big": 9999999999, "small": 10, "fraction": 10.5}'), 'big');

        Assert.isTrue(value instanceof Long, 'Large whole numbers parse as Long; merging must handle Integer, Long and Decimal');
        Assert.areEqual(9999999999L, value, 'Value');
    }

    @IsTest
    static void readsAValueFromEachOfTwoHundredListItems() {
        List<Object> items = new List<Object>();
        for (Integer i = 0; i < 200; i++) {
            items.add(new Map<String, Object>{ 'id' => 'ID-' + i, 'address' => new Map<String, Object>{ 'zip' => 1000 + i } });
        }
        Object root = new Map<String, Object>{ 'items' => items };

        Test.startTest();
        List<Object> zips = new List<Object>();
        for (Object item : (List<Object>) JsonPath.get(root, 'items')) {
            zips.add(JsonPath.get(item, 'address.zip'));
        }
        Test.stopTest();

        Assert.areEqual(200, zips.size(), 'One value per item');
        Assert.areEqual(1199, zips[199], 'Last item');
    }
}
