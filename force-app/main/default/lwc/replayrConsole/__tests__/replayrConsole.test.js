import { createElement } from 'lwc';
import ReplayrConsole from 'c/replayrConsole';

const mockHealth = {
    pollerLastRun: null,
    pollerScheduled: null,
    pollerOwner: null,
    handOffUser: null,
    handOffLastRun: null,
    oldestQueued: null,
    outcomeUnknown: 0,
    retriesUsedUp: 0,
    lastAlertCheck: null,
    lastPurge: null,
    warnings: []
};

jest.mock('@salesforce/apex/ConsoleHealth.read', () => ({ default: jest.fn(() => Promise.resolve(mockHealth)) }), { virtual: true });
jest.mock('@salesforce/apex/ConsoleJobs.listJobs', () => ({ default: jest.fn(() => Promise.resolve({ rows: [], hasMore: false })) }), { virtual: true });
jest.mock(
    '@salesforce/apex/ConsoleSetup.providers',
    () => ({ default: jest.fn(() => Promise.resolve({ providers: [], cut: false, canCreateProviders: false, canCreateEndpoints: false })) }),
    { virtual: true }
);

// Lets the mocked Apex call settle and the component re-render: ten turns, far more than the few it takes, so a
// new await in the component doesn't break the tests (timers and process aren't allowed in component code)
const flushPromises = () => Array.from({ length: 10 }).reduce((chain) => chain.then(() => undefined), Promise.resolve());

async function render() {
    const element = createElement('c-replayr-console', { is: ReplayrConsole });
    document.body.appendChild(element);
    await flushPromises();
    return element;
}

function select(element, name) {
    element.shadowRoot.querySelector('lightning-vertical-navigation').dispatchEvent(new CustomEvent('select', { detail: { name } }));
    return flushPromises();
}

describe('c-replayr-console', () => {
    afterEach(() => {
        while (document.body.firstChild) {
            document.body.removeChild(document.body.firstChild);
        }
    });

    it('opens on the Health section, in a labelled navigation', async () => {
        const element = await render();

        expect(element.shadowRoot.querySelector('nav').getAttribute('aria-label')).toBe('Replayr console sections');
        expect(element.shadowRoot.querySelector('lightning-vertical-navigation').selectedItem).toBe('health');
        expect(element.shadowRoot.querySelector('c-replayr-health')).not.toBeNull();
        await expect(element).toBeAccessible();
    });

    it('keeps Health shown when it is chosen, and shows no section it does not know', async () => {
        const element = await render();

        await select(element, 'health');
        expect(element.shadowRoot.querySelector('c-replayr-health')).not.toBeNull();

        await select(element, 'unknown');
        expect(element.shadowRoot.querySelector('c-replayr-health')).toBeNull();
    });

    it('shows the Jobs section when Jobs is chosen', async () => {
        const element = await render();

        await select(element, 'jobs');

        expect(element.shadowRoot.querySelector('c-replayr-jobs')).not.toBeNull();
        expect(element.shadowRoot.querySelector('c-replayr-health')).toBeNull();
        await expect(element).toBeAccessible();
    });

    it('shows Providers and endpoints when chosen', async () => {
        const element = await render();

        await select(element, 'setup');

        expect(element.shadowRoot.querySelector('c-replayr-setup')).not.toBeNull();
        expect(element.shadowRoot.querySelector('c-replayr-jobs')).toBeNull();
    });
});
