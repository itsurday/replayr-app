/**
 * Turns "send this record to this endpoint" into queued jobs; the Flow action
 * calls this. Each request names an endpoint by its key and, when the endpoint has a Request
 * mapping, a record of the mapping's object. The body is built now, from the record as the sender sees it
 * (user mode), and stored with the job, so every retry and replay sends the same data.
 * Gated by the Replayr_Send custom permission. Senders usually can't see Replayr's Private providers, so the
 * endpoint lookup and the job insert run in PrivilegedAccess after that check (docs/decisions.md, ADR-018).
 * When a Response mapping will write back to the sent record (Update with a blank Match Field), the sender
 * must be able to edit it: the write later runs as the integration user. Only endpoints an admin opened to
 * flows and the API (Allow_Sending__c) can be used. Every reason a record can't be sent, the endpoint's setup
 * and the record's access alike, gets CANT_SEND, so a sender learns nothing about a configuration they can't
 * see (which keys exist, which object each maps); test mode shows an admin the detail.
 */
public with sharing class JobCreation {
    public static final String PERMISSION = 'Replayr_Send';
    public static final String NO_PERMISSION =
        'You need the "Send records with Replayr" permission (in the Replayr Sender permission set).';
    public static final String CANT_SEND =
        'This record can\'t be sent to this endpoint. Ask your Replayr admin: test mode shows why.';
    public static final String NOT_SAVED = 'The job couldn\'t be saved.';
    public static final String TOO_MUCH = 'Too many different endpoints or objects in one run; send fewer at a time.';
    public static final Integer MAX_REQUESTS = 200;
    private static final String REQUEST = 'Request';
    private static final String RESPONSE = 'Response';
    private static final String UPDATE_OPERATION = 'Update';
    // Bodies are built this many records at a time: 20 bodies at the 131,072-character maximum stay well
    // inside the 6 MB synchronous heap
    private static final Integer CHUNK_SIZE = 20;
    // Jobs are saved once their bodies reach this many characters, so 200 large bodies are never all held
    // at once; usually everything is saved together
    private static final Integer SAVE_AT_LENGTH = 1000000;
    // Left for the caller (the Flow action and whatever runs after it in the same transaction)
    private static final Integer QUERIES_KEPT_FREE = 20;

    /** Thrown when the whole call is refused: no requests or too many. */
    public class CreationException extends Exception {
    }

    /** One record to send to one endpoint. */
    public class Request {
        public final String endpointKey;
        public final Id recordId;

        public Request(String endpointKey, Id recordId) {
            this.endpointKey = endpointKey;
            this.recordId = recordId;
        }
    }

    /** The job made for one request, or why none was made (an error never holds record data). */
    public class Result {
        public Id jobId { get; private set; }
        public String error { get; private set; }
    }

    // Requests for one endpoint and one object, at most CHUNK_SIZE records: built with one query
    private class Unit {
        final Endpoint__c endpoint;
        final List<Integer> positions = new List<Integer>();
        final Set<Id> recordIds = new Set<Id>();

        Unit(Endpoint__c endpoint) {
            this.endpoint = endpoint;
        }
    }

    /**
     * Makes one Queued job per request. A request that can't be sent gets an error and no job; the others go
     * ahead. The jobs are sent at the next chain run (the work-waiting event starts one at once). Jobs for one endpoint and
     * object are made in request order; across endpoints or objects the order isn't kept.
     * @param requests up to MAX_REQUESTS
     * @return one result per request, in the order given
     * @throws CreationException for no requests or more than MAX_REQUESTS
     */
    public static List<Result> create(List<Request> requests) {
        if (requests == null || requests.isEmpty() || requests.size() > MAX_REQUESTS) {
            throw new CreationException('Send between 1 and ' + MAX_REQUESTS + ' records at a time.');
        }
        List<Result> results = new List<Result>();
        for (Integer i = 0; i < requests.size(); i++) {
            results.add(new Result());
        }
        if (!FeatureManagement.checkPermission(PERMISSION)) {
            for (Result result : results) {
                result.error = NO_PERMISSION;
            }
            return results;
        }
        PrivilegedAccess access = new PrivilegedAccess();
        Map<String, Endpoint__c> endpoints = access.endpoints(keysOf(requests));
        new Saver(requests, results, jobOwner()).build(units(requests, endpoints, results));
        return results;
    }

    private static Set<String> keysOf(List<Request> requests) {
        Set<String> keys = new Set<String>();
        for (Request request : requests) {
            if (String.isNotBlank(request?.endpointKey)) {
                keys.add(request.endpointKey.trim());
            }
        }
        return keys;
    }

    // Groups the requests that can go ahead; the rest get their error here
    private static List<Unit> units(List<Request> requests, Map<String, Endpoint__c> endpoints, List<Result> results) {
        Map<String, Unit> open = new Map<String, Unit>();
        List<Unit> units = new List<Unit>();
        for (Integer i = 0; i < requests.size(); i++) {
            Request request = requests[i];
            Endpoint__c endpoint = String.isBlank(request?.endpointKey) ? null : endpoints.get(request.endpointKey.trim().toLowerCase());
            results[i].error = refusal(request, endpoint);
            if (results[i].error != null) {
                continue;
            }
            String unitKey = endpoint.Id + ':' + (request.recordId == null ? '' : String.valueOf(request.recordId.getSobjectType()));
            Unit unit = open.get(unitKey);
            if (unit == null || (unit.recordIds.size() >= CHUNK_SIZE && !unit.recordIds.contains(request.recordId))) {
                unit = new Unit(endpoint);
                open.put(unitKey, unit);
                units.add(unit);
            }
            unit.positions.add(i);
            if (request.recordId != null) {
                unit.recordIds.add(request.recordId);
            }
        }
        return units;
    }

    private static String refusal(Request request, Endpoint__c endpoint) {
        if (String.isBlank(request?.endpointKey)) {
            return 'Name the endpoint by its key.';
        }
        // An unknown key, two Request mappings, no record or the wrong object: all the endpoint's setup
        List<Mapping__c> mappings = endpoint == null ? null : requestMappings(endpoint);
        if (endpoint == null || !endpoint.Allow_Sending__c || mappings.size() > 1) {
            return CANT_SEND;
        }
        if (mappings.isEmpty()) {
            return null;
        }
        return request.recordId != null && isOfObject(request.recordId, mappings[0].Target_Object__c) ? null : CANT_SEND;
    }

    // A template written for one object must not be filled from another the sender happens to be able to read
    private static Boolean isOfObject(Id recordId, String targetObject) {
        try {
            return FieldConverter.objectType(targetObject).getName() == String.valueOf(recordId.getSobjectType());
        } catch (Exception e) {
            // An unknown object name or an Id of no object in this org: either way, not the mapping's object
            return false;
        }
    }

    private static List<Mapping__c> requestMappings(Endpoint__c endpoint) {
        List<Mapping__c> found = new List<Mapping__c>();
        for (Mapping__c mapping : endpoint.Mappings__r) {
            if (mapping.Direction__c == REQUEST) {
                found.add(mapping);
            }
        }
        return found;
    }

    // The worker may use any of the endpoint's Response mappings, so any that writes back counts; ResponseWriter
    // writes back only to a record of the mapping's own object
    private static Boolean writesBackToRecord(Endpoint__c endpoint, Id sampleRecordId) {
        for (Mapping__c mapping : endpoint.Mappings__r) {
            if (
                mapping.Direction__c == RESPONSE &&
                mapping.Operation__c == UPDATE_OPERATION &&
                String.isBlank(mapping.Match_Field__c) &&
                isOfObject(sampleRecordId, mapping.Target_Object__c)
            ) {
                return true;
            }
        }
        return false;
    }

    // Builds bodies a unit at a time and saves jobs in batches sized by body length
    private with sharing class Saver {
        final List<Request> requests;
        final List<Result> results;
        // Null until the work-waiting trigger has recorded the integration user: the sender then owns the jobs
        final Id owner;
        final List<Job__c> pending = new List<Job__c>();
        final List<Integer> pendingPositions = new List<Integer>();
        Integer pendingLength = 0;

        Saver(List<Request> requests, List<Result> results, Id owner) {
            this.owner = owner;
            this.requests = requests;
            this.results = results;
        }

        void build(List<Unit> units) {
            // A query per unit, inside this loop on purpose: one per endpoint and object for each 20 records
            // (never one per record), and the guard below stops before the transaction's limit
            for (Unit unit : units) {
                if (Limits.getQueries() >= Limits.getLimitQueries() - QUERIES_KEPT_FREE) {
                    fail(unit, TOO_MUCH);
                    continue;
                }
                Map<Id, MergeTemplate.Result> bodies = bodiesFor(unit);
                refuseBadBodies(unit, bodies);
                requireEditable(unit);
                addJobs(unit, bodies);
                // shortcut: a save per unit once bodies are large (10 for 200 bodies at the maximum length)
                // rather than one, to keep the heap small; usually one save at the end
                if (pendingLength >= SAVE_AT_LENGTH) {
                    save();
                }
            }
            save();
        }

        void refuseBadBodies(Unit unit, Map<Id, MergeTemplate.Result> bodies) {
            for (Integer position : unit.positions) {
                MergeTemplate.Result body = bodies.get(requests[position].recordId);
                if (body?.error != null) {
                    // A record not found, or a body that is invalid JSON, too long or holds {!: the detail would
                    // describe the admin's template or reveal which records exist
                    results[position].error = CANT_SEND;
                }
            }
        }

        void addJobs(Unit unit, Map<Id, MergeTemplate.Result> bodies) {
            for (Integer position : unit.positions) {
                if (results[position].error == null) {
                    Id recordId = requests[position].recordId;
                    add(position, newJob(unit.endpoint, recordId, bodies.get(recordId)?.body, owner));
                }
            }
        }

        // A body per record when the endpoint has a Request mapping; records are read in user mode either way
        Map<Id, MergeTemplate.Result> bodiesFor(Unit unit) {
            List<Mapping__c> mappings = requestMappings(unit.endpoint);
            try {
                if (!mappings.isEmpty()) {
                    return MergeTemplate.render(mappings[0].Rules__c, unit.recordIds);
                }
                // No body to build, but a Response mapping may later write to the record: the sender must see it
                Set<Id> seen = visible(unit.recordIds);
                for (Integer position : unit.positions) {
                    Id recordId = requests[position].recordId;
                    if (recordId != null && !seen.contains(recordId)) {
                        results[position].error = CANT_SEND;
                    }
                }
            } catch (QueryException e) {
                // The sender can't read the object at all
                fail(unit, CANT_SEND);
            } catch (Exception e) {
                // The template, or the sender's access to a merged field (MergeException): its text would show the
                // admin's template to the sender, and other text would be the platform's
                fail(unit, CANT_SEND);
            }
            return new Map<Id, MergeTemplate.Result>();
        }

        // The sender's own edit access, from object permissions and record sharing
        void requireEditable(Unit unit) {
            // Only records still going ahead
            Set<Id> recordIds = new Set<Id>();
            for (Integer position : unit.positions) {
                if (results[position].error == null && requests[position].recordId != null) {
                    recordIds.add(requests[position].recordId);
                }
            }
            if (recordIds.isEmpty() || !writesBackToRecord(unit.endpoint, new List<Id>(recordIds)[0])) {
                return;
            }
            Set<Id> editable = editableOf(recordIds);
            for (Integer position : unit.positions) {
                if (results[position].error == null && !editable.contains(requests[position].recordId)) {
                    results[position].error = CANT_SEND;
                }
            }
        }

        // Records of one object, at most CHUNK_SIZE (UserRecordAccess takes up to 200 per query)
        Set<Id> editableOf(Set<Id> recordIds) {
            Set<Id> editable = new Set<Id>();
            if (!new List<Id>(recordIds)[0].getSobjectType().getDescribe(SObjectDescribeOptions.DEFERRED).isUpdateable()) {
                return editable;
            }
            Id userId = UserInfo.getUserId();
            try {
                for (UserRecordAccess access : [
                    SELECT RecordId, HasEditAccess
                    FROM UserRecordAccess
                    WHERE UserId = :userId AND RecordId IN :recordIds
                    WITH USER_MODE
                ]) {
                    if (access.HasEditAccess) {
                        editable.add(access.RecordId);
                    }
                }
            } catch (Exception e) {
                // Access can't be confirmed, so it counts as missing; other units go ahead
                return new Set<Id>();
            }
            return editable;
        }

        void fail(Unit unit, String error) {
            for (Integer position : unit.positions) {
                results[position].error = error;
            }
        }

        void add(Integer position, Job__c job) {
            pending.add(job);
            pendingPositions.add(position);
            pendingLength += job.Request_Body__c?.length() ?? 0;
        }

        void save() {
            if (pending.isEmpty()) {
                return;
            }
            List<Database.SaveResult> saved = new PrivilegedAccess().insertJobs(pending);
            for (Integer i = 0; i < saved.size(); i++) {
                Result result = results[pendingPositions[i]];
                if (saved[i].isSuccess()) {
                    result.jobId = saved[i].getId();
                } else {
                    // A customer validation rule or trigger on Job wrote its message for people; other text is
                    // the platform's
                    Database.Error error = saved[i].getErrors()[0];
                    result.error = error.getStatusCode() == StatusCode.FIELD_CUSTOM_VALIDATION_EXCEPTION
                        ? JobLogs.shorten(error.getMessage())
                        : NOT_SAVED;
                }
            }
            pending.clear();
            pendingPositions.clear();
            pendingLength = 0;
        }
    }

    // Records of one object, so one query; the object name comes from the platform, not from input
    private static Set<Id> visible(Set<Id> recordIds) {
        if (recordIds.isEmpty()) {
            return recordIds;
        }
        String objectName = String.valueOf(new List<Id>(recordIds)[0].getSobjectType());
        return new Map<Id, SObject>(
                Database.queryWithBinds(
                    'SELECT Id FROM ' + objectName + ' WHERE Id IN :recordIds',
                    new Map<String, Object>{ 'recordIds' => recordIds },
                    AccessLevel.USER_MODE
                )
            )
            .keySet();
    }

    // The integration user, as the work-waiting trigger last recorded it, so jobs never belong to ordinary users
    // (who may leave, or later be granted access to Job). Only while it is still Replayr's integration user
    // (WorkWaiting.isIntegrationUser): an inactive owner, or one without access to Job, would fail every insert
    private static Id jobOwner() {
        String recorded = Replayr_Settings__c.getOrgDefaults().Hand_Off_User__c;
        Id userId;
        try {
            userId = String.isBlank(recorded) ? null : Id.valueOf(recorded);
        } catch (StringException e) {
            // Not a valid Id: the sender owns the jobs, as before setup
            return null;
        }
        return WorkWaiting.isIntegrationUser(userId) ? userId : null;
    }

    private static Job__c newJob(Endpoint__c endpoint, Id recordId, String body, Id owner) {
        Job__c job = new Job__c(
            Endpoint__c = endpoint.Id,
            Status__c = JobWorker.QUEUED,
            // Copied, so a later edit to the endpoint doesn't change what this job sends
            Method__c = endpoint.Method__c,
            Path__c = endpoint.Path__c,
            Retry_Safe__c = endpoint.Retry_Safe__c,
            Record_Id__c = recordId,
            Request_Body__c = body
        );
        if (owner != null) {
            job.OwnerId = owner;
        }
        return job;
    }

    // without sharing on purpose, and only here: Provider is Private (Endpoint and Mapping follow it), so a
    // sender who can't see the provider could neither find the endpoint nor save a job pointing at it, even in
    // system mode. Used only after the Replayr_Send check; the sent record is read in user mode, outside this
    // class. Jobs stay read-only for people, hence system mode for the insert
    private without sharing class PrivilegedAccess {
        // Keys are unique ignoring case, so the map is keyed in lower case
        Map<String, Endpoint__c> endpoints(Set<String> keys) {
            Map<String, Endpoint__c> byKey = new Map<String, Endpoint__c>();
            if (keys.isEmpty()) {
                return byKey;
            }
            for (Endpoint__c endpoint : [
                SELECT Id, Key__c, Method__c, Path__c, Retry_Safe__c, Allow_Sending__c,
                    (SELECT Direction__c, Rules__c, Target_Object__c, Operation__c, Match_Field__c FROM Mappings__r)
                FROM Endpoint__c
                WHERE Key__c IN :keys
                WITH SYSTEM_MODE
            ]) {
                byKey.put(endpoint.Key__c.toLowerCase(), endpoint);
            }
            return byKey;
        }

        List<Database.SaveResult> insertJobs(List<Job__c> jobs) {
            return Database.insert(jobs, false, AccessLevel.SYSTEM_MODE);
        }
    }
}
