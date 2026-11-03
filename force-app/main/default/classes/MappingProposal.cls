/**
 * Proposes a Response mapping from a sample response: the List Path and rules matching the first item's values
 * to fields by name. Never guesses: anything unclear is left to the admin, who also chooses the Operation and
 * Match Field.
 *
 * - List Path: the list of objects nearest the top, searched level by level. Several at that level: none is
 *   proposed and they are offered as listPathCandidates; the caller can pass the one to use (or '' for the
 *   whole body) to fromSample.
 * - Fields: names are compared simplified (lower case, letters and digits only) against each field's API name,
 *   without namespace prefix and __c, and its label. Full-path matches claim fields before last-key matches;
 *   two paths contending for one field, or a name fitting two fields, are left unmatched. Only fields the
 *   running user can create or edit are proposed (which of the two the Operation needs is checked at write
 *   time). Lookups are never proposed: an API's own ids are rarely Salesforce Ids. Lists and objects inside an
 *   item are left unmatched.
 */
public inherited sharing class MappingProposal {
    // A sample is pasted by an admin; this bounds parsing and the walk
    private static final Integer MAX_SAMPLE_LENGTH = 100000;
    private static final Integer MAX_DEPTH = 5;
    // JsonPath's limit
    private static final Integer MAX_PATH_LENGTH = 255;
    private static final Set<Schema.DisplayType> NOT_PROPOSED = new Set<Schema.DisplayType>{
        Schema.DisplayType.ADDRESS,
        Schema.DisplayType.LOCATION,
        Schema.DisplayType.BASE64,
        Schema.DisplayType.REFERENCE,
        Schema.DisplayType.ID
    };

    private final String chosenListPath;
    private final List<String> candidates;
    private final Map<String, String> rules = new Map<String, String>();
    private final List<String> left = new List<String>();

    /** Thrown when the sample can't be used. */
    public class ProposalException extends Exception {
    }

    private MappingProposal(String chosenListPath, List<String> candidates) {
        this.chosenListPath = chosenListPath;
        this.candidates = candidates;
    }

    /** The List Path: blank means the whole body is one item, or that a candidate must be chosen. */
    public String listPath {
        get {
            return chosenListPath;
        }
    }

    /** Lists of objects found at the nearest level, when there was more than one; choose one and ask again. */
    public List<String> listPathCandidates {
        get {
            return candidates.clone();
        }
    }

    /** Proposed rules: field API name to JSON path within an item. */
    public Map<String, String> fields {
        get {
            return rules.clone();
        }
    }

    /** Paths in the sample item that no field was proposed for, sorted. */
    public List<String> unmatched {
        get {
            List<String> sorted = left.clone();
            sorted.sort();
            return sorted;
        }
    }

    /**
     * Gives the proposed rules in the form the Rules field takes.
     * @return {"fields": {"Field__c": "json.path"}}
     */
    public String rulesJson() {
        return JSON.serialize(new Map<String, Object>{ 'fields' => rules });
    }

    /**
     * Proposes a mapping for a sample response, finding the List Path itself.
     * @param sampleJson a sample of the API's response
     * @param objectName the target object, for example Contact or replayr__Provider__c
     * @return the proposal
     * @throws ProposalException if the object is unknown, or the sample is not usable JSON or has no object to map
     */
    public static MappingProposal fromSample(String sampleJson, String objectName) {
        return fromSample(sampleJson, objectName, null);
    }

    /**
     * Proposes a mapping for a sample response.
     * @param sampleJson a sample of the API's response
     * @param objectName the target object
     * @param listPath the List Path to use; '' for the whole body; null to find it
     * @return the proposal; with no fields when several lists were found and none was chosen
     * @throws ProposalException as for fromSample(sampleJson, objectName), or if the List Path is not usable
     */
    public static MappingProposal fromSample(String sampleJson, String objectName, String listPath) {
        Schema.DescribeSObjectResult target;
        try {
            target = FieldConverter.objectType(objectName);
        } catch (FieldConverter.ConversionException e) {
            throw new ProposalException(e.getMessage());
        }
        Object root = parse(sampleJson);
        List<String> found = listPath == null && root instanceof Map<String, Object> ? nearestLists(root) : new List<String>();
        if (found.size() > 1) {
            return new MappingProposal('', found);
        }
        MappingProposal proposal = new MappingProposal(found.isEmpty() ? (listPath ?? '') : found[0], new List<String>());
        proposal.propose(itemAt(root, proposal.listPath), fieldIndex(target));
        return proposal;
    }

    private static Object parse(String sampleJson) {
        if (String.isBlank(sampleJson) || sampleJson.length() > MAX_SAMPLE_LENGTH) {
            throw new ProposalException('Paste a sample response of 1 to ' + MAX_SAMPLE_LENGTH + ' characters');
        }
        try {
            return JSON.deserializeUntyped(sampleJson);
        } catch (JSONException e) {
            throw new ProposalException('The sample is not valid JSON');
        }
    }

    private static Map<String, Object> itemAt(Object root, String listPath) {
        Object items;
        try {
            items = JsonPath.get(root, listPath);
        } catch (JsonPath.InvalidPathException e) {
            throw new ProposalException(e.getMessage());
        }
        Object item = items instanceof List<Object> && !((List<Object>) items).isEmpty() ? ((List<Object>) items)[0] : items;
        if (!(item instanceof Map<String, Object>)) {
            throw new ProposalException('The sample has no JSON object to map to a record at this List Path');
        }
        return (Map<String, Object>) item;
    }

    // Level by level with sorted keys, so the result never depends on map order: the lists of objects at the
    // nearest level that has any
    private static List<String> nearestLists(Object root) {
        Map<String, Object> level = new Map<String, Object>{ '' => root };
        for (Integer depth = 0; depth < MAX_DEPTH && !level.isEmpty(); depth++) {
            List<String> lists = new List<String>();
            Map<String, Object> next = new Map<String, Object>();
            for (String path : sortedKeys(level)) {
                Map<String, Object> node = (Map<String, Object>) level.get(path);
                for (String key : sortedKeys(node)) {
                    String childPath = join(path, key);
                    Object value = node.get(key);
                    if (!isAddressable(key, childPath)) {
                        continue;
                    }
                    if (isListOfObjects(value)) {
                        lists.add(childPath);
                    } else if (value instanceof Map<String, Object>) {
                        next.put(childPath, value);
                    }
                }
            }
            if (!lists.isEmpty()) {
                return lists;
            }
            level = next;
        }
        return new List<String>();
    }

    private void propose(Map<String, Object> item, Map<String, String> index) {
        List<String> paths = leaves(item, '', 0);
        Set<String> unclaimed = new Set<String>(paths);
        // Full paths first, so an exact match is never taken by a last-key match elsewhere
        claim(paths, index, true, unclaimed);
        claim(paths, index, false, unclaimed);
        left.addAll(unclaimed);
    }

    // Paths still in unclaimed that fit exactly one free field get it; paths contending for a field get none
    private void claim(List<String> paths, Map<String, String> index, Boolean byFullPath, Set<String> unclaimed) {
        Map<String, List<String>> pathsByField = new Map<String, List<String>>();
        for (String path : paths) {
            String name = simplify(byFullPath || !path.contains('.') ? path : path.substringAfterLast('.'));
            String field = String.isEmpty(name) ? null : index.get(name);
            if (field == null || !unclaimed.contains(path) || rules.containsKey(field)) {
                continue;
            }
            if (!pathsByField.containsKey(field)) {
                pathsByField.put(field, new List<String>());
            }
            pathsByField.get(field).add(path);
        }
        for (String field : pathsByField.keySet()) {
            List<String> contenders = pathsByField.get(field);
            if (contenders.size() == 1) {
                rules.put(field, contenders[0]);
                unclaimed.remove(contenders[0]);
            }
        }
    }

    // Sorted paths of the item's text, number and true/false values; everything else is left to the admin
    private List<String> leaves(Map<String, Object> node, String path, Integer depth) {
        List<String> paths = new List<String>();
        for (String key : sortedKeys(node)) {
            String childPath = join(path, key);
            Object value = node.get(key);
            Boolean nested = value instanceof Map<String, Object> && !((Map<String, Object>) value).isEmpty();
            if (isAddressable(key, childPath) && nested && depth + 1 < MAX_DEPTH) {
                paths.addAll(leaves((Map<String, Object>) value, childPath, depth + 1));
            } else if (isAddressable(key, childPath) && !(value instanceof Map<String, Object>) && !(value instanceof List<Object>)) {
                paths.add(childPath);
            } else {
                left.add(childPath);
            }
        }
        return paths;
    }

    // Simplified name to field; a name that fits two fields maps to null, so it is never used
    private static Map<String, String> fieldIndex(Schema.DescribeSObjectResult target) {
        Map<String, String> index = new Map<String, String>();
        for (Schema.SObjectField token : target.fields.getMap().values()) {
            Schema.DescribeFieldResult field = token.getDescribe();
            if ((!field.isCreateable() && !field.isUpdateable()) || NOT_PROPOSED.contains(field.getType())) {
                continue;
            }
            for (String name : new Set<String>{ simplify(withoutAffixes(field.getName())), simplify(field.getLabel()) }) {
                if (String.isEmpty(name)) {
                    continue;
                }
                Boolean fitsAnother = index.containsKey(name) && index.get(name) != field.getName();
                index.put(name, fitsAnother ? null : field.getName());
            }
        }
        return index;
    }

    // replayr__Named_Credential__c -> Named_Credential
    private static String withoutAffixes(String apiName) {
        String name = apiName.removeEndIgnoreCase('__c');
        return name.contains('__') ? name.substringAfter('__') : name;
    }

    private static String simplify(String name) {
        return (name ?? '').toLowerCase('en_US').replaceAll('[^a-z0-9]', '');
    }

    // JsonPath can't address keys that are empty, hold . [ ] or surrounding spaces (it trims), nor long paths
    private static Boolean isAddressable(String key, String path) {
        return String.isNotEmpty(key) && !key.containsAny('.[]') && key == key.trim() && path.length() <= MAX_PATH_LENGTH;
    }

    private static Boolean isListOfObjects(Object value) {
        return value instanceof List<Object> && !((List<Object>) value).isEmpty() && ((List<Object>) value)[0] instanceof Map<String, Object>;
    }

    private static List<String> sortedKeys(Map<String, Object> node) {
        List<String> keys = new List<String>(node.keySet());
        keys.sort();
        return keys;
    }

    private static String join(String path, String key) {
        return String.isEmpty(path) ? key : path + '.' + key;
    }
}
