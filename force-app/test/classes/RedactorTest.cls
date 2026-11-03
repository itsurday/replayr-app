@IsTest
private with sharing class RedactorTest {
    private static final Redactor BUILT_IN_ONLY = new Redactor(null);

    @IsTest
    static void builtInNamesAreMaskedInsideLongerNames() {
        for (String name : new List<String>{
            'Authorization', 'Set-Cookie', 'password', 'new_password', 'client_secret', 'refreshToken', 'x-auth-token',
            'access_token', 'apiKey', 'API-KEY', 'x_api_key', 'private_key'
        }) {
            Assert.isTrue(BUILT_IN_ONLY.isMasked(name), 'Masked: ' + name);
        }
        for (String name : new List<String>{ 'name', 'email', 'Idempotency-Key', 'Content-Type', 'key', '', null }) {
            Assert.isFalse(BUILT_IN_ONLY.isMasked(name), 'Shown: ' + name);
        }
    }

    @IsTest
    static void configuredNamesMatchExactlyIgnoringCase() {
        Redactor redactor = new Redactor('customer_pin,\n X-Shop-Signature \r\n,,');

        Assert.isTrue(redactor.isMasked('customer_pin'), 'Exact');
        Assert.isTrue(redactor.isMasked('CUSTOMER_PIN'), 'Case ignored');
        Assert.isTrue(redactor.isMasked('x-shop-signature'), 'Spaces around a name ignored');
        Assert.isFalse(redactor.isMasked('customer_pin2'), 'Not a longer name');
        Assert.isTrue(redactor.isMasked('password'), 'Built-ins still apply');
    }

    @IsTest
    static void masksJsonValuesAtAnyDepthAndKeepsTheLayout() {
        String body = '{\n  "name": "Ada",\n  "password": "hunter2",\n  "card": {"pin": 1234, "token": "t-1"},\n' +
            '  "items": [{"apiKey": "k1"}, {"apiKey": "k2"}],\n  "active": true\n}';
        String expected = '{\n  "name": "Ada",\n  "password": "****",\n  "card": {"pin": "****", "token": "****"},\n' +
            '  "items": [{"apiKey": "****"}, {"apiKey": "****"}],\n  "active": true\n}';

        Assert.areEqual(expected, new Redactor('pin').json(body), 'Masked in place, layout kept');
    }

    @IsTest
    static void masksAWholeObjectOrListUnderAMaskedKey() {
        Assert.areEqual(
            '{"secret": "****", "next": 1}',
            BUILT_IN_ONLY.json('{"secret": {"a": [1, {"b": "}"}], "c": "x"}, "next": 1}'),
            'Brackets inside strings ignored'
        );
        Assert.areEqual('{"tokens": "****"}', BUILT_IN_ONLY.json('{"tokens": ["a", "b"]}'), 'List masked whole');
    }

    @IsTest
    static void stringContentIsNeverReadAsAKey() {
        String body = '{"note": "\\"password\\": \\"x\\"", "name": "a \\"quoted\\" word"}';

        Assert.areEqual(body, BUILT_IN_ONLY.json(body), 'Escaped quotes inside values left alone');
        Assert.areEqual('{"pass\\"word": "x"}', BUILT_IN_ONLY.json('{"pass\\"word": "x"}'), 'An escaped quote makes a different name');
    }

    @IsTest
    static void keysSpelledWithEscapesAreDecodedFirst() {
        Assert.areEqual('{"pass\\u0077ord": "****"}', BUILT_IN_ONLY.json('{"pass\\u0077ord": "hunter2"}'), 'Unicode escape');
        Assert.areEqual('{"\\u0074oken": "****"}', BUILT_IN_ONLY.json('{"\\u0074oken": "x"}'), 'Escape at the start');
        Assert.areEqual('{"pass\\word": "****"}', BUILT_IN_ONLY.json('{"pass\\word": "x"}'), 'Malformed escape still compared');
    }

    @IsTest
    static void masksEveryKindOfValueWhateverTheSpacing() {
        Assert.areEqual(
            '{"password" : "****", "token"\n:\t"****", "secret": "****", "session": "****", "signature": "****"}',
            BUILT_IN_ONLY.json('{"password" : true, "token"\n:\tnull, "secret": 0.5, "session": "s", "signature": ""}'),
            'Booleans, null, numbers and empty strings; whitespace before the colon'
        );
        Assert.areEqual('{"password": ,"x": 1}', BUILT_IN_ONLY.json('{"password": ,"x": 1}'), 'A missing value is left alone');
        Assert.areEqual('{"name": "Zoë ✓", "tokén": "x"}', BUILT_IN_ONLY.json('{"name": "Zoë ✓", "tokén": "x"}'), 'Non-ASCII passes through');
    }

    @IsTest
    static void masksFormEncodedBodiesAndMessages() {
        Assert.areEqual('password=****&name=Ada;token=****', BUILT_IN_ONLY.json('password=hunter2&name=Ada;token=t'), 'Form body');
        Assert.areEqual('just text', BUILT_IN_ONLY.json('just text'), 'Plain text');
        Assert.areEqual(
            'Unable to reach callout:Shop/x?api_key=**** (timeout) for secret=****',
            BUILT_IN_ONLY.message('Unable to reach callout:Shop/x?api_key=abc (timeout) for secret=s'),
            'URL and pair in a message'
        );
        Assert.isNull(BUILT_IN_ONLY.message(null), 'Null');
        Assert.areEqual('Bad body {"token": "****"}', BUILT_IN_ONLY.message('Bad body {"token": "t"}'), 'JSON in a message');
    }

    @IsTest
    static void cutOrBrokenTextNeverFails() {
        Assert.areEqual('{"password": "****"', BUILT_IN_ONLY.json('{"password": "abc'), 'Cut inside a masked value');
        Assert.areEqual('{"password": ', BUILT_IN_ONLY.json('{"password": '), 'Cut before the value');
        Assert.areEqual('{"passw', BUILT_IN_ONLY.json('{"passw'), 'Cut inside a key');
        Assert.areEqual('not json', BUILT_IN_ONLY.json('not json'), 'Plain text');
        Assert.isNull(BUILT_IN_ONLY.json(null), 'Null');
        Assert.areEqual('{"secret": "****"', BUILT_IN_ONLY.json('{"secret": {"a": 1'), 'Unclosed object masked to the end');
    }

    @IsTest
    static void masksUrlQueryValues() {
        Assert.areEqual(
            'callout:Shop/orders?api_key=****&page=2&token=****',
            BUILT_IN_ONLY.url('callout:Shop/orders?api_key=abc&page=2&token=xyz'),
            'Masked values only'
        );
        Assert.areEqual('callout:Shop/x?api%5Fkey=****', BUILT_IN_ONLY.url('callout:Shop/x?api%5Fkey=abc'), 'Encoded names decoded first');
        Assert.areEqual('callout:Shop/x?flag&token=****', BUILT_IN_ONLY.url('callout:Shop/x?flag&token='), 'A masked empty value says so too');
        Assert.areEqual('callout:Shop/x', BUILT_IN_ONLY.url('callout:Shop/x'), 'No query');
        Assert.areEqual('callout:Shop/x?%zz=1', BUILT_IN_ONLY.url('callout:Shop/x?%zz=1'), 'Malformed escape left alone');
        Assert.areEqual('callout:Shop/x?a=1#access_token=****', BUILT_IN_ONLY.url('callout:Shop/x?a=1#access_token=abc'), 'Fragment');
        Assert.areEqual('callout:Shop/x?a=1;token=****', BUILT_IN_ONLY.url('callout:Shop/x?a=1;token=abc'), 'Semicolon separator');
        Assert.areEqual('callout:Shop/x?api+key=****', BUILT_IN_ONLY.url('callout:Shop/x?api+key=abc'), 'Plus is a space');
        Assert.isNull(BUILT_IN_ONLY.url(null), 'Null');
    }

    @IsTest
    static void masksHeaderValues() {
        Map<String, String> masked = new Redactor('X-Shop-Signature').headers(
            new Map<String, String>{ 'Content-Type' => 'application/json', 'X-Shop-Signature' => 'sig', 'Authorization' => 'Bearer x' }
        );

        Assert.areEqual('application/json', masked.get('Content-Type'), 'Shown');
        Assert.areEqual(Redactor.MASK, masked.get('X-Shop-Signature'), 'Configured');
        Assert.areEqual(Redactor.MASK, masked.get('Authorization'), 'Built-in');
    }

    @IsTest
    static void handlesTheLargestStoredBody() {
        List<String> items = new List<String>();
        // About 1,500 items fill most of Request Body's 131,072 characters
        for (Integer i = 0; i < 1500; i++) {
            items.add('{"id": ' + i + ', "token": "t' + i + '", "note": "' + 'x'.repeat(40) + '"}');
        }
        String body = '[' + String.join(items, ', ') + ']';
        Assert.isTrue(body.length() > 100000 && body.length() <= 131072, 'Near the field limit: ' + body.length());

        Integer cpuBefore = Limits.getCpuTime();
        String masked = BUILT_IN_ONLY.json(body);
        Integer cpu = Limits.getCpuTime() - cpuBefore;

        Assert.isTrue(cpu < 5000, 'Well inside the 10-second limit: ' + cpu + ' ms');
        Assert.isFalse(masked.contains('"t1499"') || masked.contains('"t0"'), 'Every token masked');
        Assert.isTrue(masked.contains('"id": 1499'), 'Other values kept');
    }
}
