import { createElement } from 'lwc';
import ReplayrProvider from 'c/replayrProvider';
import checkProvider from '@salesforce/apex/ConsoleProviderCheck.check';

jest.mock('@salesforce/apex/ConsoleProviderCheck.check', () => ({ default: jest.fn() }), { virtual: true });
// The endpoint view holds the mappings, which read their own
jest.mock('@salesforce/apex/ConsoleMappings.mappings', () => ({ default: jest.fn(() => Promise.resolve({ rows: [], canEdit: false })) }), { virtual: true });

const ORDERS = { id: 'a01000000000001AAA', name: 'Orders', key: 'acme-orders', method: 'POST', path: '/orders', retrySafe: false, allowSending: true };
const ACME = { id: 'a00000000000001AAA', name: 'Acme', key: 'acme', namedCredential: 'Acme_API', endpoints: [ORDERS] };

const flushPromises = () => Array.from({ length: 10 }).reduce((chain) => chain.then(() => undefined), Promise.resolve());

async function render(provider = ACME, canCreateEndpoints = true) {
    const element = createElement('c-replayr-provider', { is: ReplayrProvider });
    element.provider = provider;
    element.canCreateEndpoints = canCreateEndpoints;
    const events = [];
    element.addEventListener('back', () => events.push('back'));
    element.addEventListener('changed', () => events.push('changed'));
    document.body.appendChild(element);
    await flushPromises();
    return { element, events };
}

const button = (element, label) => [...element.shadowRoot.querySelectorAll('lightning-button')].find((b) => b.label === label);
const heading = (element) => element.shadowRoot.querySelector('[slot="title"]');

describe('c-replayr-provider', () => {
    afterEach(() => {
        while (document.body.firstChild) {
            document.body.removeChild(document.body.firstChild);
        }
        jest.clearAllMocks();
    });

    it('checks the provider and shows each finding with its meaning in words', async () => {
        const { element } = await render();
        checkProvider.mockResolvedValue({
            checked: true,
            message: null,
            findings: [
                { state: 'passed', text: 'Named Credential "Acme_API" exists.' },
                { state: 'failed', text: 'Callouts are not enabled: in Setup, Named Credentials, edit "Acme_API" and tick Enabled for Callouts.' },
                { state: 'notChecked', text: 'This Named Credential has no External Credential (an older kind), so there is no principal access to check.' }
            ]
        });

        button(element, 'Check this provider').click();
        await flushPromises();

        expect(checkProvider).toHaveBeenCalledWith({ providerId: ACME.id });
        const items = [...element.shadowRoot.querySelectorAll('li')];
        expect(items.map((li) => li.textContent.trim())).toEqual([
            'Named Credential "Acme_API" exists.',
            'Callouts are not enabled: in Setup, Named Credentials, edit "Acme_API" and tick Enabled for Callouts.',
            'This Named Credential has no External Credential (an older kind), so there is no principal access to check.'
        ]);
        expect(items.map((li) => li.querySelector('lightning-icon').alternativeText)).toEqual(['Passed', 'Problem', 'Not checked']);
        expect(element.shadowRoot.querySelector('[role="status"]').textContent).toBe('Check done: 1 problem.');
        await expect(element).toBeAccessible();
    });

    it('clears an earlier check once the provider is saved', async () => {
        const { element } = await render();
        checkProvider.mockResolvedValue({ checked: true, message: null, findings: [{ state: 'passed', text: 'Callouts are enabled.' }] });
        button(element, 'Check this provider').click();
        await flushPromises();
        expect(element.shadowRoot.querySelectorAll('li')).toHaveLength(1);

        element.shadowRoot.querySelector('lightning-record-form').dispatchEvent(new CustomEvent('success', { detail: { id: ACME.id } }));
        await flushPromises();

        expect(element.shadowRoot.querySelectorAll('li')).toHaveLength(0);
    });

    it('says when the check needs a permission the person lacks', async () => {
        const { element } = await render();
        const message = 'Checking a provider needs the View Setup and Configuration permission. Ask a Salesforce administrator to run the check.';
        checkProvider.mockResolvedValue({ checked: false, message, findings: [] });

        button(element, 'Check this provider').click();
        await flushPromises();

        expect(element.shadowRoot.textContent).toContain(message);
        expect(element.shadowRoot.querySelectorAll('li')).toHaveLength(0);
        expect(element.shadowRoot.querySelector('[role="status"]').textContent).toBe(message);
    });

    it("shows the server's reason when the check fails, and runs one check however often it is clicked", async () => {
        const { element } = await render();
        let answer;
        checkProvider.mockReturnValue(new Promise((settle, fail) => (answer = fail)));

        button(element, 'Check this provider').click();
        button(element, 'Check this provider').click();
        await flushPromises();
        expect(checkProvider).toHaveBeenCalledTimes(1);
        expect(button(element, 'Check this provider').disabled).toBe(true);
        const failure = new Error('failed');
        failure.body = { message: "Replayr couldn't check this provider (QueryException)." };
        answer(failure);
        await flushPromises();

        expect(element.shadowRoot.querySelector('[role="alert"]').textContent).toBe("Replayr couldn't check this provider (QueryException).");
        expect(button(element, 'Check this provider').disabled).toBe(false);
    });

    it('shows the provider in a record form and its endpoints, with focus on its name', async () => {
        const { element } = await render();

        expect(heading(element).textContent).toBe('Acme');
        expect(element.shadowRoot.activeElement).toBe(heading(element));
        const form = element.shadowRoot.querySelector('lightning-record-form');
        expect(form.recordId).toBe(ACME.id);
        expect(form.mode).toBe('view');
        expect(element.shadowRoot.querySelector('lightning-datatable').data).toEqual([ORDERS]);
        expect(button(element, 'New endpoint')).toBeDefined();
        await expect(element).toBeAccessible();
    });

    it('offers New endpoint only to those who may create one, and says when there are none', async () => {
        const { element } = await render({ ...ACME, endpoints: [] }, false);
        expect(button(element, 'New endpoint')).toBeUndefined();
        expect(element.shadowRoot.textContent).toContain('No endpoints yet.');
    });

    it('opens an endpoint in its record form, and comes back to the provider', async () => {
        const { element, events } = await render();

        element.shadowRoot.querySelector('lightning-datatable').dispatchEvent(new CustomEvent('rowaction', { detail: { action: { name: 'open' }, row: ORDERS } }));
        await flushPromises();
        expect(heading(element).textContent).toBe('Acme: Orders');
        expect(element.shadowRoot.activeElement).toBe(heading(element));
        expect(element.shadowRoot.querySelector('lightning-record-form').recordId).toBe(ORDERS.id);

        button(element, 'Back to Acme').click();
        await flushPromises();
        expect(heading(element).textContent).toBe('Acme');
        expect(events).toEqual([]);

        button(element, 'Back to providers').click();
        expect(events).toEqual(['back']);
    });

    it('says a saved provider or endpoint changed, so the list is read again', async () => {
        const { element, events } = await render();
        element.shadowRoot.querySelector('lightning-record-form').dispatchEvent(new CustomEvent('success', { detail: { id: ACME.id } }));
        expect(events).toEqual(['changed']);
    });

    it('creates an endpoint for this provider, then shows it', async () => {
        const { element, events } = await render();
        button(element, 'New endpoint').click();
        await flushPromises();

        expect(heading(element).textContent).toBe('New endpoint for Acme');
        const providerField = [...element.shadowRoot.querySelectorAll('lightning-input-field')].find((field) => field.value === ACME.id);
        expect(providerField.disabled).toBe(true);
        element.shadowRoot.querySelector('lightning-record-edit-form').dispatchEvent(new CustomEvent('success', { detail: { id: ORDERS.id } }));
        await flushPromises();

        expect(events).toEqual(['changed']);
        expect(heading(element).textContent).toBe('Acme: Orders');
    });

    it('always sends this provider with a new endpoint, though its field is shown disabled', async () => {
        const { element } = await render();
        button(element, 'New endpoint').click();
        await flushPromises();
        const form = element.shadowRoot.querySelector('lightning-record-edit-form');
        form.submit = jest.fn();
        const submitted = new CustomEvent('submit', { cancelable: true, detail: { fields: { Name: 'Refunds', Method__c: 'POST' } } });

        form.dispatchEvent(submitted);

        expect(submitted.defaultPrevented).toBe(true);
        expect(form.submit).toHaveBeenCalledWith(expect.objectContaining({ Name: 'Refunds', Method__c: 'POST', Provider__c: ACME.id }));
    });

    it('shows a just-created endpoint before the list read again has it', async () => {
        const { element } = await render();
        button(element, 'New endpoint').click();
        await flushPromises();

        element.shadowRoot.querySelector('lightning-record-edit-form').dispatchEvent(new CustomEvent('success', { detail: { id: 'a01000000000009AAA' } }));
        await flushPromises();

        expect(heading(element).textContent).toBe('Acme: new endpoint');
        expect(element.shadowRoot.querySelector('lightning-record-form').recordId).toBe('a01000000000009AAA');
        expect(element.shadowRoot.querySelector('lightning-datatable')).toBeNull();
    });

    it('cancels a new endpoint back to the provider', async () => {
        const { element } = await render();
        button(element, 'New endpoint').click();
        await flushPromises();

        button(element, 'Cancel').click();
        await flushPromises();

        expect(element.shadowRoot.querySelector('lightning-record-edit-form')).toBeNull();
        expect(heading(element).textContent).toBe('Acme');
    });
});
