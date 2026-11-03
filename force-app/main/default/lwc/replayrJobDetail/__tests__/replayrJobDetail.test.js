import { createElement } from 'lwc';
import ReplayrJobDetail from 'c/replayrJobDetail';
import detail from '@salesforce/apex/ConsoleJobs.detail';
import replay from '@salesforce/apex/ConsoleJobs.replay';
import resolve from '@salesforce/apex/ConsoleJobs.resolve';
import LightningConfirm from 'lightning/confirm';
import ReplayrResolveModal from 'c/replayrResolveModal';

jest.mock('@salesforce/apex/ConsoleJobs.detail', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex/ConsoleJobs.replay', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex/ConsoleJobs.resolve', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('lightning/confirm', () => ({ __esModule: true, default: { open: jest.fn() } }));
jest.mock('c/replayrResolveModal', () => ({ __esModule: true, default: { open: jest.fn() } }));

function job(rowOverrides = {}, overrides = {}) {
    return {
        job: {
            id: 'a02000000000001AAA',
            name: 'JOB-000042',
            endpoint: 'Orders',
            status: 'Failed',
            statusLabel: 'Failed',
            attempts: 2,
            httpStatus: 400,
            result: 'HTTP 400 Bad Request',
            recordId: '001000000000001AAA',
            retrySafe: true,
            replayable: true,
            createdDate: '2026-11-02T04:00:00.000Z',
            nextAttemptAt: null,
            ...rowOverrides
        },
        method: 'POST',
        path: '/orders?acme_pin=****',
        idempotencyKey: 'replayr-a02-1',
        requestBodyReadable: true,
        requestBody: '{"acme_pin": "****", "name": "Acme"}',
        requestBodyWithheld: null,
        attempts: [
            { at: '2026-11-02T04:01:00.000Z', outcome: 'Failed', httpStatus: 400, message: 'HTTP 400 Bad Request', durationMs: 120 },
            { at: '2026-11-02T04:00:30.000Z', outcome: 'Failed', httpStatus: 503, message: 'HTTP 503', durationMs: 80 }
        ],
        ...overrides
    };
}

const flushPromises = () => Array.from({ length: 10 }).reduce((chain) => chain.then(() => undefined), Promise.resolve());

async function render(shown) {
    if (shown instanceof Error) {
        detail.mockRejectedValue(shown);
    } else {
        detail.mockResolvedValue(shown);
    }
    const element = createElement('c-replayr-job-detail', { is: ReplayrJobDetail });
    element.jobId = 'a02000000000001AAA';
    const toasts = [];
    const backs = [];
    element.addEventListener('lightning__showtoast', (event) => toasts.push(event.detail));
    element.addEventListener('back', (event) => backs.push(event.detail));
    document.body.appendChild(element);
    await flushPromises();
    return { element, toasts, backs };
}

const button = (element, label) => [...element.shadowRoot.querySelectorAll('lightning-button')].find((b) => b.label === label);

function fields(element) {
    const labels = [...element.shadowRoot.querySelectorAll('dt')].map((dt) => dt.textContent);
    const values = [...element.shadowRoot.querySelectorAll('dd')].map((dd) => dd.textContent);
    return Object.fromEntries(labels.map((label, i) => [label, values[i]]));
}

describe('c-replayr-job-detail', () => {
    afterEach(() => {
        while (document.body.firstChild) {
            document.body.removeChild(document.body.firstChild);
        }
        jest.clearAllMocks();
    });

    it('shows the job, its attempts and its masked request, and puts focus on its name', async () => {
        const { element } = await render(job());

        expect(detail).toHaveBeenCalledWith({ jobId: 'a02000000000001AAA' });
        const heading = element.shadowRoot.querySelector('[slot="title"]');
        expect(heading.textContent).toBe('JOB-000042: Failed');
        expect(element.shadowRoot.activeElement).toBe(heading);
        const shown = fields(element);
        expect(shown.Request).toBe('POST /orders?acme_pin=****');
        expect(shown['Retry-safe']).toBe('Yes');
        expect(shown['Next attempt']).toBe('—');
        expect(element.shadowRoot.querySelector('lightning-datatable').data).toHaveLength(2);
        expect(element.shadowRoot.querySelector('pre').textContent).toBe('{"acme_pin": "****", "name": "Acme"}');
        expect(button(element, 'Replay')).toBeDefined();
        expect(button(element, 'Resolve')).toBeUndefined();
        await expect(element).toBeAccessible();
    });

    it('says why a body is not shown', async () => {
        let { element } = await render(job({}, { requestBodyReadable: false, requestBody: null }));
        expect(element.shadowRoot.querySelector('pre')).toBeNull();
        expect(element.shadowRoot.textContent).toContain('Only Replayr Admins can see request bodies.');
        document.body.removeChild(element);

        ({ element } = await render(job({}, { requestBody: null, requestBodyWithheld: 'Not shown: Replayr can only mask JSON bodies.' })));
        expect(element.shadowRoot.textContent).toContain('Not shown: Replayr can only mask JSON bodies.');
        document.body.removeChild(element);

        ({ element } = await render(job({}, { requestBody: null, attempts: [] })));
        expect(element.shadowRoot.textContent).toContain('No request body.');
        expect(element.shadowRoot.textContent).toContain('No attempts yet.');
    });

    it('offers Replay and Resolve for an unknown outcome, says how they differ, and warns before sending again', async () => {
        const { element } = await render(job({ status: 'Outcome_Unknown', statusLabel: 'Outcome unknown', replayable: true, retrySafe: false }));
        expect(button(element, 'Resolve')).toBeDefined();
        expect(button(element, 'Replay')).toBeDefined();
        expect(element.shadowRoot.textContent).toContain('Replay sends the call again. Resolve only records how it ended: nothing is sent.');
        expect(fields(element)['Retry-safe']).toBe('No: never resent automatically');
        LightningConfirm.open.mockResolvedValue(false);

        button(element, 'Replay').click();
        await flushPromises();

        expect(LightningConfirm.open).toHaveBeenCalledWith(expect.objectContaining({ message: expect.stringContaining('Its first call may already have worked') }));
        expect(replay).not.toHaveBeenCalled();
        await expect(element).toBeAccessible();
    });

    it('keeps Back unavailable while an action runs, so its result is never lost', async () => {
        const { element } = await render(job());
        let answer;
        replay.mockReturnValue(new Promise((settle) => (answer = settle)));

        button(element, 'Replay').click();
        await flushPromises();
        expect(button(element, 'Back to jobs').disabled).toBe(true);
        expect(button(element, 'Replay').disabled).toBe(true);

        answer([{ jobId: 'a02000000000001AAA', done: true, message: 'Queued again.' }]);
        await flushPromises();
        expect(button(element, 'Back to jobs').disabled).toBe(false);
    });

    it('shows only the latest job when it changes while a read is under way', async () => {
        const { element } = await render(job());
        let answerOld;
        detail.mockReturnValueOnce(new Promise((settle) => (answerOld = settle)));
        detail.mockResolvedValueOnce(job({ name: 'JOB-000099' }));

        element.jobId = 'a02000000000002AAA';
        element.jobId = 'a02000000000003AAA';
        await flushPromises();
        answerOld(job({ name: 'JOB-000050' }));
        await flushPromises();

        expect(element.shadowRoot.querySelector('[slot="title"]').textContent).toBe('JOB-000099: Failed');
    });

    it('replays after the warning, shows the job as it is now, and says the list must be read again', async () => {
        const { element, toasts, backs } = await render(job({ retrySafe: false }));
        LightningConfirm.open.mockResolvedValue(true);
        replay.mockResolvedValue([{ jobId: 'a02000000000001AAA', done: true, message: 'Queued again.' }]);
        detail.mockResolvedValue(job({ status: 'Queued', statusLabel: 'Queued', replayable: false }));

        button(element, 'Replay').click();
        await flushPromises();

        expect(LightningConfirm.open).toHaveBeenCalledWith(expect.objectContaining({ message: expect.stringContaining('This job is not Retry-safe') }));
        expect(replay).toHaveBeenCalledWith({ jobIds: ['a02000000000001AAA'], duplicateRiskConfirmed: true });
        expect(toasts[0]).toEqual(expect.objectContaining({ variant: 'success', message: '1 job replayed.' }));
        expect(element.shadowRoot.querySelector('[slot="title"]').textContent).toBe('JOB-000042: Queued');
        expect(button(element, 'Replay')).toBeUndefined();

        button(element, 'Back to jobs').click();
        expect(backs).toEqual([{ changed: true }]);
    });

    it('resolves with what the dialog says, and changes nothing if it is cancelled', async () => {
        const { element, backs } = await render(job({ status: 'Dead', statusLabel: 'Retries used up' }));
        ReplayrResolveModal.open.mockResolvedValue(undefined);

        button(element, 'Resolve').click();
        await flushPromises();
        expect(resolve).not.toHaveBeenCalled();
        button(element, 'Back to jobs').click();
        expect(backs).toEqual([{ changed: false }]);

        ReplayrResolveModal.open.mockResolvedValue({ outcome: 'Failed', note: 'Gave up.' });
        resolve.mockResolvedValue([{ jobId: 'a02000000000001AAA', done: true, message: 'Resolved.' }]);
        button(element, 'Resolve').click();
        await flushPromises();
        expect(resolve).toHaveBeenCalledWith({ jobIds: ['a02000000000001AAA'], outcome: 'Failed', note: 'Gave up.' });
    });

    it("shows the server's reason when the job can't be read, or an action is refused", async () => {
        const missing = new Error('missing');
        missing.body = { message: "Job not found, or you can't see it." };
        const { element } = await render(missing);
        expect(element.shadowRoot.querySelector('[role="alert"]').textContent).toBe("Job not found, or you can't see it.");
        expect(element.shadowRoot.querySelector('dl')).toBeNull();
        expect(element.shadowRoot.activeElement).toBe(element.shadowRoot.querySelector('[slot="title"]'));
        document.body.removeChild(element);

        const second = await render(job());
        const reads = detail.mock.calls.length;
        const refusal = new Error('refused');
        refusal.body = { message: 'You need the Replayr Admin or Replayr Operator permission set.' };
        replay.mockRejectedValue(refusal);
        button(second.element, 'Replay').click();
        await flushPromises();
        expect(second.toasts[0]).toEqual(expect.objectContaining({ variant: 'error', message: 'You need the Replayr Admin or Replayr Operator permission set.' }));
        // Refused, so nothing changed: the job isn't read again
        expect(detail).toHaveBeenCalledTimes(reads);
    });
});
