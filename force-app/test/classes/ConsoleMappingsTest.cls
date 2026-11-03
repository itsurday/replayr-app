@IsTest
private with sharing class ConsoleMappingsTest {
    private static final String OPERATOR = ReplayrTestAccess.username('operator');

    @TestSetup
    static void setup() {
        ReplayrTestAccess.createRunner();
        System.runAs(new User(Id = UserInfo.getUserId())) {
            User operator = ReplayrTestAccess.newUser(ReplayrTestAccess.minimalProfileId(), OPERATOR);
            insert operator;
            insert new PermissionSetAssignment(AssigneeId = operator.Id, PermissionSetId = [SELECT Id FROM PermissionSet WHERE Name = 'Replayr_Operator'].Id);
        }
        System.runAs(ReplayrTestAccess.runner()) {
            Provider__c provider = new Provider__c(Name = 'Acme', Named_Credential__c = 'Acme_API');
            insert provider;
            insert new List<Endpoint__c>{
                new Endpoint__c(Name = 'Orders', Provider__c = provider.Id, Method__c = 'POST', Path__c = '/orders'),
                new Endpoint__c(Name = 'Items', Provider__c = provider.Id, Method__c = 'GET', Path__c = '/items')
            };
        }
    }

    // Read as the test's Replayr Admin: the user running the tests may hold no Replayr set (gate 4b)
    private static List<Mapping__c> saved() {
        List<Mapping__c> rows;
        System.runAs(ReplayrTestAccess.runner()) {
            rows = [SELECT Direction__c, Target_Object__c, Operation__c, Match_Field__c, List_Path__c, Rules__c FROM Mapping__c ORDER BY Direction__c];
        }
        return rows;
    }

    private static Id endpointNamed(String name) {
        return [SELECT Id FROM Endpoint__c WHERE Name = :name].Id;
    }

    private static ConsoleMappings.RequestMapping request(Id endpointId, String targetObject, String template) {
        ConsoleMappings.RequestMapping mapping = new ConsoleMappings.RequestMapping();
        mapping.endpointId = endpointId;
        mapping.targetObject = targetObject;
        mapping.template = template;
        return mapping;
    }

    private static String refusal(ConsoleMappings.RequestMapping mapping) {
        try {
            ConsoleMappings.saveRequestMapping(mapping);
            Assert.fail('Expected AuraHandledException');
        } catch (AuraHandledException e) {
            return e.getMessage();
        }
        return null;
    }

    @IsTest
    static void savesARequestMappingAndListsIt() {
        Id orders = endpointNamed('Orders');
        ConsoleMappings.Mappings shown;
        System.runAs(ReplayrTestAccess.runner()) {
            // A related record's field and an IF form, quoted and bare, all pass
            Assert.isNotNull(
                ConsoleMappings.saveRequestMapping(request(endpointNamed('Items'), 'Account', '{"owner": "{{Owner.Name}}", "site": {{IF(ISBLANK(Site), Name, Site)}}}')),
                'Related fields and IF'
            );
            Id saved = ConsoleMappings.saveRequestMapping(request(orders, 'account', '{"name": "{{Name}}", "phone": {{Phone}}}'));
            Assert.isNotNull(saved, 'Saved');
            shown = ConsoleMappings.mappings(orders);
        }

        Assert.areEqual(1, shown.rows.size(), 'Listed, for its own endpoint only');
        Assert.areEqual('Request', shown.rows[0].direction, 'A Request mapping');
        Assert.areEqual('Account', shown.rows[0].targetObject, 'The object as describe names it');
        Assert.areEqual('{"name": "{{Name}}", "phone": {{Phone}}}', shown.rows[0].rules, 'The template as given');
        Assert.isTrue(shown.canEdit, 'Admins edit');
    }

    @IsTest
    static void editsTheTemplateOfAnExistingRequestMapping() {
        Id orders = endpointNamed('Orders');
        System.runAs(ReplayrTestAccess.runner()) {
            ConsoleMappings.RequestMapping mapping = request(orders, 'Account', '{"name": "{{Name}}"}');
            mapping.id = ConsoleMappings.saveRequestMapping(mapping);
            mapping.template = '{"name": "{{Name}}", "site": "{{Site}}"}';

            Assert.areEqual(mapping.id, ConsoleMappings.saveRequestMapping(mapping), 'The same mapping');
        }

        Assert.areEqual('{"name": "{{Name}}", "site": "{{Site}}"}', saved()[0].Rules__c, 'Updated');
        Assert.areEqual(1, [SELECT COUNT() FROM Mapping__c], 'Not a second one');
    }

    @IsTest
    static void refusesWhatEveryJobWouldFailOn() {
        Id orders = endpointNamed('Orders');
        System.runAs(ReplayrTestAccess.runner()) {
            Assert.isTrue(refusal(request(orders, 'NoSuchObject__c', '{"a": "{{Name}}"}')).contains('Unknown object'), 'Unknown object');
            Assert.isTrue(refusal(request(orders, 'Account', '{"a": "{{NoSuchField__c}}"}')).startsWith('Not saved:'), 'Unknown field');
            Assert.isTrue(refusal(request(orders, 'Account', '{"a": "{!$Credential.Acme.Key}"}')).contains('{!'), 'Credential syntax');
            Assert.isTrue(refusal(request(orders, 'Account', ' ')).contains('empty'), 'Empty template');
            // Not JSON, whatever the record: every job would fail on it
            Assert.isTrue(refusal(request(orders, 'Account', '{"a": "{{Name}}" "b": 1}')).contains('not valid JSON'), 'A missing comma');
            Assert.isTrue(refusal(request(orders, 'Account', '{"a": {{Name}}')).contains('not valid JSON'), 'An unclosed brace');
            Assert.isTrue(refusal(request(orders, 'Account', '{"a": "x {{Name}}"')).contains('not valid JSON'), 'An unclosed object after a quoted field');
        }

        Assert.areEqual(0, [SELECT COUNT() FROM Mapping__c], 'Nothing saved');
    }

    @IsTest
    static void keepsOneRequestMappingPerEndpoint() {
        Id orders = endpointNamed('Orders');
        Id items = endpointNamed('Items');
        System.runAs(ReplayrTestAccess.runner()) {
            ConsoleMappings.saveRequestMapping(request(orders, 'Account', '{"name": "{{Name}}"}'));

            Assert.isTrue(refusal(request(orders, 'Account', '{"site": "{{Site}}"}')).contains('already has a Request mapping'), 'A second refused');
            // Another endpoint may have its own
            Assert.isNotNull(ConsoleMappings.saveRequestMapping(request(items, 'Account', '{"name": "{{Name}}"}')), 'Another endpoint');
        }
    }

    @IsTest
    static void editsOnlyRequestMappingsThroughThisSave() {
        Id orders = endpointNamed('Orders');
        Mapping__c response = new Mapping__c(
            Endpoint__c = orders,
            Direction__c = 'Response',
            Target_Object__c = 'Account',
            Operation__c = 'Update',
            Rules__c = '{"fields": {"Description": "about"}}'
        );
        System.runAs(ReplayrTestAccess.runner()) {
            insert response;
            ConsoleMappings.RequestMapping mapping = request(orders, 'Account', '{"name": "{{Name}}"}');
            mapping.id = response.Id;

            Assert.isTrue(refusal(mapping).contains('not a Request mapping'), 'A Response mapping is not edited here');
            mapping.id = null;
            mapping.endpointId = null;
            Assert.isTrue(refusal(mapping).contains('Say which endpoint'), 'A new one needs its endpoint');
        }
    }

    @IsTest
    static void operatorsSeeMappingsButCantSaveThem() {
        Id orders = endpointNamed('Orders');
        Id items = endpointNamed('Items');
        System.runAs(ReplayrTestAccess.runner()) {
            ConsoleMappings.saveRequestMapping(request(orders, 'Account', '{"name": "{{Name}}"}'));
        }

        User operator = [SELECT Id FROM User WHERE Username = :OPERATOR];
        System.runAs(operator) {
            ConsoleMappings.Mappings shown = ConsoleMappings.mappings(orders);
            Assert.areEqual(1, shown.rows.size(), 'Operators see mappings');
            Assert.isFalse(shown.canEdit, 'But may not edit them');
            Assert.isTrue(refusal(request(items, 'Account', '{"name": "{{Name}}"}')).contains('Replayr Admin'), 'Saving refused');
        }
        Assert.areEqual(1, [SELECT COUNT() FROM Mapping__c], 'Nothing saved by the Operator');
    }

    private static ConsoleMappings.ResponseMapping response(Id endpointId, String operation, String matchField, Map<String, String> rules) {
        ConsoleMappings.ResponseMapping mapping = new ConsoleMappings.ResponseMapping();
        mapping.endpointId = endpointId;
        mapping.targetObject = 'account';
        mapping.operation = operation;
        mapping.matchField = matchField;
        mapping.listPath = 'items';
        mapping.rules = new List<ConsoleMappings.Rule>();
        for (String field : rules.keySet()) {
            ConsoleMappings.Rule rule = new ConsoleMappings.Rule();
            rule.field = field;
            rule.path = rules.get(field);
            mapping.rules.add(rule);
        }
        return mapping;
    }

    private static String responseRefusal(ConsoleMappings.ResponseMapping mapping) {
        try {
            ConsoleMappings.saveResponseMapping(mapping);
            Assert.fail('Expected AuraHandledException');
        } catch (AuraHandledException e) {
            return e.getMessage();
        }
        return null;
    }

    @IsTest
    static void theConsoleActionsTakePlainValuesAndRulesAsJson() {
        Id orders = endpointNamed('Orders');
        Id request;
        Id response;
        String mangled;
        System.runAs(ReplayrTestAccess.runner()) {
            request = ConsoleMappings.saveRequest(null, orders, 'Account', '{"name": "{{Name}}"}');
            response = ConsoleMappings.saveResponse(null, orders, 'Account', 'Update', null, null, '[{"field": "Description", "path": "about"}]');
            try {
                ConsoleMappings.saveResponse(response, null, 'Account', 'Update', null, null, '{"not": "a list"}');
            } catch (AuraHandledException e) {
                mangled = e.getMessage();
            }
        }

        List<Mapping__c> rows = saved();
        Assert.areEqual(2, rows.size(), 'Both saved through the console actions');
        Assert.isNotNull(request, 'Request saved');
        Assert.areEqual('{"fields":{"Description":"about"}}', rows[1].Rules__c, 'Rules read from JSON');
        Assert.areEqual('Not saved: the rules couldn\'t be read.', mangled, 'Rules that are not a list are refused');
    }

    @IsTest
    static void theResponseActionChecksPermissionBeforeReadingRules() {
        User nobody = ReplayrTestAccess.newUser(ReplayrTestAccess.minimalProfileId(), ReplayrTestAccess.username('nobody'));
        System.runAs(new User(Id = UserInfo.getUserId())) {
            insert nobody;
        }
        Id orders = endpointNamed('Orders');
        String message;
        System.runAs(nobody) {
            try {
                ConsoleMappings.saveResponse(null, orders, 'Account', 'Update', null, null, 'not json');
            } catch (AuraHandledException e) {
                message = e.getMessage();
            }
        }

        Assert.isTrue(message.contains('Replayr Operator'), message);
    }

    @IsTest
    static void savesAndEditsAResponseMappingFromItsRows() {
        Id orders = endpointNamed('Orders');
        System.runAs(ReplayrTestAccess.runner()) {
            ConsoleMappings.ResponseMapping mapping = response(orders, 'Upsert', 'AccountNumber', new Map<String, String>{ 'AccountNumber' => 'id', 'Name' => 'name' });
            mapping.id = ConsoleMappings.saveResponseMapping(mapping);
            mapping.rules[1].path = 'company.name';

            Assert.areEqual(mapping.id, ConsoleMappings.saveResponseMapping(mapping), 'Edited in place');
        }

        Mapping__c saved = saved()[0];
        Assert.areEqual('Response', saved.Direction__c, 'Still a Response mapping after the edit');
        Assert.areEqual('Account', saved.Target_Object__c, 'As describe names it');
        Assert.areEqual('Upsert', saved.Operation__c, 'Operation');
        Assert.areEqual('AccountNumber', saved.Match_Field__c, 'Match Field');
        Assert.areEqual('items', saved.List_Path__c, 'List Path');
        Map<String, Object> fields = (Map<String, Object>) ((Map<String, Object>) JSON.deserializeUntyped(saved.Rules__c)).get('fields');
        Assert.areEqual(new Map<String, Object>{ 'AccountNumber' => 'id', 'Name' => 'company.name' }, fields, 'Rules from the rows');
    }

    @IsTest
    static void refusesAResponseMappingTheWorkerWouldRefuse() {
        Id orders = endpointNamed('Orders');
        System.runAs(ReplayrTestAccess.runner()) {
            Map<String, String> name = new Map<String, String>{ 'Name' => 'name' };
            Assert.isTrue(responseRefusal(response(orders, null, null, name)).contains('needs an Operation'), 'No Operation');
            Assert.isTrue(responseRefusal(response(orders, 'Upsert', null, name)).contains('Upsert needs a Match Field'), 'Upsert, no Match Field');
            Assert.isTrue(responseRefusal(response(orders, 'Upsert', 'AccountNumber', name)).contains('needs a rule giving its value'), 'Match Field without a rule');
            Assert.isTrue(responseRefusal(response(orders, 'Insert', null, new Map<String, String>{ 'NoSuchField__c' => 'x' })).startsWith('Not saved:'), 'Unknown field');
            Assert.isTrue(responseRefusal(response(orders, 'Insert', null, new Map<String, String>())).startsWith('Not saved:'), 'No rules');

            ConsoleMappings.ResponseMapping halfFilled = response(orders, 'Insert', null, new Map<String, String>{ 'Name' => ' ' });
            Assert.isTrue(responseRefusal(halfFilled).contains('needs a field and a JSON path'), 'A half-filled row');
            ConsoleMappings.ResponseMapping twice = response(orders, 'Insert', null, new Map<String, String>{ 'Name' => 'name', 'name' => 'title' });
            Assert.isTrue(responseRefusal(twice).contains('more than one rule'), 'A field twice, whatever its case');
        }

        Assert.areEqual(0, [SELECT COUNT() FROM Mapping__c], 'Nothing saved');
    }

    @IsTest
    static void keepsOneResponseMappingPerEndpointAndAnUpdateMayWriteBack() {
        Id orders = endpointNamed('Orders');
        System.runAs(ReplayrTestAccess.runner()) {
            // An Update without a Match Field writes back to the job's record: only a real job can check that
            Assert.isNotNull(ConsoleMappings.saveResponseMapping(response(orders, 'Update', null, new Map<String, String>{ 'Description' => 'about' })), 'Saved');

            Assert.isTrue(responseRefusal(response(orders, 'Insert', null, new Map<String, String>{ 'Name' => 'name' })).contains('already has a Response mapping'), 'A second refused');
        }
    }

    @IsTest
    static void proposesRulesFromASampleReply() {
        // Only fields the person may write are proposed: a Replayr Admin writes Replayr's own Provider
        ConsoleMappings.Proposal proposal;
        System.runAs(ReplayrTestAccess.runner()) {
            proposal = ConsoleMappings.propose('{"items": [{"name": "Acme", "key": "acme", "colour": "red"}]}', 'Provider__c', null);
        }

        Assert.areEqual('items', proposal.listPath, 'The list found');
        Map<String, String> rules = new Map<String, String>();
        for (ConsoleMappings.Rule rule : proposal.rules) {
            rules.put(rule.field, rule.path);
        }
        Assert.areEqual('name', rules.get('Name'), 'Name proposed: ' + rules);
        Assert.areEqual('key', rules.get(Schema.SObjectType.Provider__c.fields.Key__c.getName()), 'Key proposed: ' + rules);
        Assert.isTrue(proposal.unmatched.contains('colour'), 'What matched no field is listed: ' + proposal.unmatched);
    }

    @IsTest
    static void offersTheListsWhenASampleHasSeveral() {
        ConsoleMappings.Proposal proposal;
        System.runAs(ReplayrTestAccess.runner()) {
            proposal = ConsoleMappings.propose('{"orders": [{"name": "A"}], "refunds": [{"name": "B"}]}', 'Provider__c', null);
        }

        Assert.areEqual(0, proposal.rules.size(), 'Nothing proposed until one is chosen');
        Assert.areEqual(new Set<String>{ 'orders', 'refunds' }, new Set<String>(proposal.listPathCandidates), 'Both offered');
    }

    @IsTest
    static void trimsWhatIsTypedAndKeepsResponseAndRequestApart() {
        Id orders = endpointNamed('Orders');
        System.runAs(ReplayrTestAccess.runner()) {
            ConsoleMappings.ResponseMapping mapping = response(orders, 'Upsert', '  AccountNumber ', new Map<String, String>{ 'AccountNumber' => 'id' });
            mapping.listPath = ' items ';
            ConsoleMappings.saveResponseMapping(mapping);

            Id request = ConsoleMappings.saveRequestMapping(request(orders, 'Account', '{"name": "{{Name}}"}'));
            ConsoleMappings.ResponseMapping wrongKind = response(orders, 'Insert', null, new Map<String, String>{ 'Name' => 'name' });
            wrongKind.id = request;
            Assert.isTrue(responseRefusal(wrongKind).contains('not a Response mapping'), 'A Request mapping is not edited here');
        }

        // Request sorts before Response
        Mapping__c saved = saved()[1];
        Assert.areEqual('AccountNumber', saved.Match_Field__c, 'Trimmed');
        Assert.areEqual('items', saved.List_Path__c, 'Trimmed');
    }

    @IsTest
    static void operatorsMayProposeButNotSaveAResponseMapping() {
        Id orders = endpointNamed('Orders');
        User operator = [SELECT Id FROM User WHERE Username = :OPERATOR];
        System.runAs(operator) {
            // Proposing only reads the sample and describe; saving needs the Replayr Admin set
            Assert.isNotNull(ConsoleMappings.propose('{"name": "Acme"}', 'Provider__c', null), 'A proposal');
            Assert.isTrue(responseRefusal(response(orders, 'Insert', null, new Map<String, String>{ 'Name' => 'name' })).contains('Replayr Admin'), 'Saving refused');
        }
        Assert.areEqual(0, [SELECT COUNT() FROM Mapping__c], 'Nothing saved');
    }

    @IsTest
    static void saysWhyASampleCantBeUsed() {
        System.runAs(ReplayrTestAccess.runner()) {
            for (List<String> attempt : new List<List<String>>{ new List<String>{ 'not json', 'Account' }, new List<String>{ '{"a": 1}', 'NoSuchObject__c' } }) {
                try {
                    ConsoleMappings.propose(attempt[0], attempt[1], null);
                    Assert.fail('Expected AuraHandledException for ' + attempt);
                } catch (AuraHandledException e) {
                    Assert.isTrue(String.isNotBlank(e.getMessage()), 'A reason');
                }
            }
        }
    }

    @IsTest
    static void refusesUsersWithoutReplayrAdminOrOperator() {
        User nobody = ReplayrTestAccess.newUser(ReplayrTestAccess.minimalProfileId(), ReplayrTestAccess.username('nobody'));
        System.runAs(new User(Id = UserInfo.getUserId())) {
            insert nobody;
        }
        Id orders = endpointNamed('Orders');
        System.runAs(nobody) {
            try {
                ConsoleMappings.mappings(orders);
                Assert.fail('Expected AuraHandledException');
            } catch (AuraHandledException e) {
                Assert.isTrue(e.getMessage().contains('Replayr Operator'), e.getMessage());
            }
            Assert.isTrue(refusal(request(orders, 'Account', '{"name": "{{Name}}"}')).contains('Replayr Operator'), 'Saving refused too');
        }
    }
}
