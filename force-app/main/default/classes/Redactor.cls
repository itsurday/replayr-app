/**
 * Masks secret values wherever Replayr shows a request or response: JSON values
 * of masked keys at any depth, form-encoded and URL parameters (query and fragment), header values, and
 * name=value pairs in messages. Stored request bodies are never changed, so a replay sends the real data (decisions.md,
 * ADR-014). It works on the text itself, so a preview keeps its exact layout; a hand-written scanner, because
 * Apex regexes with repeated groups fail on long input (see CalloutService). Not masked: XML and other formats,
 * JSON held inside a JSON string, and secrets in a URL path.
 */
public with sharing class Redactor {
    public static final String MASK = '****';
    // Matched inside longer names, ignoring case, spaces, '-' and '_': token also masks refreshToken and
    // x-auth-token, secret masks client_secret, cookie masks Set-Cookie. Masking too much in a preview is harmless
    private static final List<String> BUILT_IN = new List<String>{
        'authorization',
        'cookie',
        'credential',
        'passwd',
        'password',
        'privatekey',
        'secret',
        'session',
        'signature',
        'token',
        'apikey'
    };
    // Suffixed: Apex names ignore case, so a local such as "colon" would otherwise hide COLON (docs/apex-notes.md)
    private static final Integer QUOTE_CHAR = '"'.charAt(0);
    private static final Integer BACKSLASH_CHAR = '\\'.charAt(0);
    private static final Integer COLON_CHAR = ':'.charAt(0);
    private static final Set<Integer> OPENER_CHARS = new Set<Integer>{ '{'.charAt(0), '['.charAt(0) };
    private static final Set<Integer> CLOSER_CHARS = new Set<Integer>{ '}'.charAt(0), ']'.charAt(0) };
    private static final Set<Integer> SPACE_CHARS = new Set<Integer>{ ' '.charAt(0), '\t'.charAt(0), '\r'.charAt(0), '\n'.charAt(0) };
    private static final Set<Integer> SCALAR_END_CHARS = new Set<Integer>{
        ','.charAt(0), '}'.charAt(0), ']'.charAt(0), ' '.charAt(0), '\t'.charAt(0), '\r'.charAt(0), '\n'.charAt(0)
    };

    private final Set<String> configured = new Set<String>();

    /**
     * @param maskedNames a provider's Masked names: separated by commas or new lines, case ignored; may be blank
     */
    public Redactor(String maskedNames) {
        // Not ?? in the for header: Code Analyzer v5's Graph Engine can't load a class with that; recheck on upgrade
        List<String> names = (maskedNames ?? '').split('[,\\r\\n]+');
        for (String name : names) {
            if (String.isNotBlank(name)) {
                configured.add(name.trim().toLowerCase('en_US'));
            }
        }
    }

    /**
     * @param name a header name, JSON key or parameter name
     * @return true if its value is masked: a configured name exactly, or one containing a built-in name
     */
    public Boolean isMasked(String name) {
        if (String.isBlank(name)) {
            return false;
        }
        String lower = name.trim().toLowerCase('en_US');
        if (configured.contains(lower)) {
            return true;
        }
        String compact = lower.replace('-', '').replace('_', '').replace(' ', '');
        for (String builtIn : BUILT_IN) {
            if (compact.contains(builtIn)) {
                return true;
            }
        }
        return false;
    }

    /**
     * @param given header names and values
     * @return a copy with masked values replaced
     */
    public Map<String, String> headers(Map<String, String> given) {
        Map<String, String> masked = new Map<String, String>();
        for (String name : given.keySet()) {
            masked.put(name, isMasked(name) ? MASK : given.get(name));
        }
        return masked;
    }

    /**
     * @param address a URL or callout endpoint, possibly with a query string and a fragment
     * @return the same URL with masked parameter values replaced
     */
    public String url(String address) {
        if (address == null || !(address.contains('?') || address.contains('#'))) {
            return address;
        }
        String fragment = address.contains('#') ? '#' + params(address.substringAfter('#')) : '';
        String beforeFragment = address.substringBefore('#');
        String query = beforeFragment.contains('?') ? '?' + params(beforeFragment.substringAfter('?')) : '';
        return beforeFragment.substringBefore('?') + query + fragment;
    }

    /**
     * Masks the value of every masked key in JSON text, at any depth; a masked object or list is masked whole.
     * Text without any quote is treated as form-encoded (name=value pairs).
     * @param text JSON text, possibly cut short, or form-encoded text
     * @return the same text with masked values replaced
     */
    public String json(String text) {
        if (String.isEmpty(text)) {
            return text;
        }
        if (!text.contains('"')) {
            return text.contains('=') ? params(text) : text;
        }
        Integer length = text.length();
        List<String> parts = new List<String>();
        Integer copied = 0;
        Integer i = 0;
        while (i < length) {
            if (text.charAt(i) != QUOTE_CHAR) {
                i++;
                continue;
            }
            Integer keyEnd = stringEnd(text, i);
            Integer colon = skipSpaces(text, keyEnd);
            if (colon >= length || text.charAt(colon) != COLON_CHAR) {
                // A string that is a value, not a key: skip it whole, so its content is never read as a key
                i = keyEnd;
                continue;
            }
            Integer valueStart = skipSpaces(text, colon + 1);
            Boolean masked = isMasked(keyName(text.substring(i + 1, keyEnd - 1)));
            Integer valueFinish = masked ? valueEnd(text, valueStart) : scalarEnd(text, valueStart);
            if (masked && valueFinish > valueStart) {
                parts.add(text.substring(copied, valueStart));
                parts.add('"' + MASK + '"');
                copied = valueFinish;
            }
            // An unmasked object or list is scanned on from its opening bracket, so its keys are checked too
            i = Math.max(valueFinish, valueStart + 1);
        }
        parts.add(text.substring(copied));
        return String.join(parts, '');
    }

    /**
     * Masks name=value pairs and URLs in free text, such as a platform error message that repeats a URL.
     * @param text any text
     * @return the same text with masked values replaced
     */
    public String message(String text) {
        if (String.isEmpty(text)) {
            return text;
        }
        List<String> words = new List<String>();
        for (String word : text.split(' ', -1)) {
            words.add(word.contains('?') || word.contains('#') ? url(word) : (word.contains('=') ? params(word) : word));
        }
        String masked = String.join(words, ' ');
        // Only quoted "key": value pairs; quote-free text would be read as one long form field
        return masked.contains('"') ? json(masked) : masked;
    }

    // name=value pairs separated by & or ;, names percent-decoded ('+' is a space) before they are compared
    private String params(String pairs) {
        List<String> parts = new List<String>();
        Integer start = 0;
        for (Integer k = 0; k <= pairs.length(); k++) {
            Boolean atEnd = k == pairs.length();
            String c = atEnd ? '' : pairs.substring(k, k + 1);
            if (atEnd || c == '&' || c == ';') {
                String pair = pairs.substring(start, k);
                String name = pair.substringBefore('=');
                parts.add(pair.contains('=') && isMasked(decoded(name)) ? name + '=' + MASK : pair);
                parts.add(c);
                start = k + 1;
            }
        }
        return String.join(parts, '');
    }

    private static String decoded(String name) {
        try {
            return EncodingUtil.urlDecode(name, 'UTF-8');
        } catch (Exception e) {
            // A malformed %-escape: compare the name as written
            return name;
        }
    }

    // A key may be spelled with JSON escapes ("password" is password): decode it before comparing
    private static String keyName(String raw) {
        if (!raw.contains('\\')) {
            return raw;
        }
        try {
            return (String) JSON.deserializeUntyped('"' + raw + '"');
        } catch (Exception e) {
            // A malformed escape: compare without the backslashes rather than let it pass as written
            return raw.replace('\\', '');
        }
    }

    // Index after the string that starts at start (a quote), or the end of the text if it is never closed
    private static Integer stringEnd(String text, Integer start) {
        Integer length = text.length();
        Integer k = start + 1;
        while (k < length) {
            Integer c = text.charAt(k);
            if (c == BACKSLASH_CHAR) {
                k += 2;
            } else if (c == QUOTE_CHAR) {
                return k + 1;
            } else {
                k++;
            }
        }
        return length;
    }

    // JSON whitespace only: space, tab, carriage return and line feed
    private static Integer skipSpaces(String text, Integer start) {
        Integer k = start;
        while (k < text.length() && SPACE_CHARS.contains(text.charAt(k))) {
            k++;
        }
        return k;
    }

    // End of a string or plain value; an object or list ends here (start), so it is scanned into
    private static Integer scalarEnd(String text, Integer start) {
        if (start >= text.length() || OPENER_CHARS.contains(text.charAt(start))) {
            return start;
        }
        if (text.charAt(start) == QUOTE_CHAR) {
            return stringEnd(text, start);
        }
        Integer k = start;
        while (k < text.length() && !SCALAR_END_CHARS.contains(text.charAt(k))) {
            k++;
        }
        return k;
    }

    // End of any value, an object or list included (matching brackets, skipping strings)
    private static Integer valueEnd(String text, Integer start) {
        if (start >= text.length() || !OPENER_CHARS.contains(text.charAt(start))) {
            return scalarEnd(text, start);
        }
        Integer depth = 0;
        Integer k = start;
        while (k < text.length()) {
            Integer c = text.charAt(k);
            if (c == QUOTE_CHAR) {
                k = stringEnd(text, k);
                continue;
            }
            depth += OPENER_CHARS.contains(c) ? 1 : (CLOSER_CHARS.contains(c) ? -1 : 0);
            k++;
            if (depth == 0) {
                return k;
            }
        }
        return text.length();
    }
}
