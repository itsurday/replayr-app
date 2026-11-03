import { createElement } from 'lwc';
import ReplayrTestMode from 'c/replayrTestMode';
import run from '@salesforce/apex/ConsoleTestMode.run';

jest.mock('@salesforce/apex/ConsoleTestMode.run', () => ({ default: jest.fn() }), { virtual: true });

const ENDPOINT = 'a01000000000001AAA';
const RECORD = '001000000000001AAA';
const PREVIEW = {
    method: 'POST',
    url: 'callout:Acme_API/lookup?acme_pin=****',
    headers: [{ name: 'Content-Type', value: 'application/json' }],
    body: '{"name": "Acme", "acme_pin": "****"}',
    bodyWithheld: null,
    sideEffectFree: true,
    sent: false
};

const flushPromises = () => Array.from({ length: 10 }).reduce((chain) => chain.then(() => undefined), Promise.resolve());

async function render(targetObject = 'Account') {
    const element = createElement('c-replayr-test-mode', { is: ReplayrTestMode });
    element.endpointId = ENDPOINT;
    element.targetObject = targetObject;
    document.body.appendChild(element);
    await flushPromises();
    return element;
}

const button = (element, label) => [...element.shadowRoot.querySelectorAll('lightning-button')].find((b) => b.label === label);
const status = (element) => element.shadowRoot.querySelector('[role="status"]').textContent;

async function pick(element, recordId = RECORD) {
    element.shadowRoot.querySelector('lightning-record-picker').dispatchEvent(new CustomEvent('change', { detail: { recordId } }));
    await flushPromises();
}

describe('c-replayr-test-mode', () => {
    afterEach(() => {
        while (document.body.firstChild) {
            document.body.removeChild(document.body.firstChild);
        }
        jest.clearAllMocks();
    });

    it('asks for a record of the Request mapping’s object before it can preview', async () => {
        const element = await render('Account');

        expect(element.shadowRoot.querySelector('lightning-record-picker').objectApiName).toBe('Account');
        expect(button(element, 'Preview').disabled).toBe(true);
        expect(button(element, 'Send a test')).toBeUndefined();
        await pick(element);
        expect(button(element, 'Preview').disabled).toBe(false);
        await expect(element).toBeAccessible();
    });

    it('previews the request without sending it, then offers to send a Side-effect-free endpoint', async () => {
        const element = await render();
        await pick(element);
        run.mockResolvedValue(PREVIEW);

        button(element, 'Preview').click();
        await flushPromises();

        expect(run).toHaveBeenCalledWith({ endpointId: ENDPOINT, recordId: RECORD, send: false });
        expect(element.shadowRoot.textContent).toContain('POST callout:Acme_API/lookup?acme_pin=****');
        expect(element.shadowRoot.querySelector('li').textContent).toBe('Content-Type: application/json');
        expect(element.shadowRoot.querySelector('pre').textContent).toBe(PREVIEW.body);
        expect(status(element)).toBe('Request built, not sent.');
        expect(button(element, 'Send a test')).toBeDefined();
        await expect(element).toBeAccessible();
    });

    it('sends the test and shows the reply, its status and that it was logged', async () => {
        const element = await render();
        await pick(element);
        run.mockResolvedValueOnce(PREVIEW);
        button(element, 'Preview').click();
        await flushPromises();
        run.mockResolvedValueOnce({ ...PREVIEW, sent: true, statusCode: 200, status: 'OK', durationMs: 120, responseBody: '{"ok": true}', jobId: 'a02000000000001AAA' });

        button(element, 'Send a test').click();
        await flushPromises();

        expect(run).toHaveBeenLastCalledWith({ endpointId: ENDPOINT, recordId: RECORD, send: true });
        expect(element.shadowRoot.textContent).toContain('HTTP 200 OK in 120 ms');
        expect([...element.shadowRoot.querySelectorAll('pre')].map((pre) => pre.textContent)).toEqual([PREVIEW.body, '{"ok": true}']);
        expect(element.shadowRoot.textContent).toContain('Logged as a test job');
        expect(status(element)).toBe('Test sent: HTTP 200 OK in 120 ms');
    });

    it('says why a body or reply is not shown, and when a call got no reply', async () => {
        const element = await render();
        await pick(element);
        run.mockResolvedValue({
            ...PREVIEW,
            body: null,
            bodyWithheld: 'Not shown: Replayr can only mask JSON.',
            sent: true,
            statusCode: null,
            error: 'Read timed out',
            responseWithheld: 'Not shown: Replayr can only mask JSON.'
        });

        button(element, 'Preview').click();
        await flushPromises();

        expect(element.shadowRoot.querySelector('pre')).toBeNull();
        expect(element.shadowRoot.textContent).toContain('Not shown: Replayr can only mask JSON.');
        expect(element.shadowRoot.textContent).toContain('No reply arrived.');
        expect(element.shadowRoot.textContent).toContain('Read timed out');
    });

    it('only ever previews an endpoint with side effects, and says so', async () => {
        const element = await render();
        await pick(element);
        run.mockResolvedValue({ ...PREVIEW, sideEffectFree: false });

        button(element, 'Preview').click();
        await flushPromises();

        expect(button(element, 'Send a test')).toBeUndefined();
        expect(element.shadowRoot.textContent).toContain("isn't Side-effect-free");
    });

    it('drops an answer for a record no longer chosen, and keeps the picker unavailable meanwhile', async () => {
        const element = await render();
        await pick(element);
        let answer;
        run.mockReturnValueOnce(new Promise((settle) => (answer = settle)));

        button(element, 'Preview').click();
        await flushPromises();
        expect(element.shadowRoot.querySelector('lightning-record-picker').disabled).toBe(true);
        await pick(element, '001000000000002AAA');
        answer(PREVIEW);
        await flushPromises();

        expect(element.shadowRoot.querySelector('pre')).toBeNull();
        expect(button(element, 'Send a test')).toBeUndefined();
    });

    it('forgets the record and result when the Request mapping’s object changes', async () => {
        const element = await render('Account');
        await pick(element);
        run.mockResolvedValue(PREVIEW);
        button(element, 'Preview').click();
        await flushPromises();

        element.targetObject = 'Contact';
        await flushPromises();

        expect(element.shadowRoot.querySelector('pre')).toBeNull();
        expect(button(element, 'Preview').disabled).toBe(true);
    });

    it('needs no record when the endpoint has no Request mapping', async () => {
        // null, not undefined, which would fall back to the helper's default object
        const element = await render(null);
        run.mockResolvedValue({ ...PREVIEW, body: null });

        expect(element.shadowRoot.querySelector('lightning-record-picker')).toBeNull();
        button(element, 'Preview').click();
        await flushPromises();

        expect(run).toHaveBeenCalledWith({ endpointId: ENDPOINT, recordId: undefined, send: false });
        expect(element.shadowRoot.textContent).toContain('No body.');
    });

    it("shows the server's reason, runs one test however often it is clicked, and clears a result on a new record", async () => {
        const element = await render();
        await pick(element);
        let answer;
        run.mockReturnValueOnce(new Promise((settle, fail) => (answer = fail)));

        button(element, 'Preview').click();
        button(element, 'Preview').click();
        await flushPromises();
        expect(run).toHaveBeenCalledTimes(1);
        const refusal = new Error('refused');
        refusal.body = { message: 'Testing an endpoint needs the Replayr Admin permission set.' };
        answer(refusal);
        await flushPromises();
        expect(element.shadowRoot.querySelector('[role="alert"]').textContent).toBe('Testing an endpoint needs the Replayr Admin permission set.');

        run.mockResolvedValue(PREVIEW);
        button(element, 'Preview').click();
        await flushPromises();
        expect(element.shadowRoot.querySelector('pre')).not.toBeNull();
        await pick(element, '001000000000002AAA');
        expect(element.shadowRoot.querySelector('pre')).toBeNull();
    });
});
