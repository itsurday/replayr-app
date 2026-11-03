/**
 * Decides whether a failed attempt is tried again, and when (docs/decisions.md, ADR-010).
 * Pure logic, no queries or DML: the worker asks it after each failed call of a Retry-safe job.
 */
public with sharing class RetryPolicy {
    public static final Integer DEFAULT_MAX_ATTEMPTS = 5;
    public static final Integer MAX_WAIT_SECONDS = 24 * 60 * 60;
    private static final Long FIRST_WAIT_SECONDS = 60;
    // Waits are spread by ±20%, so jobs that failed together don't all retry in the same second
    private static final Double JITTER = 0.2;
    private static final Set<Integer> RETRYABLE_STATUSES = new Set<Integer>{ 408, 429 };
    private static final Pattern SECONDS = Pattern.compile('[0-9]+');
    // IMF-fixdate, the only HTTP-date form senders may generate (RFC 9110 5.6.7); obsolete forms are ignored
    private static final Pattern HTTP_DATE = Pattern.compile(
        '[A-Z][a-z]{2}, ([0-9]{2}) ([A-Z][a-z]{2}) ([0-9]{4}) ([0-9]{2}):([0-9]{2}):([0-9]{2}) GMT'
    );
    private static final List<String> MONTHS = new List<String>{
        'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
    };

    /**
     * Whether trying again could succeed: a callout error such as a timeout, or HTTP 408, 429 or 5xx.
     * Other HTTP errors and requests rejected before sending are final.
     * @param attempt the failed attempt
     * @return true if the error is retryable
     */
    public static Boolean isRetryable(JobWorker.Attempt attempt) {
        if (attempt.logOutcome == JobWorker.OUTCOME_UNKNOWN) {
            return true;
        }
        Integer code = attempt.httpStatus;
        return attempt.logOutcome == JobWorker.FAILED &&
            code != null &&
            (RETRYABLE_STATUSES.contains(code) || (code >= 500 && code <= 599));
    }

    /**
     * @param attemptsMade the job's Attempts, this one included; blank counts as none
     * @param maxAttempts the endpoint's Max attempts; blank means the default
     * @return true if another attempt is allowed
     */
    public static Boolean hasAttemptsLeft(Decimal attemptsMade, Decimal maxAttempts) {
        return (attemptsMade ?? 0) < (maxAttempts ?? DEFAULT_MAX_ATTEMPTS);
    }

    /**
     * When to try again: 1, 2, 4, 8... minutes after attempt 1, 2, 3, 4..., spread by ±20%, or the API's
     * Retry-After if that is longer; never more than 24 hours.
     * @param attemptsMade the job's Attempts, this one included
     * @param retryAfter the response's Retry-After header (seconds or an HTTP date), or null; unreadable values are ignored
     * @param now the current time
     * @param random a number from 0 (up to 1), such as Math.random(); 0.5 gives the exact doubling
     * @return the next attempt time
     */
    public static Datetime nextAttemptAt(Integer attemptsMade, String retryAfter, Datetime now, Double random) {
        // Capped before shifting, so a huge attempt count can't overflow
        Integer doublings = Math.min(Math.max((attemptsMade ?? 1) - 1, 0), 20);
        Long backoff = Math.min(FIRST_WAIT_SECONDS << doublings, MAX_WAIT_SECONDS);
        Double unit = Math.min(Math.max(random ?? 0.5, 0), 1);
        Long spread = Math.roundToLong(backoff * (1 - JITTER + 2 * JITTER * unit));
        Long wait = Math.min(Math.max(spread, retryAfterSeconds(retryAfter, now) ?? 0), MAX_WAIT_SECONDS);
        return now.addSeconds(wait.intValue());
    }

    private static Long retryAfterSeconds(String value, Datetime now) {
        String trimmed = value?.trim();
        if (String.isEmpty(trimmed)) {
            return null;
        }
        if (SECONDS.matcher(trimmed).matches()) {
            String digits = trimmed.replaceFirst('^0+(?=[0-9])', '');
            // More than 9 digits is beyond the 24-hour cap anyway, and could overflow
            return digits.length() > 9 ? MAX_WAIT_SECONDS : Long.valueOf(digits);
        }
        Datetime due = httpDate(trimmed);
        return due == null ? null : Math.max(0, (due.getTime() - now.getTime()) / 1000);
    }

    private static Datetime httpDate(String value) {
        Matcher parts = HTTP_DATE.matcher(value);
        Integer month = MONTHS.indexOf(parts.matches() ? parts.group(2) : '') + 1;
        if (month == 0) {
            return null;
        }
        Integer year = Integer.valueOf(parts.group(3));
        // Years such as 0000 or 9999 (used as "never") may be beyond what Datetime supports; ignored
        if (year < 1970 || year > 3999) {
            return null;
        }
        Datetime due = Datetime.newInstanceGmt(
            year,
            month,
            Integer.valueOf(parts.group(1)),
            Integer.valueOf(parts.group(4)),
            Integer.valueOf(parts.group(5)),
            Integer.valueOf(parts.group(6))
        );
        // Impossible values such as 31 Feb or 25:00 roll over instead of failing: reject them by comparing back
        String expected = parts.group(3) + String.valueOf(month).leftPad(2, '0') + parts.group(1) + parts.group(4) + parts.group(5) + parts.group(6);
        return due.formatGmt('yyyyMMddHHmmss') == expected ? due : null;
    }
}
