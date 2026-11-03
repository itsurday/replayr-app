import { createElement } from 'lwc';
import ReplayrMappings from 'c/replayrMappings';
import mappings from '@salesforce/apex/ConsoleMappings.mappings';
import saveRequest from '@salesforce/apex/ConsoleMappings.saveRequest';

jest.mock('@salesforce/apex/ConsoleMappings.mappings', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex/ConsoleMappings.saveRequest', () => ({ default: jest.fn() }), { virtual: true });

const ENDPOINT = 'a01000000000001AAA';
const REQUEST = { id: 'a03000000000001AAA', direction: 'Request', targetObject: 'Account', rules: '{"name": "{{Name}}"}' };
const RESPONSE = {
    id: 'a03000000000002AAA',
    direction: 'Response',
    targetObject: 'Account',
    operation: 'Update',
    matchField: 'AccountNumber',
    listPath: 'items',
    rules: '{"fields": {"Description": "about"}}'
};

const flushPromises = () => Array.from({ length: 10 }).reduce((chain) => chain.then(() => undefined), Promise.resolve());

async function render(rows, canEdit = true) {
    mappings.mockResolvedValue({ rows, canEdit });
    const element = createElement('c-replayr-mappings', { is: ReplayrMappings });
    element.endpointId = ENDPOINT;
    document.body.appendChild(element);
    await flushPromises();
    return element;
}

const button = (element, label) => [...element.shadowRoot.querySelectorAll('lightning-button')].find((b) => b.label === label);

describe('c-replayr-mappings', () => {
    afterEach(() => {
        while (document.body.firstChild) {
            document.body.removeChild(document.body.firstChild);
        }
        jest.clearAllMocks();
    });

    it('shows the endpoint’s Request template and Response rules', async () => {
        const element = await render([REQUEST, RESPONSE]);

        expect(mappings).toHaveBeenCalledWith({ endpointId: ENDPOINT });
        const code = [...element.shadowRoot.querySelectorAll('pre')].map((pre) => pre.textContent);
        expect(code).toEqual(['{"name": "{{Name}}"}', '{"fields": {"Description": "about"}}']);
        expect(element.shadowRoot.textContent).toContain('For Account:');
        expect(element.shadowRoot.textContent).toContain('Update Account, matching on AccountNumber, each item of items:');
        expect(button(element, 'Edit Request mapping')).toBeDefined();
        await expect(element).toBeAccessible();
    });

    it('says what is missing, and offers New only to those who may edit', async () => {
        let element = await render([]);
        expect(element.shadowRoot.textContent).toContain('No Request mapping');
        expect(element.shadowRoot.textContent).toContain('No Response mapping');
        expect(button(element, 'New Request mapping')).toBeDefined();
        document.body.removeChild(element);

        element = await render([REQUEST], false);
        expect(button(element, 'Edit Request mapping')).toBeUndefined();
    });

    it('edits the Request mapping, saves it through the server and shows it again', async () => {
        const element = await render([REQUEST]);
        button(element, 'Edit Request mapping').click();
        await flushPromises();

        const heading = element.shadowRoot.querySelector('h4[tabindex="-1"]');
        expect(heading.textContent).toBe('Edit the Request mapping');
        expect(element.shadowRoot.activeElement).toBe(heading);
        expect(element.shadowRoot.querySelector('lightning-input').value).toBe('Account');
        element.shadowRoot.querySelector('lightning-textarea').dispatchEvent(new CustomEvent('change', { detail: { value: '{"site": "{{Site}}"}' } }));
        saveRequest.mockResolvedValue(REQUEST.id);
        mappings.mockResolvedValue({ rows: [{ ...REQUEST, rules: '{"site": "{{Site}}"}' }], canEdit: true });

        button(element, 'Save').click();
        await flushPromises();

        expect(saveRequest).toHaveBeenCalledWith({ id: REQUEST.id, endpointId: ENDPOINT, targetObject: 'Account', template: '{"site": "{{Site}}"}' });
        expect(element.shadowRoot.querySelector('lightning-textarea')).toBeNull();
        expect(element.shadowRoot.querySelector('pre').textContent).toBe('{"site": "{{Site}}"}');
        expect(element.shadowRoot.querySelector('[role="status"]').textContent).toBe('Request mapping saved.');
    });

    it('creates a Request mapping for this endpoint', async () => {
        const element = await render([]);
        button(element, 'New Request mapping').click();
        await flushPromises();
        element.shadowRoot.querySelector('lightning-input').dispatchEvent(new CustomEvent('change', { detail: { value: 'Contact' } }));
        element.shadowRoot.querySelector('lightning-textarea').dispatchEvent(new CustomEvent('change', { detail: { value: '{"last": "{{LastName}}"}' } }));
        saveRequest.mockResolvedValue('a03000000000009AAA');

        button(element, 'Save').click();
        await flushPromises();

        expect(saveRequest).toHaveBeenCalledWith({ id: undefined, endpointId: ENDPOINT, targetObject: 'Contact', template: '{"last": "{{LastName}}"}' });
    });

    it('keeps the editor open with the server’s reason when it refuses, and drops changes on Cancel', async () => {
        const element = await render([REQUEST]);
        button(element, 'Edit Request mapping').click();
        await flushPromises();
        const refusal = new Error('refused');
        refusal.body = { message: 'Not saved: Not a merge field: {{NoSuchField__c}}' };
        saveRequest.mockRejectedValue(refusal);

        button(element, 'Save').click();
        await flushPromises();

        expect(element.shadowRoot.querySelector('[role="alert"]').textContent).toBe('Not saved: Not a merge field: {{NoSuchField__c}}');
        expect(element.shadowRoot.querySelector('lightning-textarea')).not.toBeNull();
        await expect(element).toBeAccessible();

        button(element, 'Cancel').click();
        await flushPromises();
        expect(element.shadowRoot.querySelector('lightning-textarea')).toBeNull();
        expect(element.shadowRoot.querySelector('pre').textContent).toBe(REQUEST.rules);
    });

    it('shows only the endpoint now open, even when an earlier one answers last', async () => {
        const element = await render([REQUEST]);
        button(element, 'Edit Request mapping').click();
        await flushPromises();
        let answerOld;
        mappings.mockReturnValueOnce(new Promise((settle) => (answerOld = settle)));
        mappings.mockResolvedValueOnce({ rows: [], canEdit: true });

        element.endpointId = 'a01000000000002AAA';
        element.endpointId = 'a01000000000003AAA';
        await flushPromises();
        answerOld({ rows: [REQUEST], canEdit: true });
        await flushPromises();

        expect(element.shadowRoot.querySelector('lightning-textarea')).toBeNull();
        expect(element.shadowRoot.querySelector('pre')).toBeNull();
        expect(element.shadowRoot.textContent).toContain('No Request mapping');
    });

    it('puts focus back on the button after Cancel', async () => {
        const element = await render([REQUEST]);
        button(element, 'Edit Request mapping').click();
        await flushPromises();
        // The test stand-in for lightning-button can't take focus, so the call itself is what is checked
        const focus = jest.spyOn(HTMLElement.prototype, 'focus');

        button(element, 'Cancel').click();
        await flushPromises();

        expect(focus.mock.contexts).toContain(button(element, 'Edit Request mapping'));
        focus.mockRestore();
    });

    it('shows no out-of-date template when reading again after a save fails', async () => {
        const element = await render([REQUEST]);
        button(element, 'Edit Request mapping').click();
        await flushPromises();
        saveRequest.mockResolvedValue(REQUEST.id);
        mappings.mockRejectedValue(new Error('Network error'));

        button(element, 'Save').click();
        await flushPromises();

        expect(element.shadowRoot.querySelector('pre')).toBeNull();
        expect(element.shadowRoot.querySelector('[role="alert"]').textContent).toBe("Replayr couldn't read mappings.");
    });

    it('opens the Response editor, and on save closes it and reads the mappings again', async () => {
        const element = await render([REQUEST, RESPONSE]);
        button(element, 'Edit Response mapping').click();
        await flushPromises();

        const editor = element.shadowRoot.querySelector('c-replayr-response-editor');
        expect(editor.mapping).toEqual(RESPONSE);
        expect(editor.endpointId).toBe(ENDPOINT);
        editor.dispatchEvent(new CustomEvent('saved'));
        await flushPromises();

        expect(element.shadowRoot.querySelector('c-replayr-response-editor')).toBeNull();
        expect(mappings).toHaveBeenCalledTimes(2);
        expect(element.shadowRoot.querySelector('[role="status"]').textContent).toBe('Response mapping saved.');
    });

    it('offers New Response mapping when there is none, and closes the editor on Cancel', async () => {
        const element = await render([REQUEST]);
        button(element, 'New Response mapping').click();
        await flushPromises();
        expect(element.shadowRoot.querySelector('c-replayr-response-editor').mapping).toBeUndefined();

        element.shadowRoot.querySelector('c-replayr-response-editor').dispatchEvent(new CustomEvent('cancel'));
        await flushPromises();

        expect(element.shadowRoot.querySelector('c-replayr-response-editor')).toBeNull();
        expect(mappings).toHaveBeenCalledTimes(1);
    });

    it("shows the server's message when mappings can't be read", async () => {
        const failure = new Error('failed');
        failure.body = { message: "Replayr couldn't read mappings (QueryException): check your Replayr permission set." };
        mappings.mockRejectedValue(failure);
        const element = createElement('c-replayr-mappings', { is: ReplayrMappings });
        element.endpointId = ENDPOINT;
        document.body.appendChild(element);
        await flushPromises();

        expect(element.shadowRoot.querySelector('[role="alert"]').textContent).toContain('check your Replayr permission set');
    });
});
