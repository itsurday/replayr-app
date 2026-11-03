import { createElement } from 'lwc';
import ReplayrJobs from 'c/replayrJobs';
import listJobs from '@salesforce/apex/ConsoleJobs.listJobs';
import replay from '@salesforce/apex/ConsoleJobs.replay';
import resolve from '@salesforce/apex/ConsoleJobs.resolve';
import LightningConfirm from 'lightning/confirm';
import ReplayrResolveModal from 'c/replayrResolveModal';

jest.mock('@salesforce/apex/ConsoleJobs.listJobs', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex/ConsoleJobs.replay', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex/ConsoleJobs.resolve', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('lightning/confirm', () => ({ __esModule: true, default: { open: jest.fn() } }));
jest.mock('c/replayrResolveModal', () => ({ __esModule: true, default: { open: jest.fn() } }));

function row(id, overrides = {}) {
    return {
        id,
        name: `JOB-${id}`,
        endpoint: 'Orders',
        status: 'Outcome_Unknown',
        statusLabel: 'Outcome unknown',
        attempts: 1,
        result: 'Timed out',
        retrySafe: true,
        replayable: true,
        createdDate: `2026-11-02T0${id}:00:00.000Z`,
        ...overrides
    };
}

const flushPromises = () => Array.from({ length: 10 }).reduce((chain) => chain.then(() => undefined), Promise.resolve());

async function render(rows, hasMore = false) {
    listJobs.mockResolvedValue({ rows, hasMore });
    const element = createElement('c-replayr-jobs', { is: ReplayrJobs });
    const toasts = [];
    element.addEventListener('lightning__showtoast', (event) => toasts.push(event.detail));
    document.body.appendChild(element);
    await flushPromises();
    return { element, toasts };
}

const button = (element, label) => [...element.shadowRoot.querySelectorAll('lightning-button')].find((b) => b.label.startsWith(label));
const lastQuery = () => listJobs.mock.calls[listJobs.mock.calls.length - 1][0];

async function select(element, rows) {
    element.shadowRoot.querySelector('lightning-datatable').dispatchEvent(new CustomEvent('rowselection', { detail: { selectedRows: rows } }));
    await flushPromises();
}

describe('c-replayr-jobs', () => {
    afterEach(() => {
        while (document.body.firstChild) {
            document.body.removeChild(document.body.firstChild);
        }
        jest.clearAllMocks();
    });

    it('opens on the jobs needing a person, without test runs', async () => {
        const { element } = await render([row(1), row(2)]);

        expect(lastQuery()).toEqual(expect.objectContaining({ filter: 'needsPerson', includeTestRuns: false }));
        expect(element.shadowRoot.querySelector('lightning-datatable').data).toHaveLength(2);
        expect(element.shadowRoot.querySelector('[role="status"]').textContent).toBe('2 jobs shown.');
        expect(button(element, 'Replay selected').disabled).toBe(true);
        await expect(element).toBeAccessible();
    });

    it('gives each status an icon beside its label, and Retry-safe as words', async () => {
        const { element } = await render([row(1, { status: 'Succeeded', statusLabel: 'Succeeded' }), row(2, { retrySafe: false }), row(3, { status: 'Something_New' })]);

        const shown = element.shadowRoot.querySelector('lightning-datatable').data;
        expect(shown.map((r) => r.statusIcon)).toEqual(['utility:success', 'utility:warning', undefined]);
        expect(shown[0].statusClass).toBe('slds-text-color_success');
        expect(shown.map((r) => r.retrySafeText)).toEqual(['Yes', 'No', 'Yes']);
        expect(shown[1].statusLabel).toBe('Outcome unknown');
    });

    it('says when there is nothing to show, and shows a failure to read', async () => {
        let { element } = await render([]);
        expect(element.shadowRoot.textContent).toContain('No jobs to show.');
        document.body.removeChild(element);

        const failure = new Error('failed');
        failure.body = { message: "Replayr couldn't read jobs (QueryException): check your Replayr permission set." };
        listJobs.mockRejectedValue(failure);
        element = createElement('c-replayr-jobs', { is: ReplayrJobs });
        document.body.appendChild(element);
        await flushPromises();
        expect(element.shadowRoot.querySelector('[role="alert"]').textContent).toContain('check your Replayr permission set');
    });

    it('asks again when the filter, the endpoint or the test-run switch changes', async () => {
        const { element } = await render([row(1)]);

        element.shadowRoot.querySelector('lightning-combobox').dispatchEvent(new CustomEvent('change', { detail: { value: 'failed' } }));
        await flushPromises();
        expect(lastQuery().filter).toBe('failed');

        element.shadowRoot.querySelector('lightning-record-picker').dispatchEvent(new CustomEvent('change', { detail: { recordId: 'a01000000000001AAA' } }));
        await flushPromises();
        expect(lastQuery().endpointId).toBe('a01000000000001AAA');

        element.shadowRoot.querySelector('lightning-input').dispatchEvent(new CustomEvent('change', { detail: { checked: true } }));
        await flushPromises();
        expect(lastQuery()).toEqual(expect.objectContaining({ filter: 'failed', endpointId: 'a01000000000001AAA', includeTestRuns: true }));
    });

    it('loads the next page after the last row and adds it', async () => {
        const { element } = await render([row(1), row(2)], true);
        listJobs.mockResolvedValue({ rows: [row(3)], hasMore: false });

        button(element, 'Load more').click();
        await flushPromises();

        expect(lastQuery()).toEqual(expect.objectContaining({ beforeCreated: row(2).createdDate, beforeId: 2 }));
        expect(element.shadowRoot.querySelector('lightning-datatable').data).toHaveLength(3);
        expect(button(element, 'Load more')).toBeUndefined();
    });

    it('replays Retry-safe jobs without asking, then says what happened', async () => {
        const { element, toasts } = await render([row(1), row(2)]);
        replay.mockResolvedValue([
            { jobId: 1, done: true, message: 'Queued again.' },
            { jobId: 2, done: true, message: 'Queued again.' }
        ]);
        await select(element, [row(1), row(2)]);

        button(element, 'Replay selected').click();
        await flushPromises();

        expect(LightningConfirm.open).not.toHaveBeenCalled();
        expect(replay).toHaveBeenCalledWith({ jobIds: [1, 2], duplicateRiskConfirmed: false });
        expect(toasts[0]).toEqual(expect.objectContaining({ variant: 'success', message: '2 jobs replayed.' }));
        expect(listJobs).toHaveBeenCalledTimes(2);
    });

    it('asks before replaying a job that may send twice, and stops if the person says no', async () => {
        const risky = row(1, { retrySafe: false });
        const { element } = await render([risky]);
        await select(element, [risky]);
        LightningConfirm.open.mockResolvedValue(false);

        button(element, 'Replay selected').click();
        await flushPromises();

        expect(LightningConfirm.open).toHaveBeenCalledWith(expect.objectContaining({ message: expect.stringContaining('This job is not Retry-safe') }));
        expect(replay).not.toHaveBeenCalled();
    });

    it('replays once confirmed, and names why a job was not replayed', async () => {
        const risky = row(1, { retrySafe: false });
        const done = row(2, { status: 'Queued', replayable: false });
        const { element, toasts } = await render([risky, done]);
        await select(element, [risky, done]);
        LightningConfirm.open.mockResolvedValue(true);
        replay.mockResolvedValue([
            { jobId: 1, done: true, message: 'Queued again.' },
            { jobId: 2, done: false, message: 'Only finished jobs can be replayed.' }
        ]);

        button(element, 'Replay selected').click();
        await flushPromises();

        expect(replay).toHaveBeenCalledWith({ jobIds: [1, 2], duplicateRiskConfirmed: true });
        expect(toasts[0]).toEqual(expect.objectContaining({ variant: 'warning', message: '1 job replayed. 1 not: Only finished jobs can be replayed.' }));
        // The toast announces the action; the status line says what the list now shows
        expect(element.shadowRoot.querySelector('[role="status"]').textContent).toBe('2 jobs shown.');
    });

    it('resolves with the outcome and note from the dialog, or not at all if cancelled', async () => {
        const { element } = await render([row(1)]);
        await select(element, [row(1)]);
        ReplayrResolveModal.open.mockResolvedValue(undefined);

        button(element, 'Resolve selected').click();
        await flushPromises();
        expect(ReplayrResolveModal.open).toHaveBeenCalledWith(expect.objectContaining({ count: 1 }));
        expect(resolve).not.toHaveBeenCalled();

        ReplayrResolveModal.open.mockResolvedValue({ outcome: 'Failed', note: 'Never arrived.' });
        resolve.mockResolvedValue([{ jobId: 1, done: true, message: 'Resolved.' }]);
        button(element, 'Resolve selected').click();
        await flushPromises();
        expect(resolve).toHaveBeenCalledWith({ jobIds: [1], outcome: 'Failed', note: 'Never arrived.' });
    });

    it('shows only the latest answer when the filter changes while a read is under way', async () => {
        const { element } = await render([row(1)]);
        let answerFailed;
        let answerAll;
        listJobs.mockReturnValueOnce(new Promise((settle) => (answerFailed = settle)));
        listJobs.mockReturnValueOnce(new Promise((settle) => (answerAll = settle)));
        const combobox = element.shadowRoot.querySelector('lightning-combobox');

        combobox.dispatchEvent(new CustomEvent('change', { detail: { value: 'failed' } }));
        combobox.dispatchEvent(new CustomEvent('change', { detail: { value: 'all' } }));
        answerAll({ rows: [row(5), row(6)], hasMore: false });
        await flushPromises();
        expect(element.shadowRoot.querySelector('lightning-spinner')).toBeNull();
        // The older read answers last: dropped
        answerFailed({ rows: [row(9)], hasMore: true });
        await flushPromises();

        expect(element.shadowRoot.querySelector('lightning-datatable').data.map((r) => r.id)).toEqual([5, 6]);
        expect(button(element, 'Load more')).toBeUndefined();
    });

    it('never adds a page from before the filter changed', async () => {
        const { element } = await render([row(1), row(2)], true);
        let answerMore;
        listJobs.mockReturnValueOnce(new Promise((settle) => (answerMore = settle)));
        listJobs.mockResolvedValueOnce({ rows: [row(7)], hasMore: false });

        button(element, 'Load more').click();
        element.shadowRoot.querySelector('lightning-combobox').dispatchEvent(new CustomEvent('change', { detail: { value: 'failed' } }));
        await flushPromises();
        answerMore({ rows: [row(3)], hasMore: false });
        await flushPromises();

        expect(element.shadowRoot.querySelector('lightning-datatable').data.map((r) => r.id)).toEqual([7]);
    });

    it('leaves nothing from the previous filter to act on when a read fails', async () => {
        const { element } = await render([row(1), row(2)], true);
        await select(element, [row(1)]);
        listJobs.mockRejectedValue(new Error('Network error'));

        element.shadowRoot.querySelector('lightning-combobox').dispatchEvent(new CustomEvent('change', { detail: { value: 'failed' } }));
        await flushPromises();

        expect(element.shadowRoot.querySelector('[role="alert"]').textContent).toBe("Replayr couldn't read jobs.");
        expect(element.shadowRoot.querySelector('lightning-datatable')).toBeNull();
        expect(button(element, 'Load more')).toBeUndefined();
        expect(button(element, 'Replay selected').disabled).toBe(true);
        await expect(element).toBeAccessible();
    });

    it('does one replay however often Replay is clicked', async () => {
        const risky = row(1, { retrySafe: false });
        const { element } = await render([risky]);
        await select(element, [risky]);
        let answer;
        LightningConfirm.open.mockReturnValue(new Promise((settle) => (answer = settle)));
        replay.mockResolvedValue([{ jobId: 1, done: true, message: 'Queued again.' }]);

        button(element, 'Replay selected').click();
        button(element, 'Replay selected').click();
        await flushPromises();
        expect(button(element, 'Replay selected').disabled).toBe(true);
        answer(true);
        await flushPromises();

        expect(LightningConfirm.open).toHaveBeenCalledTimes(1);
        expect(replay).toHaveBeenCalledTimes(1);
    });

    it('names each different reason jobs were not done, once', async () => {
        const { element, toasts } = await render([row(1), row(2), row(3)]);
        await select(element, [row(1), row(2), row(3)]);
        replay.mockResolvedValue([
            { jobId: 1, done: false, message: 'A test run can\'t be replayed.' },
            { jobId: 2, done: false, message: 'Only finished jobs can be replayed.' },
            { jobId: 3, done: false, message: 'A test run can\'t be replayed.' }
        ]);

        button(element, 'Replay selected').click();
        await flushPromises();

        expect(toasts[0].message).toBe("0 jobs replayed. 3 not: A test run can't be replayed. Only finished jobs can be replayed.");
    });

    it("shows the server's reason when an action is refused as a whole", async () => {
        const { element, toasts } = await render([row(1)]);
        await select(element, [row(1)]);
        const refusal = new Error('refused');
        refusal.body = { message: 'At most 200 jobs at a time.' };
        replay.mockRejectedValue(refusal);

        button(element, 'Replay selected').click();
        await flushPromises();

        expect(toasts[0]).toEqual(expect.objectContaining({ variant: 'error', message: 'At most 200 jobs at a time.' }));
    });

    it('opens a job from its number, and on the way back reads the list again only if the job changed', async () => {
        const { element } = await render([row(1), row(2)]);
        const table = element.shadowRoot.querySelector('lightning-datatable');

        table.dispatchEvent(new CustomEvent('rowaction', { detail: { action: { name: 'open' }, row: row(2) } }));
        await flushPromises();
        const opened = element.shadowRoot.querySelector('c-replayr-job-detail');
        expect(opened.jobId).toBe(2);
        // The list is hidden, not removed, so its scroll and selection survive
        expect(element.shadowRoot.querySelector('lightning-card').className).toContain('slds-hide');

        opened.dispatchEvent(new CustomEvent('back', { detail: { changed: false } }));
        await flushPromises();
        expect(element.shadowRoot.querySelector('c-replayr-job-detail')).toBeNull();
        expect(element.shadowRoot.querySelector('lightning-card').className).not.toContain('slds-hide');
        expect(element.shadowRoot.activeElement).toBe(element.shadowRoot.querySelector('[slot="title"]'));
        expect(element.shadowRoot.querySelector('lightning-datatable').data).toHaveLength(2);
        expect(listJobs).toHaveBeenCalledTimes(1);

        element.shadowRoot.querySelector('lightning-datatable').dispatchEvent(new CustomEvent('rowaction', { detail: { action: { name: 'open' }, row: row(1) } }));
        await flushPromises();
        element.shadowRoot.querySelector('c-replayr-job-detail').dispatchEvent(new CustomEvent('back', { detail: { changed: true } }));
        await flushPromises();
        expect(listJobs).toHaveBeenCalledTimes(2);
    });
});
