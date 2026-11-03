import { LightningElement } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import listJobs from '@salesforce/apex/ConsoleJobs.listJobs';
import ENDPOINT_OBJECT from '@salesforce/schema/Endpoint__c';
import { replayJobs, resolveJobs } from 'c/replayrJobActions';

// What JobActions takes in one request
const MAX_SELECTED = 200;
const DATE_FORMAT = { year: 'numeric', month: 'short', day: 'numeric', hour: '2-digit', minute: '2-digit' };
const COLUMNS = [
    // The job number opens the job
    { label: 'Job', type: 'button', typeAttributes: { label: { fieldName: 'name' }, name: 'open', variant: 'base', title: 'Open this job' } },
    { label: 'Endpoint', fieldName: 'endpoint' },
    // An icon and colour per status, beside the label, so the colour is never the only cue
    { label: 'Status', fieldName: 'statusLabel', cellAttributes: { iconName: { fieldName: 'statusIcon' }, class: { fieldName: 'statusClass' } } },
    { label: 'Attempts', fieldName: 'attempts', type: 'number', initialWidth: 100 },
    { label: 'Result', fieldName: 'result', wrapText: true },
    // Yes or No: a blank would read as unknown, and a job that isn't Retry-safe is never resent by itself
    { label: 'Retry-safe', fieldName: 'retrySafeText', initialWidth: 110 },
    { label: 'Created', fieldName: 'createdDate', type: 'date', typeAttributes: DATE_FORMAT }
];
// By Job__c.Status__c's API names (JobWorker); an unknown status gets no icon
const STATUS_LOOKS = {
    Succeeded: { statusIcon: 'utility:success', statusClass: 'slds-text-color_success' },
    Failed: { statusIcon: 'utility:error', statusClass: 'slds-text-color_error' },
    Dead: { statusIcon: 'utility:error', statusClass: 'slds-text-color_error' },
    // A warning, as in Health: it needs a person, but it may have worked
    Outcome_Unknown: { statusIcon: 'utility:warning' },
    Queued: { statusIcon: 'utility:clock' },
    Processing: { statusIcon: 'utility:clock' },
    Retry_Wait: { statusIcon: 'utility:clock' }
};
// The filters ConsoleJobs knows (decisions.md, ADR-022)
const FILTERS = [
    { label: 'Needs a person', value: 'needsPerson' },
    { label: 'Failed', value: 'failed' },
    { label: 'Waiting', value: 'waiting' },
    { label: 'Succeeded', value: 'succeeded' },
    { label: 'All', value: 'all' }
];

// The console's Jobs section: the list, a page at a time, and replaying or resolving the jobs selected. The server
// decides what may be done (JobActions); this only asks first where a person must confirm
export default class ReplayrJobs extends LightningElement {
    columns = COLUMNS;
    filters = FILTERS;
    maxSelected = MAX_SELECTED;
    endpointObject = ENDPOINT_OBJECT.objectApiName;
    filter = 'needsPerson';
    endpointId;
    includeTestRuns = false;
    rows = [];
    hasMore = false;
    loading = false;
    error;
    chosen = [];
    // The job shown in full, or undefined for the list
    openJob;
    focusListPending = false;
    // A replay or resolve is under way, from its first dialog to its reload
    busy = false;
    // Announced to screen readers: what the list now shows (an action's summary is announced by its toast)
    status = '';
    // Numbers each read, so only the latest one's answer is shown
    requestSeq = 0;

    connectedCallback() {
        this.load();
    }

    get hasRows() {
        return this.rows.length > 0;
    }

    get isEmpty() {
        return !this.loading && !this.error && this.rows.length === 0;
    }

    get selectedIds() {
        return this.chosen.map((row) => row.id);
    }

    get nothingSelected() {
        return this.chosen.length === 0 || this.loading || this.busy;
    }

    get cantReload() {
        return this.loading || this.busy;
    }

    get replayLabel() {
        return this.chosen.length ? `Replay selected (${this.chosen.length})` : 'Replay selected';
    }

    get resolveLabel() {
        return this.chosen.length ? `Resolve selected (${this.chosen.length})` : 'Resolve selected';
    }

    // A fresh list, or the next page after the last row shown. A newer read (a filter changed meanwhile) makes this
    // one's answer stale: it is dropped, so old rows never appear under a new filter
    async load(more = false) {
        const seq = ++this.requestSeq;
        this.loading = true;
        this.error = undefined;
        const last = more ? this.rows[this.rows.length - 1] : undefined;
        try {
            const page = await listJobs({
                filter: this.filter,
                endpointId: this.endpointId,
                includeTestRuns: this.includeTestRuns,
                beforeCreated: last?.createdDate,
                beforeId: last?.id
            });
            if (seq !== this.requestSeq) {
                return;
            }
            const shown = page.rows.map(looksOf);
            this.rows = more ? [...this.rows, ...shown] : shown;
            this.hasMore = page.hasMore;
            if (!more) {
                this.chosen = [];
            }
            this.status = `${this.rows.length} ${this.rows.length === 1 ? 'job' : 'jobs'} shown.`;
        } catch (e) {
            if (seq !== this.requestSeq) {
                return;
            }
            this.error = e?.body?.message ?? "Replayr couldn't read jobs.";
            this.status = '';
            if (!more) {
                // Nothing from the previous filter stays on screen to be selected
                this.rows = [];
                this.hasMore = false;
                this.chosen = [];
            }
        } finally {
            if (seq === this.requestSeq) {
                this.loading = false;
            }
        }
    }

    handleFilter(event) {
        this.filter = event.detail.value;
        this.load();
    }

    handleEndpoint(event) {
        this.endpointId = event.detail.recordId ?? undefined;
        this.load();
    }

    handleTestRuns(event) {
        this.includeTestRuns = event.detail.checked;
        this.load();
    }

    handleMore() {
        this.load(true);
    }

    handleRefresh() {
        this.load();
    }

    handleSelection(event) {
        this.chosen = event.detail.selectedRows;
    }

    handleRowAction(event) {
        if (event.detail.action.name === 'open') {
            this.openJob = event.detail.row;
        }
    }

    // Back from a job: the list as it was, read again only if the job changed
    handleBack(event) {
        this.openJob = undefined;
        this.focusListPending = true;
        if (event.detail?.changed) {
            this.load();
        }
    }

    get listClass() {
        return this.openJob ? 'slds-hide' : '';
    }

    // Back from a job: focus goes to the list's title, not lost with the closed job (a row's own button can't be
    // focused from outside the table)
    renderedCallback() {
        if (this.focusListPending && !this.openJob && this.refs?.listHeading) {
            this.focusListPending = false;
            this.refs.listHeading.focus();
        }
    }

    handleReplay() {
        return this.once(async () => this.report(await replayJobs(this.chosen)));
    }

    handleResolve() {
        return this.once(async () => this.report(await resolveJobs(this.chosen)));
    }

    // One action at a time: a second click while a dialog opens or a call runs does nothing
    async once(action) {
        if (this.busy) {
            return;
        }
        this.busy = true;
        try {
            await action();
        } finally {
            this.busy = false;
        }
    }

    // Says what an action did (nothing if the person cancelled), and reads the list again after one that ran
    async report(outcome) {
        if (!outcome) {
            return;
        }
        this.dispatchEvent(new ShowToastEvent({ title: outcome.variant === 'error' ? 'Not done' : 'Jobs', message: outcome.message, variant: outcome.variant }));
        if (outcome.variant !== 'error') {
            await this.load();
        }
    }
}

// A row as the table shows it: its status icon and colour, and Retry-safe as words
function looksOf(row) {
    return { ...row, ...(STATUS_LOOKS[row.status] ?? {}), retrySafeText: row.retrySafe ? 'Yes' : 'No' };
}
