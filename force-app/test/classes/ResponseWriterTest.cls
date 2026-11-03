@IsTest
private with sharing class ResponseWriterTest {
    private static final String CONTACT_RULES = '{"fields": {"LastName": "name.last", "Email": "email", "Title": "title"}}';

    private static Mapping__c mapping(String objectName, String operation, String matchField, String listPath, String rules) {
        return new Mapping__c(
            Direction__c = 'Response',
            Target_Object__c = objectName,
            Operation__c = operation,
            Match_Field__c = matchField,
            List_Path__c = listPath,
            Rules__c = rules
        );
    }

    private static String person(String last, String email, String title) {
        return '{"name": {"last": "' + last + '"}, "email": "' + email + '", "title": "' + title + '"}';
    }

    private static void assertRejected(Mapping__c rejected, String body, Id recordId, String expected) {
        try {
            ResponseWriter.write(rejected, body, recordId);
            Assert.fail('Expected WriteException: ' + expected);
        } catch (ResponseWriter.WriteException e) {
            Assert.isTrue(e.getMessage().contains(expected), expected + ' -> ' + e.getMessage());
        }
    }

    @IsTest
    static void insertsOneRecordPerItemFromNestedJson() {
        String body = '{"data": {"people": [' + person('Ann', 'ann@example.com', 'CEO') + ', ' + person('Bo', 'bo@example.com', 'CTO') + ']}}';

        ResponseWriter.Outcome outcome = ResponseWriter.write(mapping('Contact', 'Insert', null, 'data.people', CONTACT_RULES), body, null);

        Assert.areEqual(2, outcome.saved, 'Both saved: ' + outcome.errors);
        Assert.isTrue(outcome.errors.isEmpty(), 'No errors');
        Contact bo = [SELECT Email, Title FROM Contact WHERE LastName = 'Bo'];
        Assert.areEqual('bo@example.com', bo.Email, 'Top-level key');
        Assert.areEqual('CTO', bo.Title, 'Value');
    }

    @IsTest
    static void wholeBodyIsOneItemWhenListPathIsBlank() {
        ResponseWriter.Outcome outcome = ResponseWriter.write(
            mapping('Contact', 'Insert', null, null, CONTACT_RULES),
            person('Solo', 'solo@example.com', 'CFO'),
            null
        );

        Assert.areEqual(1, outcome.saved, 'Saved: ' + outcome.errors);
        Assert.areEqual(1, [SELECT COUNT() FROM Contact WHERE LastName = 'Solo'], 'Inserted');

        ResponseWriter.Outcome wrapped = ResponseWriter.write(
            mapping('Contact', 'Insert', null, 'person', CONTACT_RULES),
            '{"person": ' + person('Wrapped', 'w@example.com', 'x') + '}',
            null
        );
        Assert.areEqual(1, wrapped.saved, 'A List Path at an object is one item: ' + wrapped.errors);
    }

    @IsTest
    static void matchesOnIdAndLookupFields() {
        Account account = new Account(Name = 'Acme');
        insert account;
        Contact contact = new Contact(LastName = 'Lee', AccountId = account.Id);
        insert contact;

        ResponseWriter.Outcome byId = ResponseWriter.write(
            mapping('Contact', 'Update', 'Id', null, '{"fields": {"Id": "sfid", "Title": "title"}}'),
            '{"sfid": "' + contact.Id + '", "title": "ById"}',
            null
        );
        ResponseWriter.Outcome byLookup = ResponseWriter.write(
            mapping('Contact', 'Update', 'AccountId', null, '{"fields": {"AccountId": "account", "Department": "dept"}}'),
            '{"account": "' + String.valueOf(account.Id).left(15) + '", "dept": "ByAccount"}',
            null
        );

        Assert.areEqual(1, byId.saved, 'Id match: ' + byId.errors);
        Assert.areEqual(1, byLookup.saved, '15-character lookup Id match: ' + byLookup.errors);
        Contact updated = [SELECT Title, Department FROM Contact WHERE Id = :contact.Id];
        Assert.areEqual('ById', updated.Title, 'By Id');
        Assert.areEqual('ByAccount', updated.Department, 'By lookup');
    }

    @IsTest
    static void blankMatchValuesAndRepeatedNewItemsAreNotInserted() {
        insert new Contact(LastName = 'NoEmail');
        String body = '[' + String.join(new List<String>{
            person('Blank', '', 'x'),
            person('Spaces', '   ', 'x'),
            person('First', 'new@example.com', 'x'),
            person('Second', 'new@example.com', 'x')
        }, ', ') + ']';

        ResponseWriter.Outcome outcome = ResponseWriter.write(mapping('Contact', 'Upsert', 'Email', null, CONTACT_RULES), body, null);

        Assert.areEqual(1, outcome.saved, 'Only the first new item');
        String errors = String.join(outcome.errors, '\n');
        Assert.isTrue(errors.contains('Item 1: no value for the Match Field Email'), errors);
        Assert.isTrue(errors.contains('Item 2: no value for the Match Field Email'), errors);
        Assert.isTrue(errors.contains('Item 4: same Email as item 3'), errors);
        Assert.areEqual(1, [SELECT COUNT() FROM Contact WHERE Email = 'new@example.com'], 'Inserted once');
        Assert.areEqual('NoEmail', [SELECT LastName FROM Contact WHERE Email = NULL].LastName, 'Blank record untouched');
    }

    @IsTest
    static void saveFailuresAreTiedToTheirOwnItemsInBothWrites() {
        insert new List<Contact>{ new Contact(LastName = 'One', Email = 'one@example.com'), new Contact(LastName = 'Two', Email = 'two@example.com') };
        String body = '[' + String.join(new List<String>{
            '{"email": "new1@example.com"}',
            person('Fresh', 'new2@example.com', 'x'),
            person('', 'one@example.com', 'x'),
            person('TwoUpdated', 'two@example.com', 'x')
        }, ', ') + ']';

        ResponseWriter.Outcome outcome = ResponseWriter.write(mapping('Contact', 'Upsert', 'Email', null, CONTACT_RULES), body, null);

        Assert.areEqual(2, outcome.saved, 'Second insert and second update saved: ' + outcome.errors);
        String errors = String.join(outcome.errors, '\n');
        Assert.isTrue(errors.contains('Item 1: REQUIRED_FIELD_MISSING'), 'First insert failed: ' + errors);
        Assert.isTrue(errors.contains('Item 3: REQUIRED_FIELD_MISSING'), 'First update failed: ' + errors);
        Assert.areEqual(2, outcome.errors.size(), errors);
        Assert.areEqual(2, [SELECT COUNT() FROM Contact WHERE LastName IN ('Fresh', 'TwoUpdated')], 'The right records written');
    }

    @IsTest
    static void upsertUpdatesMatchesIgnoringCaseAndInsertsTheRest() {
        Contact existing = new Contact(LastName = 'Ann', Email = 'ann@example.com', Title = 'Old');
        insert existing;
        String body = '[' + person('Ann', 'ANN@EXAMPLE.COM', 'New') + ', ' + person('Bo', 'bo@example.com', 'CTO') + ']';

        Test.startTest();
        ResponseWriter.Outcome outcome = ResponseWriter.write(mapping('Contact', 'Upsert', 'Email', null, CONTACT_RULES), body, null);
        Integer queries = Limits.getQueries();
        Integer writes = Limits.getDmlStatements();
        Test.stopTest();

        Assert.areEqual(2, outcome.saved, 'Both saved: ' + outcome.errors);
        Assert.areEqual(1, queries, 'One query to match');
        Assert.areEqual(2, writes, 'One insert and one update');
        Contact updated = [SELECT Title, Email FROM Contact WHERE Id = :existing.Id];
        Assert.areEqual('New', updated.Title, 'Matched record updated');
        Assert.areEqual('ann@example.com', updated.Email, 'Matched ignoring case; match field left as it was');
        Assert.areEqual(1, [SELECT COUNT() FROM Contact WHERE Email = 'bo@example.com'], 'Unmatched item inserted');
    }

    @IsTest
    static void missingPathLeavesAFieldAndNullClearsIt() {
        Contact existing = new Contact(LastName = 'Ann', Email = 'ann@example.com', Title = 'Keep', Department = 'Clear');
        insert existing;
        String rules = '{"fields": {"Email": "email", "Title": "title", "Department": "department"}}';

        ResponseWriter.Outcome outcome = ResponseWriter.write(
            mapping('Contact', 'Update', 'Email', null, rules),
            '{"email": "ann@example.com", "department": null}',
            null
        );

        Assert.areEqual(1, outcome.saved, 'Saved: ' + outcome.errors);
        Contact updated = [SELECT Title, Department FROM Contact WHERE Id = :existing.Id];
        Assert.areEqual('Keep', updated.Title, 'Missing path: unchanged');
        Assert.isNull(updated.Department, 'JSON null: cleared');
    }

    @IsTest
    static void matchingProblemsAreErrorsForThatItemOnly() {
        insert new List<Contact>{
            new Contact(LastName = 'Good', Email = 'good@example.com'),
            new Contact(LastName = 'Twin1', Email = 'twin@example.com'),
            new Contact(LastName = 'Twin2', Email = 'twin@example.com')
        };
        String body = '[' + String.join(new List<String>{
            person('Good', 'good@example.com', 'Updated'),
            person('Nobody', 'nobody@example.com', 'x'),
            person('Twin', 'twin@example.com', 'x'),
            person('Again', 'good@example.com', 'x'),
            '{"name": {"last": "NoEmail"}}'
        }, ', ') + ']';

        ResponseWriter.Outcome outcome = ResponseWriter.write(mapping('Contact', 'Update', 'Email', null, CONTACT_RULES), body, null);

        Assert.areEqual(1, outcome.saved, 'Only the clear match saved');
        String errors = String.join(outcome.errors, '\n');
        Assert.isTrue(errors.contains('Item 2: no Contact record has this Email'), errors);
        Assert.isTrue(errors.contains('Item 3: 2 Contact records have this Email'), errors);
        Assert.isTrue(errors.contains('Item 4: same Email as item 1'), errors);
        Assert.isTrue(errors.contains('Item 5: no value for the Match Field Email'), errors);
        Assert.areEqual('Updated', [SELECT Title FROM Contact WHERE LastName = 'Good'].Title, 'First item written');
    }

    @IsTest
    static void numbersMatchByValue() {
        Account account = new Account(Name = 'Old', AnnualRevenue = 100, NumberOfEmployees = 50);
        insert account;

        ResponseWriter.Outcome byCurrency = ResponseWriter.write(
            mapping('Account', 'Update', 'AnnualRevenue', null, '{"fields": {"AnnualRevenue": "revenue", "Name": "name"}}'),
            '{"revenue": "100.00", "name": "ByRevenue"}',
            null
        );
        ResponseWriter.Outcome byWholeNumber = ResponseWriter.write(
            mapping('Account', 'Update', 'NumberOfEmployees', null, '{"fields": {"NumberOfEmployees": "staff", "Description": "note"}}'),
            '{"staff": 50, "note": "BySize"}',
            null
        );

        Assert.areEqual(1, byCurrency.saved, 'Currency match: ' + byCurrency.errors);
        Assert.areEqual(1, byWholeNumber.saved, 'Whole number match: ' + byWholeNumber.errors);
        Account updated = [SELECT Name, Description FROM Account WHERE Id = :account.Id];
        Assert.areEqual('ByRevenue', updated.Name, '100.00 matched 100');
        Assert.areEqual('BySize', updated.Description, '50 matched 50');
    }

    @IsTest
    static void writesBackToTheJobsOwnRecord() {
        Account account = new Account(Name = 'Acme');
        insert account;
        Contact contact = new Contact(LastName = 'Lee');
        insert contact;
        Mapping__c writeBack = mapping('Account', 'Update', null, null, '{"fields": {"Description": "id"}}');

        ResponseWriter.Outcome outcome = ResponseWriter.write(writeBack, '{"id": "EXT-1"}', account.Id);

        Assert.areEqual(1, outcome.saved, 'Saved: ' + outcome.errors);
        Assert.areEqual('EXT-1', [SELECT Description FROM Account WHERE Id = :account.Id].Description, 'Written back');
        assertRejected(writeBack, '{"id": "EXT-1"}', contact.Id, 'must be a record of Account');
        assertRejected(writeBack, '{"id": "EXT-1"}', null, 'must be a record of Account');
        assertRejected(writeBack, '[{"id": "A"}, {"id": "B"}]', account.Id, 'needs one item');
    }

    @IsTest
    static void badItemsAreReportedWithoutTheirValuesAndOthersSaved() {
        String rules = '{"fields": {"LastName": "name.last", "Birthdate": "born"}}';
        String body = '[{"name": {"last": "Fine"}}, {"name": {"last": "BadDate"}, "born": "secret-31"}, {"born": "2000-01-01"}, 42]';

        ResponseWriter.Outcome outcome = ResponseWriter.write(mapping('Contact', 'Insert', null, null, rules), body, null);

        Assert.areEqual(1, outcome.saved, 'Good item saved');
        String errors = String.join(outcome.errors, '\n');
        Assert.isTrue(errors.contains('Item 2: Field Birthdate expects a date'), errors);
        Assert.isTrue(errors.contains('Item 3: REQUIRED_FIELD_MISSING (LastName)'), errors);
        Assert.isTrue(errors.contains('Item 4: not a JSON object'), errors);
        Assert.isFalse(errors.contains('secret'), 'Values never repeated: ' + errors);
    }

    @IsTest
    static void writesAtMostOneThousandItems() {
        List<String> numbers = new List<String>();
        for (Integer i = 0; i < 1001; i++) {
            numbers.add(String.valueOf(i));
        }

        ResponseWriter.Outcome outcome = ResponseWriter.write(
            mapping('Contact', 'Insert', null, null, CONTACT_RULES),
            '[' + String.join(numbers, ',') + ']',
            null
        );

        Assert.areEqual('1 items after the first 1000 were not written', outcome.errors[0], 'Overflow reported first');
        Assert.areEqual(1001, outcome.errors.size(), 'The first 1000 were each tried');
    }

    @IsTest
    static void rejectsMappingsAndResponsesItCannotUse() {
        Account account = new Account(Name = 'Acme');
        insert account;
        String body = '{"a": "x"}';
        Map<String, Mapping__c> cases = new Map<String, Mapping__c>{
            'Not a Response mapping' => new Mapping__c(Direction__c = 'Request'),
            'needs an Operation' => mapping('Contact', null, null, null, CONTACT_RULES),
            'Unknown object' => mapping('Nope__c', 'Insert', null, null, CONTACT_RULES),
            'Rules must look like' => mapping('Contact', 'Insert', null, null, '{"LastName": "a"}'),
            'without {!' => mapping('Contact', 'Insert', null, null, '{"fields": {"LastName": "{!$Credential.X.Key}"}}'),
            'Unknown field on Contact' => mapping('Contact', 'Insert', null, null, '{"fields": {"Nope": "a"}}'),
            'must be a JSON path in quotes' => mapping('Contact', 'Insert', null, null, '{"fields": {"LastName": 1}}'),
            'more than one rule' => mapping('Contact', 'Insert', null, null, '{"fields": {"LastName": "a", "lastname": "b"}}'),
            'A JSON path' => mapping('Contact', 'Insert', null, 'a..b', CONTACT_RULES),
            'Upsert needs a Match Field' => mapping('Contact', 'Upsert', null, null, CONTACT_RULES),
            'needs a rule giving its value' => mapping('Contact', 'Upsert', 'Phone', null, CONTACT_RULES),
            'must be a text, number or Id field' => mapping('Contact', 'Upsert', 'Birthdate', null, '{"fields": {"Birthdate": "a"}}'),
            'cannot write field CreatedDate' => mapping('Account', 'Insert', null, null, '{"fields": {"CreatedDate": "a"}}')
        };

        for (String expected : cases.keySet()) {
            assertRejected(cases.get(expected), body, account.Id, expected);
        }
        assertRejected(mapping('Contact', 'Insert', null, null, CONTACT_RULES), 'not json', null, 'not valid JSON');
        assertRejected(mapping('Contact', 'Insert', null, 'data', CONTACT_RULES), body, null, 'is not in the response');
    }

    @IsTest
    static void followsTheRunningUsersAccess() {
        User outsider = ReplayrTestAccess.newUser(ReplayrTestAccess.minimalProfileId(), ReplayrTestAccess.username('outsider'));
        System.runAs(new User(Id = UserInfo.getUserId())) {
            insert outsider;
        }

        System.runAs(outsider) {
            assertRejected(mapping('Provider__c', 'Insert', null, null, '{"fields": {"Name": "name"}}'), '{"name": "P"}', null, 'cannot insert');
        }
    }

    @IsTest
    static void upsertsTwoHundredItemsWithOneQueryAndTwoWrites() {
        List<Contact> existing = new List<Contact>();
        List<String> items = new List<String>();
        for (Integer i = 0; i < 200; i++) {
            if (i < 100) {
                existing.add(new Contact(LastName = 'Old ' + i, Email = 'p' + i + '@example.com'));
            }
            items.add(person('New ' + i, 'p' + i + '@example.com', 'T' + i));
        }
        insert existing;

        Test.startTest();
        ResponseWriter.Outcome outcome = ResponseWriter.write(
            mapping('Contact', 'Upsert', 'Email', 'items', CONTACT_RULES),
            '{"items": [' + String.join(items, ', ') + ']}',
            null
        );
        Integer queries = Limits.getQueries();
        Integer writes = Limits.getDmlStatements();
        Test.stopTest();

        Assert.areEqual(200, outcome.saved, 'All saved: ' + outcome.errors);
        Assert.areEqual(1, queries, 'One query');
        Assert.areEqual(2, writes, 'One insert and one update');
        Assert.areEqual(200, [SELECT COUNT() FROM Contact WHERE LastName LIKE 'New %'], '100 updated and 100 inserted');
    }
}
