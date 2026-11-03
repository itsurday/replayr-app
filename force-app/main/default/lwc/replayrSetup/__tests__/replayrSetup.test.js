import { createElement } from 'lwc';
import ReplayrSetup from 'c/replayrSetup';
import providers from '@salesforce/apex/ConsoleSetup.providers';

jest.mock('@salesforce/apex/ConsoleSetup.providers', () => ({ default: jest.fn() }), { virtual: true });

const ACME = {
    id: 'a00000000000001AAA',
    name: 'Acme',
    key: 'acme',
    namedCredential: 'Acme_API',
    endpoints: [{ id: 'a01000000000001AAA', name: 'Orders', key: 'acme-orders', method: 'POST', path: '/orders', retrySafe: false, allowSending: true }]
};

function setup(overrides = {}) {
    return { providers: [ACME], cut: false, canCreateProviders: true, canCreateEndpoints: true, ...overrides };
}

const flushPromises = () => Array.from({ length: 10 }).reduce((chain) => chain.then(() => undefined), Promise.resolve());

async function render(answer) {
    if (answer instanceof Error) {
        providers.mockRejectedValue(answer);
    } else {
        providers.mockResolvedValue(answer);
    }
    const element = createElement('c-replayr-setup', { is: ReplayrSetup });
    document.body.appendChild(element);
    await flushPromises();
    return element;
}

const button = (element, label) => [...element.shadowRoot.querySelectorAll('lightning-button')].find((b) => b.label === label);
const listCard = (element) => [...element.shadowRoot.querySelectorAll('lightning-card')].pop();

describe('c-replayr-setup', () => {
    afterEach(() => {
        while (document.body.firstChild) {
            document.body.removeChild(document.body.firstChild);
        }
        jest.clearAllMocks();
    });

    it('lists the providers with how many endpoints each has', async () => {
        const element = await render(setup());

        const table = element.shadowRoot.querySelector('lightning-datatable');
        expect(table.data).toEqual([expect.objectContaining({ name: 'Acme', namedCredential: 'Acme_API', endpointCount: 1 })]);
        expect(button(element, 'New provider')).toBeDefined();
        await expect(element).toBeAccessible();
    });

    it('offers New provider only to those who may create one, and says when there are none or too many', async () => {
        let element = await render(setup({ providers: [], canCreateProviders: false }));
        expect(button(element, 'New provider')).toBeUndefined();
        expect(element.shadowRoot.textContent).toContain('No providers yet.');
        document.body.removeChild(element);

        element = await render(setup({ cut: true }));
        expect(element.shadowRoot.textContent).toContain('Only the first 200 providers are listed.');
    });

    it("shows the server's message when providers can't be read", async () => {
        const failure = new Error('failed');
        failure.body = { message: 'You need the Replayr Admin or Replayr Operator permission set.' };
        const element = await render(failure);

        expect(element.shadowRoot.querySelector('[role="alert"]').textContent).toBe('You need the Replayr Admin or Replayr Operator permission set.');
        expect(button(element, 'New provider')).toBeUndefined();
    });

    it('opens a provider in place of the list, and comes back to the list with focus on its title', async () => {
        const element = await render(setup());

        element.shadowRoot.querySelector('lightning-datatable').dispatchEvent(new CustomEvent('rowaction', { detail: { action: { name: 'open' }, row: ACME } }));
        await flushPromises();
        const opened = element.shadowRoot.querySelector('c-replayr-provider');
        expect(opened.provider).toEqual(ACME);
        expect(opened.canCreateEndpoints).toBe(true);
        expect(listCard(element).className).toContain('slds-hide');

        opened.dispatchEvent(new CustomEvent('back'));
        await flushPromises();
        expect(element.shadowRoot.querySelector('c-replayr-provider')).toBeNull();
        expect(listCard(element).className).not.toContain('slds-hide');
        expect(element.shadowRoot.activeElement).toBe(element.shadowRoot.querySelector('[slot="title"]'));
    });

    it('reads the list again after a provider is saved', async () => {
        const element = await render(setup());
        element.shadowRoot.querySelector('lightning-datatable').dispatchEvent(new CustomEvent('rowaction', { detail: { action: { name: 'open' }, row: ACME } }));
        await flushPromises();

        element.shadowRoot.querySelector('c-replayr-provider').dispatchEvent(new CustomEvent('changed'));
        await flushPromises();

        expect(providers).toHaveBeenCalledTimes(2);
        expect(element.shadowRoot.querySelector('c-replayr-provider')).not.toBeNull();
    });

    it('creates a provider through the record form and then opens it', async () => {
        const element = await render(setup());
        button(element, 'New provider').click();
        await flushPromises();
        const form = element.shadowRoot.querySelector('lightning-record-form');
        expect(form.mode).toBe('edit');
        expect(form.recordId).toBeUndefined();
        const created = { ...ACME, id: 'a00000000000002AAA', name: 'Billing', endpoints: [] };
        providers.mockResolvedValue(setup({ providers: [ACME, created] }));

        form.dispatchEvent(new CustomEvent('success', { detail: { id: created.id } }));
        await flushPromises();

        expect(element.shadowRoot.querySelector('c-replayr-provider').provider).toEqual(created);
    });

    it('moves focus to the new provider form', async () => {
        const element = await render(setup());
        button(element, 'New provider').click();
        await flushPromises();

        const title = element.shadowRoot.querySelector('[slot="title"]');
        expect(title.textContent).toBe('New provider');
        expect(element.shadowRoot.activeElement).toBe(title);
        await expect(element).toBeAccessible();
    });

    it('keeps an open provider open when reading the list again fails', async () => {
        const element = await render(setup());
        element.shadowRoot.querySelector('lightning-datatable').dispatchEvent(new CustomEvent('rowaction', { detail: { action: { name: 'open' }, row: ACME } }));
        await flushPromises();
        providers.mockRejectedValue(new Error('Network error'));

        element.shadowRoot.querySelector('c-replayr-provider').dispatchEvent(new CustomEvent('changed'));
        await flushPromises();

        expect(element.shadowRoot.querySelector('c-replayr-provider')).not.toBeNull();
        expect(element.shadowRoot.querySelector('[role="alert"]').textContent).toBe("Replayr couldn't read providers.");
    });

    it('goes back to the list when a new provider is cancelled', async () => {
        const element = await render(setup());
        button(element, 'New provider').click();
        await flushPromises();

        element.shadowRoot.querySelector('lightning-record-form').dispatchEvent(new CustomEvent('cancel'));
        await flushPromises();

        expect(element.shadowRoot.querySelector('lightning-record-form')).toBeNull();
        expect(listCard(element).className).not.toContain('slds-hide');
    });
});
