@IsTest
private with sharing class MergeTemplateTest {
    private static Map<String, Object> mergeOne(String template, Id recordId) {
        MergeTemplate.Result result = MergeTemplate.render(template, new Set<Id>{ recordId }).get(recordId);
        Assert.isNull(result.error, 'No error expected: ' + result.error);
        return (Map<String, Object>) JSON.deserializeUntyped(result.body);
    }

    private static String errorFor(String template, Id recordId) {
        MergeTemplate.Result result = MergeTemplate.render(template, new Set<Id>{ recordId }).get(recordId);
        Assert.isNull(result.body, 'No body when there is an error');
        return result.error;
    }

    private static void assertRejected(String template, Id recordId, String expected) {
        try {
            MergeTemplate.render(template, new Set<Id>{ recordId });
            Assert.fail('Expected MergeException for ' + template);
        } catch (MergeTemplate.MergeException e) {
            Assert.isTrue(e.getMessage().contains(expected), template + ' -> ' + e.getMessage());
        }
    }

    @IsTest
    static void mergesFieldsAndParentFieldsAsText() {
        Account account = new Account(Name = 'Acme');
        insert account;
        Contact contact = new Contact(FirstName = 'Ann', LastName = 'Lee', AccountId = account.Id);
        insert contact;

        Map<String, Object> body = mergeOne(
            '{"company": "{{Account.Name}}", "name": "{{ LastName }}", "greeting": "Hi {{FirstName}}!", "nested": {"id": "{{Id}}"}}',
            contact.Id
        );

        Assert.areEqual('Acme', body.get('company'), 'Parent field');
        Assert.areEqual('Lee', body.get('name'), 'Spaces inside the braces are ignored');
        Assert.areEqual('Hi Ann!', body.get('greeting'), 'Inside other text');
        Assert.areEqual(contact.Id, ((Map<String, Object>) body.get('nested')).get('id'), 'Nested object closing in }}');
    }

    @IsTest
    static void bareMergeFieldsAreJsonValuesAndQuotedOnesText() {
        Account account = new Account(Name = 'Acme', AnnualRevenue = 99.5, NumberOfEmployees = 50);
        insert account;

        Map<String, Object> body = mergeOne(
            '{"revenue": {{AnnualRevenue}}, "staff": "{{NumberOfEmployees}}", "phone": {{Phone}}, "fax": "{{Fax}}", "created": {{CreatedDate}}}',
            account.Id
        );

        Assert.areEqual(99.5, body.get('revenue'), 'Bare number');
        Assert.areEqual('50', body.get('staff'), 'Quoted number is text');
        Assert.isTrue(body.containsKey('phone') && body.get('phone') == null, 'Bare empty value is null');
        Assert.areEqual('', body.get('fax'), 'Quoted empty value is empty text');
        Assert.isTrue(((String) body.get('created')).endsWith('Z'), 'Date/time is ISO 8601 in GMT');
    }

    @IsTest
    static void missingParentMergesAsEmpty() {
        Contact contact = new Contact(LastName = 'Solo');
        insert contact;

        Map<String, Object> body = mergeOne('{"text": "{{Account.Name}}", "value": {{Account.Name}}}', contact.Id);

        Assert.areEqual('', body.get('text'), 'Quoted');
        Assert.isNull(body.get('value'), 'Bare');
    }

    @IsTest
    static void escapesValuesSoTheyCannotBreakOutOfTheirString() {
        String tricky = 'x", "admin": true, "y": "a\\b\nline';
        Account account = new Account(Name = 'Acme', Description = tricky);
        insert account;

        Map<String, Object> body = mergeOne('{"note": "Say: {{Description}}", "raw": {{Description}}}', account.Id);

        Assert.areEqual(new Set<String>{ 'note', 'raw' }, body.keySet(), 'No keys injected');
        Assert.areEqual('Say: ' + tricky, body.get('note'), 'Text kept exactly');
        Assert.areEqual(tricky, body.get('raw'), 'Bare text kept exactly');
    }

    @IsTest
    static void escapedQuotesInTheTemplateAreFollowed() {
        Account account = new Account(Name = 'Acme');
        insert account;

        Map<String, Object> body = mergeOne('{"q": "He said \\"{{Name}}\\"", "v": {{Name}}}', account.Id);

        Assert.areEqual('He said "Acme"', body.get('q'), 'Still inside the string after \\"');
        Assert.areEqual('Acme', body.get('v'), 'Outside the string again');
        Assert.areEqual('Acme', mergeOne('{"q": "a\\\\", "v": {{Name}}}', account.Id).get('v'), 'An escaped backslash ends no string');
    }

    @IsTest
    static void rejectsCredentialSyntaxInTheTemplate() {
        Account account = new Account(Name = 'Acme');
        insert account;

        assertRejected('{"key": "{!$Credential.X.ApiKey}"}', account.Id, '{!');
    }

    @IsTest
    static void rejectsCredentialSyntaxComingFromRecordData() {
        Account account = new Account(Name = '{!$Credential.Httpbin_ApiKey_Auth.ApiKey}');
        insert account;

        String error = errorFor('{"name": "{{Name}}"}', account.Id);

        Assert.isTrue(error.contains('{!'), error);
        Assert.isFalse(error.contains('Credential'), 'The value is not repeated: ' + error);
    }

    @IsTest
    static void rejectsTemplatesNotInTheSupportedForm() {
        Contact contact = new Contact(LastName = 'Lee');
        insert contact;
        Map<String, String> templates = new Map<String, String>{
            '' => 'empty',
            '{"a": "{{}}"}' => 'Not a merge field',
            '{"a": "{{Last Name}}"}' => 'Not a merge field',
            '{"a": "{{Account..Name}}"}' => 'Not a merge field',
            '{"a": "{{1Name}}"}' => 'Not a merge field',
            // A literal { just before a merge field could otherwise combine with a value starting with !
            '{"a": "{{{LastName}}"}' => 'Not a merge field',
            '{"a": "{{A.B.C.D.E.F.Name}}"}' => 'Not a merge field',
            '{"a": "{{Nope}}"}' => 'Unknown field on Contact: Nope',
            '{"a": "{{Nope.Name}}"}' => 'Unknown relationship on Contact: Nope',
            '{"a": "{{LastName.Name}}"}' => 'Unknown relationship',
            '{"a": "{{Account.Nope}}"}' => 'Unknown field on Account: Nope',
            '{"a": "{{LastName"}' => 'not part of a {{Field}}'
        };

        for (String template : templates.keySet()) {
            assertRejected(template, contact.Id, templates.get(template));
        }
    }

    @IsTest
    static void reportsBodiesThatAreNotJsonOrTooLongPerRecord() {
        Account account = new Account(Name = 'Acme', Description = 'x'.repeat(32000));
        insert account;

        String notJson = errorFor('{"a": {{Name}}x}', account.Id);
        String tooLong = errorFor('["{{Description}}", "{{Description}}", "{{Description}}", "{{Description}}", "{{Description}}"]', account.Id);

        Assert.isTrue(notJson.contains('not valid JSON'), notJson);
        Assert.isTrue(tooLong.contains('131072'), tooLong);
    }

    @IsTest
    static void aBadRecordLeavesItsNeighboursIntact() {
        Account good = new Account(Name = 'Good');
        Account secret = new Account(Name = '{!$Credential.X.ApiKey}');
        // Split across two merge fields, { and ! still meet in the body
        Account split = new Account(Name = '{', Description = '!$Credential.X.ApiKey}');
        insert new List<Account>{ good, secret, split };

        Map<Id, MergeTemplate.Result> results = MergeTemplate.render(
            '{"n": "{{Name}}{{Description}}"}',
            new Set<Id>{ good.Id, secret.Id, split.Id }
        );

        Assert.areEqual('{"n": "Good"}', results.get(good.Id).body, 'Good record built');
        Assert.isTrue(results.get(secret.Id).error.contains('{!'), results.get(secret.Id).error);
        Assert.isTrue(results.get(split.Id).error.contains('{!'), results.get(split.Id).error);
    }

    @IsTest
    static void rejectsFieldsAndRelationshipsThatAreNotOneValue() {
        Account account = new Account(Name = 'Acme');
        insert account;
        Case supportCase = new Case(Subject = 'S');
        insert supportCase;

        assertRejected('{"a": "{{BillingAddress}}"}', account.Id, 'address, location or file');
        assertRejected('{"a": "{{Owner.Name}}"}', supportCase.Id, 'several objects');
        assertRejected('{"a": "x\\\\\\{{Name}}"}', account.Id, 'backslash');
    }

    @IsTest
    static void rejectsUnknownIdsAndTooManyRecords() {
        Set<Id> tooMany = new Set<Id>();
        for (Integer i = 0; i < 201; i++) {
            tooMany.add(Id.valueOf('001000000000' + String.valueOf(i).leftPad(3, '0')));
        }

        // Key prefix 000 names no object
        assertRejected('{}', Id.valueOf('000' + '0'.repeat(11) + '1'), 'no object');
        try {
            MergeTemplate.render('{}', tooMany);
            Assert.fail('Expected MergeException');
        } catch (MergeTemplate.MergeException e) {
            Assert.isTrue(e.getMessage().contains('At most 200'), e.getMessage());
        }
    }

    @IsTest
    static void unknownRecordIsAnErrorForThatRecordOnly() {
        Account kept = new Account(Name = 'Kept');
        Account deleted = new Account(Name = 'Deleted');
        insert new List<Account>{ kept, deleted };
        delete deleted;

        Map<Id, MergeTemplate.Result> results = MergeTemplate.render('{"n": "{{Name}}"}', new Set<Id>{ kept.Id, deleted.Id });

        Assert.areEqual('{"n": "Kept"}', results.get(kept.Id).body, 'Other record built');
        Assert.isTrue(results.get(deleted.Id).error.contains('not found'), results.get(deleted.Id).error);
    }

    @IsTest
    static void rejectsIdsOfMoreThanOneObjectAndMissingIds() {
        Account account = new Account(Name = 'Acme');
        insert account;
        Contact contact = new Contact(LastName = 'Lee');
        insert contact;

        try {
            MergeTemplate.render('{}', new Set<Id>{ account.Id, contact.Id });
            Assert.fail('Expected MergeException');
        } catch (MergeTemplate.MergeException e) {
            Assert.isTrue(e.getMessage().contains('one object'), e.getMessage());
        }
        assertRejected('{}', null, 'missing');
        Assert.isTrue(MergeTemplate.render('{}', new Set<Id>()).isEmpty(), 'No Ids, no results');
    }

    @IsTest
    static void readsWithTheRunningUsersAccess() {
        User runner = ReplayrTestAccess.createRunner();
        User outsider = ReplayrTestAccess.newUser(ReplayrTestAccess.minimalProfileId(), ReplayrTestAccess.username('outsider'));
        System.runAs(new User(Id = UserInfo.getUserId())) {
            insert outsider;
        }
        Provider__c provider = new Provider__c(Name = 'P', Named_Credential__c = 'Test_API');
        System.runAs(runner) {
            insert provider;
            Assert.isNull(MergeTemplate.render('{"n": "{{Name}}"}', new Set<Id>{ provider.Id }).get(provider.Id).error, 'Runner reads it');
        }

        System.runAs(outsider) {
            assertRejected('{"n": "{{Name}}"}', provider.Id, 'running user');
        }
    }

    @IsTest
    static void ifChoosesOnBlankAndNotBlank() {
        Account withPhone = new Account(Name = 'A', Phone = '555', Fax = '777');
        Account noPhone = new Account(Name = 'B', Fax = '777');
        insert new List<Account>{ withPhone, noPhone };
        String template =
            '{"tel": "{{IF(ISBLANK(Phone), Fax, Phone)}}", "has": {{if ( not ( isblank ( Phone ) ) , \'yes\' , \'no\' )}},' +
            ' "say": "Call {{IF(ISBLANK(Phone), \'nobody\', Name)}}"}';

        Map<String, Object> first = mergeOne(template, withPhone.Id);
        Map<String, Object> second = mergeOne(template, noPhone.Id);

        Assert.areEqual('555', first.get('tel'), 'Not blank: then is skipped, else used');
        Assert.areEqual('777', second.get('tel'), 'Blank: then used');
        Assert.areEqual('yes', first.get('has'), 'NOT(ISBLANK), any case and spacing, bare text literal');
        Assert.areEqual('no', second.get('has'), 'NOT(ISBLANK) false');
        Assert.areEqual('Call A', first.get('say'), 'Inside other text');
        Assert.areEqual('Call nobody', second.get('say'), 'Literal inside other text');
    }

    @IsTest
    static void ifComparesTextIgnoringCaseAndNumbersByValue() {
        Account account = new Account(Name = 'Acme', AnnualRevenue = 100);
        insert account;
        Contact contact = new Contact(FirstName = 'Lee', LastName = 'Lee', DoNotCall = true, AccountId = account.Id);
        insert contact;

        Map<String, Object> body = mergeOne(
            '{"exact": "{{IF(Account.Name = \'Acme\', \'y\', \'n\')}}", "case": "{{IF(Account.Name = \'acme\', \'y\', \'n\')}}",' +
            ' "differs": "{{IF(Account.Name != \'Other\', \'y\', \'n\')}}", "number": "{{IF(Account.AnnualRevenue = \'100.00\', \'y\', \'n\')}}",' +
            ' "checkbox": "{{IF(DoNotCall = \'true\', \'y\', \'n\')}}", "fields": "{{IF(FirstName = LastName, \'y\', \'n\')}}",' +
            ' "value": {{IF(DoNotCall != \'true\', Account.AnnualRevenue, Account.Name)}}}',
            contact.Id
        );

        Assert.areEqual('y', body.get('exact'), '= on text');
        Assert.areEqual('y', body.get('case'), 'Text ignores case, as in formulas');
        Assert.areEqual('y', body.get('differs'), '!=');
        Assert.areEqual('y', body.get('number'), '100 = 100.00');
        Assert.areEqual('y', body.get('checkbox'), 'Checkbox as true/false');
        Assert.areEqual('y', body.get('fields'), 'Field to field');
        Assert.areEqual('Acme', body.get('value'), 'Else branch, bare field');
    }

    @IsTest
    static void ifEdgeCasesOfBlankNumbersDatesAndQuotes() {
        Account account = new Account(Name = 'Acme', AnnualRevenue = 7, Fax = '007', Phone = '  ', BillingLatitude = 1.5, BillingLongitude = 2);
        insert account;
        Contact contact = new Contact(LastName = 'Lee', Birthdate = Date.newInstance(2000, 1, 31), AccountId = account.Id);
        insert contact;

        Map<String, Object> body = mergeOne(
            '{"nullIsEmpty": "{{IF(Email = \'\', \'y\', \'n\')}}", "notEmpty": "{{IF(Email != \'\', \'y\', \'n\')}}",' +
            ' "spaces": "{{IF(ISBLANK(Account.Phone), \'y\', \'n\')}}", "date": "{{IF(Birthdate = \'2000-01-31\', \'y\', \'n\')}}",' +
            ' "padded": "{{IF(Account.AnnualRevenue = \' 7 \', \'y\', \'n\')}}", "textNumber": "{{IF(Account.AnnualRevenue = Account.Fax, \'y\', \'n\')}}",' +
            ' "double": "{{IF(Account.BillingLatitude = \'1.50\', \'y\', \'n\')}}",' +
            ' "quoted": "{{IF(ISBLANK(Email), \'say "hi"\', LastName)}}", "bareQuoted": {{IF(ISBLANK(Email), \'say "hi"\', LastName)}}}',
            contact.Id
        );

        Assert.areEqual('y', body.get('nullIsEmpty'), 'A blank value equals empty text');
        Assert.areEqual('n', body.get('notEmpty'), 'and != empty text is false');
        Assert.areEqual('y', body.get('spaces'), 'Only spaces is blank');
        Assert.areEqual('y', body.get('date'), 'Dates as 2026-10-27');
        Assert.areEqual('n', body.get('padded'), 'Padded text is not a plain number');
        Assert.areEqual('y', body.get('textNumber'), 'Number field against plain number text: 7 = 007');
        Assert.areEqual('y', body.get('double'), 'Latitude (a double) by value');
        Assert.areEqual('say "hi"', body.get('quoted'), 'Quote in a literal is escaped inside a string');
        Assert.areEqual('say "hi"', body.get('bareQuoted'), 'and as a bare value');
    }

    @IsTest
    static void ifBranchValuesStillPassTheCredentialCheck() {
        Account account = new Account(Name = 'Acme', Description = '{!$Credential.X.ApiKey}');
        insert account;

        String error = errorFor('{"d": "{{IF(ISBLANK(Phone), Description, Name)}}"}', account.Id);

        Assert.isTrue(error.contains('{!'), error);
    }

    @IsTest
    static void rejectsIfsNotInTheSupportedForm() {
        Account account = new Account(Name = 'Acme');
        insert account;
        List<String> invalid = new List<String>{
            'IF(Name, \'a\', \'b\')',
            'IF(Name = \'a\', \'b\')',
            'IF(Name > \'a\', \'b\', \'c\')',
            'IF(Name = "a", \'b\', \'c\')',
            'IF(Name = \'it\'s\', \'b\', \'c\')',
            'IF(Name = \'a\', IF(Name = \'b\', \'c\', \'d\'), \'e\')',
            'IF(ISBLANK(Name) = \'a\', \'b\', \'c\')',
            'IF(Name = \'a\', \'b\', \'c\') x',
            'IF(Name = \'a\', \'b\', \'c\'',
            'IF(Name = \'a\\\\\', \'b\', \'c\')',
            'IF(Name = \'it\'\'s\', \'b\', \'c\')'
        };

        for (String content : invalid) {
            assertRejected('{"a": "{{' + content + '}}"}', account.Id, 'Not a valid IF');
        }
        assertRejected('{"a": "{{IF(Nope = \'a\', \'b\', \'c\')}}"}', account.Id, 'Unknown field on Account: Nope');
    }

    @IsTest
    static void buildsTwoHundredBodiesWithOneQuery() {
        Account parent = new Account(Name = 'Parent');
        insert parent;
        List<Contact> contacts = new List<Contact>();
        for (Integer i = 0; i < 200; i++) {
            contacts.add(new Contact(LastName = 'Lee ' + i, AccountId = parent.Id));
        }
        insert contacts;
        Set<Id> contactIds = new Map<Id, Contact>(contacts).keySet();

        Test.startTest();
        Map<Id, MergeTemplate.Result> results = MergeTemplate.render(
            '{"n": "{{LastName}}", "a": "{{Account.Name}}", "p": "{{IF(ISBLANK(Phone), \'none\', Phone)}}"}',
            contactIds
        );
        Integer queries = Limits.getQueries();
        Test.stopTest();

        Assert.areEqual(1, queries, 'One query for all records');
        Assert.areEqual(200, results.size(), 'A result per record');
        Assert.areEqual('{"n": "Lee 199", "a": "Parent", "p": "none"}', results.get(contacts[199].Id).body, 'Last record');
    }
}
