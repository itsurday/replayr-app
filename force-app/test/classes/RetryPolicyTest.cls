@IsTest
private with sharing class RetryPolicyTest {
    private static final Datetime NOW = Datetime.newInstanceGmt(2026, 10, 21, 7, 0, 0);
    // 0.5 cancels the spread, so waits are exact
    private static final Decimal NO_SPREAD = 0.5;

    private static JobWorker.Attempt failed(Integer httpStatus) {
        return new JobWorker.Attempt(JobWorker.FAILED, JobWorker.FAILED, httpStatus, 'HTTP ' + httpStatus, 10);
    }

    // Decimal, because number literals such as 0.99999 are Decimal in Apex
    private static Long waitSeconds(Integer attemptsMade, String retryAfter, Decimal random) {
        return (RetryPolicy.nextAttemptAt(attemptsMade, retryAfter, NOW, random.doubleValue()).getTime() - NOW.getTime()) / 1000;
    }

    @IsTest
    static void retriesTimeoutsAndTemporaryHttpErrors() {
        for (Integer code : new List<Integer>{ 408, 429, 500, 502, 503, 504, 599 }) {
            Assert.isTrue(RetryPolicy.isRetryable(failed(code)), 'HTTP ' + code + ' retryable');
        }
        JobWorker.Attempt timeout = new JobWorker.Attempt(JobWorker.OUTCOME_UNKNOWN, JobWorker.OUTCOME_UNKNOWN, null, 'Read timed out', 10);
        Assert.isTrue(RetryPolicy.isRetryable(timeout), 'Callout error retryable');
    }

    @IsTest
    static void otherErrorsAreFinal() {
        for (Integer code : new List<Integer>{ 300, 400, 401, 403, 404, 409, 422, 499, 600 }) {
            Assert.isFalse(RetryPolicy.isRetryable(failed(code)), 'HTTP ' + code + ' final');
        }
        Assert.isFalse(RetryPolicy.isRetryable(failed(null)), 'Failed without a response is final');
        JobWorker.Attempt notSent = new JobWorker.Attempt(JobWorker.FAILED, JobWorker.NOT_SENT, null, 'Invalid path', null);
        Assert.isFalse(RetryPolicy.isRetryable(notSent), 'Rejected before sending is final');
        JobWorker.Attempt succeeded = new JobWorker.Attempt(JobWorker.SUCCEEDED, JobWorker.SUCCEEDED, 200, 'HTTP 200 OK', 10);
        Assert.isFalse(RetryPolicy.isRetryable(succeeded), 'A success is never retried');
    }

    @IsTest
    static void countsAttemptsAgainstTheEndpointLimit() {
        Assert.isTrue(RetryPolicy.hasAttemptsLeft(1, 5), 'First of five');
        Assert.isTrue(RetryPolicy.hasAttemptsLeft(4, 5), 'Fourth of five');
        Assert.isFalse(RetryPolicy.hasAttemptsLeft(5, 5), 'Fifth of five is the last');
        Assert.isFalse(RetryPolicy.hasAttemptsLeft(1, 1), 'One attempt means never retry');
        Assert.isTrue(RetryPolicy.hasAttemptsLeft(null, null), 'Blank counts as none of the default');
        Assert.isFalse(RetryPolicy.hasAttemptsLeft(5, null), 'Blank limit is the default of five');
    }

    @IsTest
    static void waitsDoubleFromOneMinuteUpToADay() {
        Assert.areEqual(60, waitSeconds(1, null, NO_SPREAD), 'After attempt 1');
        Assert.areEqual(120, waitSeconds(2, null, NO_SPREAD), 'After attempt 2');
        Assert.areEqual(240, waitSeconds(3, null, NO_SPREAD), 'After attempt 3');
        Assert.areEqual(480, waitSeconds(4, null, NO_SPREAD), 'After attempt 4');
        Assert.areEqual(30720, waitSeconds(10, null, NO_SPREAD), 'After attempt 10');
        Assert.areEqual(RetryPolicy.MAX_WAIT_SECONDS, waitSeconds(9999, null, NO_SPREAD), 'Capped at a day, no overflow');
        Assert.areEqual(60, waitSeconds(null, null, NO_SPREAD), 'Blank counts as attempt 1');
    }

    @IsTest
    static void spreadsWaitsByTwentyPercent() {
        Assert.areEqual(48, waitSeconds(1, null, 0), 'Shortest: 80%');
        Assert.areEqual(72, waitSeconds(1, null, 0.99999), 'Longest: just under 120%');
        Assert.areEqual(RetryPolicy.MAX_WAIT_SECONDS, waitSeconds(20, null, 0.99999), 'Spread never passes the cap');
        Assert.areEqual(48, waitSeconds(1, null, -3), 'Random below 0 treated as 0');
        Assert.areEqual(72, waitSeconds(1, null, 7), 'Random above 1 treated as 1');
        Assert.areEqual(60, waitSeconds(0, null, NO_SPREAD), 'Attempt 0 waits like attempt 1');
        Assert.areEqual(300, waitSeconds(1, '300', 0.99999), 'Retry-After above the spread wins');
        Assert.areEqual(72, waitSeconds(1, '65', 0.99999), 'Spread above Retry-After wins');
        Datetime defaultSpread = RetryPolicy.nextAttemptAt(1, null, NOW, null);
        Assert.areEqual(NOW.addSeconds(60), defaultSpread, 'Blank random means no spread');
    }

    @IsTest
    static void honoursRetryAfterSecondsWhenLonger() {
        Assert.areEqual(600, waitSeconds(1, '600', NO_SPREAD), 'Longer Retry-After wins');
        Assert.areEqual(120, waitSeconds(1, ' 120 ', NO_SPREAD), 'Spaces around the value allowed');
        Assert.areEqual(60, waitSeconds(1, '5', NO_SPREAD), 'Shorter Retry-After never speeds us up');
        Assert.areEqual(RetryPolicy.MAX_WAIT_SECONDS, waitSeconds(1, '9999999999999', NO_SPREAD), 'Huge value capped, no overflow');
        Assert.areEqual(RetryPolicy.MAX_WAIT_SECONDS, waitSeconds(1, '100000', NO_SPREAD), 'Over a day capped');
        Assert.areEqual(120, waitSeconds(1, '0000000120', NO_SPREAD), 'Leading zeros are not a huge value');
        Assert.areEqual(60, waitSeconds(1, '0000000000', NO_SPREAD), 'Zero means our own wait');
    }

    @IsTest
    static void honoursRetryAfterDates() {
        Assert.areEqual(1680, waitSeconds(1, 'Wed, 21 Oct 2026 07:28:00 GMT', NO_SPREAD), '28 minutes ahead');
        Assert.areEqual(60, waitSeconds(1, 'Wed, 21 Oct 2026 06:00:00 GMT', NO_SPREAD), 'A past date means our own wait');
        Assert.areEqual(RetryPolicy.MAX_WAIT_SECONDS, waitSeconds(1, 'Sat, 24 Oct 2026 07:00:00 GMT', NO_SPREAD), 'Days ahead capped');
    }

    @IsTest
    static void ignoresUnreadableRetryAfter() {
        List<String> unreadable = new List<String>{
            null,
            '',
            '   ',
            'Fri, 31 Dec 9999 23:59:59 GMT',
            'Sat, 01 Jan 0000 00:00:00 GMT',
            '-5',
            '1.5',
            'soon',
            '٣٠٠',
            'Wed, 31 Feb 2026 07:28:00 GMT',
            'Wed, 21 Oct 2026 25:00:00 GMT',
            'Wed, 21 Foo 2026 07:28:00 GMT',
            'Wed, 21 Oct 2026 07:28:00 CET',
            'Wednesday, 21-Oct-26 07:28:00 GMT',
            'Wed Oct 21 07:28:00 2026'
        };
        for (String value : unreadable) {
            Assert.areEqual(60, waitSeconds(1, value, NO_SPREAD), 'Ignored: ' + value);
        }
    }
}
