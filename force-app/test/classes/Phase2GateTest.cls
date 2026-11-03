/**
 * Phase 2 gate: mapping in bulk and with nested JSON. 200 request bodies are built
 * in one query, a worker sends a stored body exactly as built, and a nested 200-item response is upserted in one
 * query and two writes. Mappings name package fields with their replayr__ prefix; object names resolve without it.
 */
@IsTest
private with sharing class Phase2GateTest {
    private static final Integer RECORD_COUNT = 200;
    private static final String TEMPLATE =
        '{"customer": {"name": "{{LastName}}", "company": "{{Account.Name}}", "contact": {"email": "{{Email}}", ' +
        '"phone": {{IF(ISBLANK(Phone), \'none\', Phone)}}}}}';
    private static final String RULES =
        '{"fields": {"Name": "profile.name", "replayr__Named_Credential__c": "auth.named", "replayr__Masked_Names__c": "auth.external"}}';

    @TestSetup
    static void setup() {
        ReplayrTestAccess.createRunner();
        Account parent = new Account(Name = 'Acme "Ltd"');
        insert parent;
        List<Contact> contacts = new List<Contact>();
        for (Integer i = 0; i < RECORD_COUNT; i++) {
            contacts.add(new Contact(LastName = 'Lee ' + i, Email = 'p' + i + '@example.com', AccountId = parent.Id, Phone = Math.mod(i, 2) == 0 ? '555' : null));
        }
        insert contacts;
    }

    private static String nestedResponse() {
        List<String> items = new List<String>();
        for (Integer i = 0; i < RECORD_COUNT; i++) {
            items.add('{"profile": {"name": "Provider ' + i + '"}, "auth": {"named": "Api_' + i + '", "external": "Auth_' + i + '"}}');
        }
        return '{"meta": {"page": 1}, "data": {"providers": [' + String.join(items, ', ') + ']}}';
    }

    private class NestedResponse implements HttpCalloutMock {
        public HttpRequest received;

        public HttpResponse respond(HttpRequest request) {
            received = request;
            HttpResponse response = new HttpResponse();
            response.setStatusCode(200);
            response.setStatus('OK');
            response.setBody(nestedResponse());
            return response;
        }
    }

    // Runs as the test runner: the gate provider, its endpoint and Response mapping, and 100 of the 200 targets
    private static Endpoint__c insertEndpointWithMapping() {
        Provider__c provider = new Provider__c(Name = 'Gate', Named_Credential__c = 'Gate_API');
        insert provider;
        Endpoint__c endpoint = new Endpoint__c(Name = 'Sync', Provider__c = provider.Id, Method__c = 'POST', Path__c = '/sync');
        insert endpoint;
        insert responseMapping(endpoint.Id);
        List<Provider__c> existing = new List<Provider__c>();
        for (Integer i = 0; i < RECORD_COUNT / 2; i++) {
            existing.add(new Provider__c(Name = 'Old ' + i, Named_Credential__c = 'Api_' + i, Masked_Names__c = 'Old_Auth'));
        }
        insert existing;
        return endpoint;
    }

    private static Mapping__c responseMapping(Id endpointId) {
        return new Mapping__c(
            Endpoint__c = endpointId,
            Direction__c = 'Response',
            Target_Object__c = 'Provider__c',
            Operation__c = 'Upsert',
            Match_Field__c = 'replayr__Named_Credential__c',
            List_Path__c = 'data.providers',
            Rules__c = RULES
        );
    }

    private static void assertProvidersWritten() {
        Assert.areEqual(RECORD_COUNT + 1, [SELECT COUNT() FROM Provider__c], 'The gate provider, 100 updated and 100 inserted');
        Assert.areEqual(0, [SELECT COUNT() FROM Provider__c WHERE Name LIKE 'Old %'], 'Matches updated');
        Assert.areEqual('Auth_7', [SELECT Masked_Names__c FROM Provider__c WHERE Named_Credential__c = 'Api_7'].Masked_Names__c, 'Nested value');
    }

    @IsTest
    static void buildsTwoHundredNestedBodiesInOneQuery() {
        Map<Id, Contact> contacts = new Map<Id, Contact>([SELECT Id, LastName, Email, Phone FROM Contact]);

        Integer queriesBefore = Limits.getQueries();
        Integer writesBefore = Limits.getDmlStatements();
        Map<Id, MergeTemplate.Result> bodies = MergeTemplate.render(TEMPLATE, contacts.keySet());

        Assert.areEqual(1, Limits.getQueries() - queriesBefore, 'One query for 200 bodies');
        Assert.areEqual(0, Limits.getDmlStatements() - writesBefore, 'No writes');
        Assert.areEqual(RECORD_COUNT, bodies.size(), 'A body per record');
        for (Contact source : contacts.values()) {
            MergeTemplate.Result result = bodies.get(source.Id);
            Assert.isNull(result.error, 'Built: ' + result.error);
            Map<String, Object> customer = (Map<String, Object>) ((Map<String, Object>) JSON.deserializeUntyped(result.body)).get('customer');
            Map<String, Object> contact = (Map<String, Object>) customer.get('contact');
            Assert.areEqual(source.LastName, customer.get('name'), 'Its own record');
            Assert.areEqual('Acme "Ltd"', customer.get('company'), 'Parent field, escaped');
            Assert.areEqual(source.Email, contact.get('email'), 'Nested value');
            Assert.areEqual(source.Phone == null ? 'none' : source.Phone, contact.get('phone'), 'IF branch');
        }
    }

    @IsTest
    static void writesANestedTwoHundredItemResponseInOneQueryAndTwoWrites() {
        System.runAs(ReplayrTestAccess.runner()) {
            Endpoint__c endpoint = insertEndpointWithMapping();
            Mapping__c mapping = responseMapping(endpoint.Id);

            Test.startTest();
            ResponseWriter.Outcome outcome = ResponseWriter.write(mapping, nestedResponse(), null);
            Integer queries = Limits.getQueries();
            Integer writes = Limits.getDmlStatements();
            Test.stopTest();

            Assert.areEqual(RECORD_COUNT, outcome.saved, 'All saved: ' + outcome.errors);
            Assert.areEqual(1, queries, 'One query to match');
            Assert.areEqual(2, writes, 'One insert and one update');
            assertProvidersWritten();
        }
    }

    @IsTest
    static void aWorkerSendsAStoredBodyAndWritesTheNestedResponse() {
        Set<Id> contactIds = new Map<Id, Contact>([SELECT Id FROM Contact]).keySet();
        Map<Id, MergeTemplate.Result> bodies = MergeTemplate.render(TEMPLATE, contactIds);

        System.runAs(ReplayrTestAccess.runner()) {
            Endpoint__c endpoint = insertEndpointWithMapping();
            List<Job__c> jobs = new List<Job__c>();
            for (Id contactId : contactIds) {
                jobs.add(new Job__c(
                    Endpoint__c = endpoint.Id,
                    Status__c = JobWorker.QUEUED,
                    Method__c = 'POST',
                    Path__c = '/sync',
                    Record_Id__c = contactId,
                    Request_Body__c = bodies.get(contactId).body
                ));
            }
            insert jobs;
            NestedResponse mock = new NestedResponse();
            Test.setMock(HttpCalloutMock.class, mock);

            Test.startTest();
            Id started = JobWorker.start();
            Test.stopTest();

            Job__c job = [SELECT Status__c, HTTP_Status__c, Result__c, Record_Id__c FROM Job__c WHERE Id = :started];
            Assert.areEqual(bodies.get(job.Record_Id__c).body, mock.received.getBody(), 'Sent exactly as built');
            Assert.areEqual('POST', mock.received.getMethod(), 'Method');
            Assert.isTrue(mock.received.getEndpoint().endsWith('/sync'), 'Path');
            Assert.areEqual(JobWorker.SUCCEEDED, job.Status__c, 'Job status');
            Assert.areEqual(200, job.HTTP_Status__c, 'HTTP status');
            Assert.isTrue(job.Result__c.contains('Response: 200 saved'), job.Result__c);
            assertProvidersWritten();
        }
    }
}
