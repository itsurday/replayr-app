@IsTest
private with sharing class MappingProposalTest {
    private static final String NESTED_SAMPLE =
        '{"meta": {"count": 1}, "data": {"people": [{"first_name": "Ann", "last_name": "Lee", ' +
        '"contact": {"email": "ann@example.com", "mobile_phone": "555"}, "id": "P1", "account_id": "A9", ' +
        '"tags": ["vip"], "favourite_colour": "red", "a.b": 1}]}}';

    private static void assertRejected(String sample, String objectName, String expected) {
        assertRejected(sample, objectName, expected, null);
    }

    private static void assertRejected(String sample, String objectName, String expected, String listPath) {
        try {
            MappingProposal.fromSample(sample, objectName, listPath);
            Assert.fail('Expected ProposalException: ' + expected);
        } catch (MappingProposal.ProposalException e) {
            Assert.isTrue(e.getMessage().contains(expected), expected + ' -> ' + e.getMessage());
        }
    }

    @IsTest
    static void proposesTheListPathAndFieldsFromANestedSample() {
        MappingProposal proposal = MappingProposal.fromSample(NESTED_SAMPLE, 'Contact');

        Assert.areEqual('data.people', proposal.listPath, 'Nearest list of objects');
        Assert.areEqual('first_name', proposal.fields.get('FirstName'), 'Underscores ignored');
        Assert.areEqual('last_name', proposal.fields.get('LastName'), 'Last name');
        Assert.areEqual('contact.email', proposal.fields.get('Email'), 'Nested value by its last key');
        Assert.areEqual('contact.mobile_phone', proposal.fields.get('MobilePhone'), 'Matched to the API name or label');
        Set<String> unmatched = new Set<String>(proposal.unmatched);
        for (String path : new List<String>{ 'id', 'account_id', 'tags', 'favourite_colour', 'a.b' }) {
            Assert.isTrue(unmatched.contains(path), 'Left to the admin: ' + path + ' in ' + unmatched);
        }
    }

    @IsTest
    static void aRootListOrASingleObjectHasABlankListPath() {
        Assert.areEqual('', MappingProposal.fromSample('[{"email": "a@example.com"}]', 'Contact').listPath, 'Root list');
        MappingProposal single = MappingProposal.fromSample('{"email": "a@example.com", "tags": [1, 2]}', 'Contact');
        Assert.areEqual('', single.listPath, 'No list of objects: one record');
        Assert.areEqual('email', single.fields.get('Email'), 'Field');
    }

    @IsTest
    static void theProposalWritesTheSampleItWasMadeFrom() {
        MappingProposal proposal = MappingProposal.fromSample(NESTED_SAMPLE, 'Contact');
        Mapping__c mapping = new Mapping__c(
            Direction__c = 'Response',
            Target_Object__c = 'Contact',
            Operation__c = 'Insert',
            List_Path__c = proposal.listPath,
            Rules__c = proposal.rulesJson()
        );

        ResponseWriter.Outcome outcome = ResponseWriter.write(mapping, NESTED_SAMPLE, null);

        Assert.areEqual(1, outcome.saved, 'Written: ' + outcome.errors);
        Contact written = [SELECT FirstName, LastName, Email, MobilePhone FROM Contact];
        Assert.areEqual('Ann', written.FirstName, 'First name');
        Assert.areEqual('ann@example.com', written.Email, 'Email');
        Assert.areEqual('555', written.MobilePhone, 'Mobile');
    }

    @IsTest
    static void proposesPackageFieldsWithoutTheirPrefixAndOnlyWritableOnes() {
        User runner = ReplayrTestAccess.createRunner();
        User outsider = ReplayrTestAccess.newUser(ReplayrTestAccess.minimalProfileId(), ReplayrTestAccess.username('outsider'));
        System.runAs(new User(Id = UserInfo.getUserId())) {
            insert outsider;
        }
        String sample = '{"name": "P", "named_credential": "X_API", "Masked Names": "X_Auth"}';

        MappingProposal forAdmin;
        MappingProposal forOutsider;
        System.runAs(runner) {
            forAdmin = MappingProposal.fromSample(sample, 'Provider__c');
        }
        System.runAs(outsider) {
            forOutsider = MappingProposal.fromSample(sample, 'Provider__c');
        }

        Assert.areEqual('named_credential', forAdmin.fields.get('replayr__Named_Credential__c'), 'Namespace and __c ignored');
        Assert.areEqual('Masked Names', forAdmin.fields.get('replayr__Masked_Names__c'), 'Spaces ignored');
        Assert.areEqual('name', forAdmin.fields.get('Name'), 'Standard field');
        Assert.isTrue(forOutsider.fields.isEmpty(), 'Nothing proposed that the user cannot write: ' + forOutsider.fields);
        Assert.areEqual(3, forOutsider.unmatched.size(), 'All left to the admin');
    }

    @IsTest
    static void aFieldIsProposedForOnePathOnly() {
        MappingProposal proposal = MappingProposal.fromSample('{"email": "a@example.com", "work": {"email": "b@example.com"}}', 'Contact');

        Assert.areEqual('email', proposal.fields.get('Email'), 'The exact match wins over a nested last key');
        Assert.areEqual(new List<String>{ 'work.email' }, proposal.unmatched, 'Second left to the admin');
        Assert.areEqual('{"fields":{"Email":"email"}}', proposal.rulesJson(), 'Rules format');
    }

    @IsTest
    static void severalListsAtOneLevelAreOfferedNotGuessed() {
        String sample = '{"included": [{"title": "x"}], "data": [{"email": "a@example.com"}], "z": {"deeper": [{"email": "b"}]}}';

        MappingProposal found = MappingProposal.fromSample(sample, 'Contact');
        MappingProposal chosen = MappingProposal.fromSample(sample, 'Contact', 'data');
        MappingProposal wholeBody = MappingProposal.fromSample('{"email": "a@example.com", "orders": [{"id": 1}]}', 'Contact', '');

        Assert.areEqual('', found.listPath, 'None proposed');
        Assert.areEqual(new List<String>{ 'data', 'included' }, found.listPathCandidates, 'Nearest level only, sorted');
        Assert.isTrue(found.fields.isEmpty(), 'No fields until one is chosen');
        Assert.areEqual('data', chosen.listPath, 'The chosen one');
        Assert.areEqual('email', chosen.fields.get('Email'), 'Fields from the chosen list');
        Assert.areEqual('email', wholeBody.fields.get('Email'), 'Whole body when told so, despite a list');
        assertRejected('{"a": [{"b": 1}]}', 'Contact', 'A JSON path', 'a..b');
    }

    @IsTest
    static void contendedFieldsAndUnusableValuesAreLeftToTheAdmin() {
        String sample =
            '{"email": "a@example.com", "e_mail": "b@example.com", "description": ["a"], "title": {}, ' +
            '"名前": "x", " phone": "1", "deep": {"a": {"b": {"c": {"d": {"phone": "2"}}}}}}';

        MappingProposal proposal = MappingProposal.fromSample(sample, 'Contact');

        Assert.isNull(proposal.fields.get('Email'), 'Two paths for one field: neither');
        Assert.isNull(proposal.fields.get('Description'), 'A list is not a value');
        Assert.isNull(proposal.fields.get('Title'), 'An object is not a value');
        Assert.isNull(proposal.fields.get('Phone'), 'Untrimmed key and too-deep path not proposed');
        Set<String> unmatched = new Set<String>(proposal.unmatched);
        for (String path : new List<String>{ 'email', 'e_mail', 'description', 'title', '名前', ' phone', 'deep.a.b.c.d' }) {
            Assert.isTrue(unmatched.contains(path), 'Left to the admin: ' + path + ' in ' + unmatched);
        }
        Map<String, String> copy = proposal.fields;
        copy.put('LastName', 'x');
        Assert.isFalse(proposal.fields.containsKey('LastName'), 'Results are copies');
    }

    @IsTest
    static void rejectsSamplesItCannotUse() {
        assertRejected('not json', 'Contact', 'not valid JSON');
        assertRejected('', 'Contact', 'Paste a sample');
        assertRejected('"' + 'x'.repeat(100000) + '"', 'Contact', 'Paste a sample');
        assertRejected('[1, 2]', 'Contact', 'no JSON object');
        assertRejected('{}', 'Nope__c', 'Unknown object');
        MappingProposal emptyList = MappingProposal.fromSample('{"items": []}', 'Contact');
        Assert.isTrue(emptyList.fields.isEmpty(), 'An empty list proposes nothing');
        Assert.areEqual(new List<String>{ 'items' }, emptyList.unmatched, 'and is left to the admin');
    }
}
