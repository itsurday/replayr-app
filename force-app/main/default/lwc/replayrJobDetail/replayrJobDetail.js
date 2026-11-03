import { LightningElement, api } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import detail from '@salesforce/apex/ConsoleJobs.detail';
import { isResolvable, replayJobs, resolveJobs } from 'c/replayrJobActions';

const DATE_FORMAT = { year: 'numeric', month: 'short', day: 'numeric', hour: '2-digit', minute: '2-digit', second: '2-digit' };
const ATTEMPT_COLUMNS = [
    { label: 'When', fieldName: 'at', type: 'date', typeAttributes: DATE_FORMAT },
    { label: 'Outcome', fieldName: 'outcome' },
    { label: 'HTTP', fieldName: 'httpStatus', type: 'number', initialWidth: 90 },
    { label: 'Message', fieldName: 'message', wrapText: true },
    { label: 'Took (ms)', fieldName: 'durationMs', type: 'number', initialWidth: 110 }
];

// One job in full: its fields, its attempts and its masked request (ConsoleJobs.detail), with Replay and Resolve.
// Sends "back" when the person returns to the list, saying whether the job changed
export default class ReplayrJobDetail extends LightningElement {
    attemptColumns = ATTEMPT_COLUMNS;
    job;
    error;
    loading = false;
    busy = false;
    changed = false;
    // Focus moves to the heading once the job (or why it can't be read) is shown, so a screen reader announces it
    focusPending = true;
    // Numbers each read, so only the latest one's answer is shown
    requestSeq = 0;
    _jobId;

    @api
    get jobId() {
        return this._jobId;
    }
    set jobId(value) {
        this._jobId = value;
        this.job = undefined;
        this.focusPending = true;
        this.load();
    }

    renderedCallback() {
        const heading = this.refs?.heading;
        const shown = !this.loading && (this.job || this.error);
        if (this.focusPending && shown && heading) {
            this.focusPending = false;
            heading.focus();
        }
    }

    async load() {
        if (!this._jobId) {
            return;
        }
        const seq = ++this.requestSeq;
        this.loading = true;
        this.error = undefined;
        try {
            const job = await detail({ jobId: this._jobId });
            if (seq === this.requestSeq) {
                // Attempts keyed by position: two can share a timestamp
                this.job = { ...job, attempts: (job.attempts ?? []).map((attempt, index) => ({ ...attempt, key: `attempt-${index}` })) };
            }
        } catch (e) {
            if (seq === this.requestSeq) {
                this.job = undefined;
                this.error = e?.body?.message ?? "Replayr couldn't read this job.";
            }
        } finally {
            if (seq === this.requestSeq) {
                this.loading = false;
            }
        }
    }

    get heading() {
        return this.job ? `${this.job.job.name}: ${this.job.job.statusLabel}` : 'Job';
    }

    get canReplay() {
        return this.job?.job.replayable === true;
    }

    get canResolve() {
        return isResolvable(this.job?.job);
    }

    // Both offered (Outcome unknown, Retries used up): they differ in whether anything is sent
    get showsBoth() {
        return this.canReplay && this.canResolve;
    }

    get hasAttempts() {
        return this.job?.attempts?.length > 0;
    }

    get showBody() {
        return this.job?.requestBodyReadable && this.job.requestBody;
    }

    get bodyNote() {
        const job = this.job;
        if (!job.requestBodyReadable) {
            return 'Only Replayr Admins can see request bodies.';
        }
        return job.requestBodyWithheld ?? (job.requestBody ? undefined : 'No request body.');
    }

    get fields() {
        const row = this.job.job;
        return [
            text('Endpoint', row.endpoint),
            text('Status', row.statusLabel),
            text('Attempts', row.attempts),
            text('Last HTTP status', row.httpStatus),
            text('Result', row.result),
            text('Retry-safe', row.retrySafe ? 'Yes' : 'No: never resent automatically'),
            text('Record Id', row.recordId),
            date('Created', row.createdDate),
            date('Next attempt', row.nextAttemptAt),
            text('Request', `${this.job.method} ${this.job.path}`),
            text('Idempotency key', this.job.idempotencyKey)
        ];
    }

    handleBack() {
        this.dispatchEvent(new CustomEvent('back', { detail: { changed: this.changed } }));
    }

    handleReplay() {
        return this.once(() => replayJobs([this.job.job]));
    }

    handleResolve() {
        return this.once(() => resolveJobs([this.job.job]));
    }

    // One action at a time; then says what happened and shows the job as it is now
    async once(action) {
        if (this.busy) {
            return;
        }
        this.busy = true;
        try {
            const outcome = await action();
            if (outcome) {
                this.dispatchEvent(new ShowToastEvent({ title: outcome.variant === 'error' ? 'Not done' : 'Job', message: outcome.message, variant: outcome.variant }));
                if (outcome.variant !== 'error') {
                    this.changed = true;
                    await this.load();
                }
            }
        } finally {
            this.busy = false;
        }
    }
}

function text(label, value) {
    return { label, key: label, valueKey: `${label}-value`, text: value === null || value === undefined || value === '' ? '—' : String(value) };
}

function date(label, value) {
    return value ? { label, key: label, valueKey: `${label}-value`, date: value } : text(label, undefined);
}
