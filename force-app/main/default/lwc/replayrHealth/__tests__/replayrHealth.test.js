import { createElement } from 'lwc';
import ReplayrHealth from 'c/replayrHealth';
import read from '@salesforce/apex/ConsoleHealth.read';

jest.mock('@salesforce/apex/ConsoleHealth.read', () => ({ default: jest.fn() }), { virtual: true });

const HEALTHY = {
    pollerLastRun: '2026-11-02T04:01:00.000Z',
    pollerScheduled: true,
    pollerOwner: 'Replayr Integration',
    handOffUser: 'Replayr Integration',
    handOffLastRun: '2026-11-02T04:23:27.000Z',
    oldestQueued: null,
    outcomeUnknown: 0,
    retriesUsedUp: 0,
    lastAlertCheck: '2026-11-02T04:01:00.000Z',
    lastPurge: null,
    warnings: []
};

// Lets the mocked Apex call settle and the component re-render, however many steps that takes
// Lets the mocked Apex call settle and the component re-render: ten turns, far more than the few it takes, so a
// new await in the component doesn't break the tests (timers and process aren't allowed in component code)
const flushPromises = () => Array.from({ length: 10 }).reduce((chain) => chain.then(() => undefined), Promise.resolve());

async function render(health) {
    if (health instanceof Error) {
        read.mockRejectedValue(health);
    } else {
        read.mockResolvedValue(health);
    }
    const element = createElement('c-replayr-health', { is: ReplayrHealth });
    document.body.appendChild(element);
    await flushPromises();
    return element;
}

// The value given to a date row's lightning-formatted-date-time
function dateShown(element, label) {
    const labels = [...element.shadowRoot.querySelectorAll('th[scope="row"]')].map((th) => th.textContent);
    const cell = element.shadowRoot.querySelectorAll('td')[labels.indexOf(label)];
    return cell?.querySelector('lightning-formatted-date-time')?.value;
}

const statusText = (element) => element.shadowRoot.querySelector('[role="status"]').textContent;

// The figures as label → shown text
function figures(element) {
    const labels = [...element.shadowRoot.querySelectorAll('th[scope="row"]')].map((th) => th.textContent);
    const values = [...element.shadowRoot.querySelectorAll('td')].map((td) => td.textContent);
    return Object.fromEntries(labels.map((label, i) => [label, values[i]]));
}

describe('c-replayr-health', () => {
    afterEach(() => {
        while (document.body.firstChild) {
            document.body.removeChild(document.body.firstChild);
        }
        jest.clearAllMocks();
    });

    it('says all is well when there are no warnings, and shows the figures', async () => {
        const element = await render(HEALTHY);

        expect(element.shadowRoot.querySelector('ul')).toBeNull();
        expect(element.shadowRoot.textContent).toContain('set up and moving');
        const shown = figures(element);
        expect(shown['Poller schedule']).toBe('Scheduled, runs as Replayr Integration');
        expect(shown['Purge last started']).toBe('Never');
        expect(shown['Oldest queued job']).toBe('None waiting');
        expect(shown['Outcome unknown']).toBe('0');
        await expect(element).toBeAccessible();
    });

    it('lists each warning as plain text, never as markup', async () => {
        const warnings = ['The poller runs as <b>Jane</b>, not an active Replayr integration user.', 'Jobs need a person: 2 Outcome unknown, 0 Retries used up.'];
        const element = await render({ ...HEALTHY, pollerScheduled: null, warnings });

        const items = [...element.shadowRoot.querySelectorAll('li')];
        expect(items.map((li) => li.textContent)).toEqual(warnings);
        expect(element.shadowRoot.querySelector('li b')).toBeNull();
        expect(figures(element)['Poller schedule']).toContain('Not visible to you');
        await expect(element).toBeAccessible();
    });

    it('describes a poller that is not scheduled, or scheduled but not running', async () => {
        let element = await render({ ...HEALTHY, pollerScheduled: false, pollerOwner: null });
        expect(figures(element)['Poller schedule']).toBe('Not scheduled');
        document.body.removeChild(element);

        element = await render({ ...HEALTHY, pollerScheduled: false, pollerOwner: 'Jane Admin' });
        expect(figures(element)['Poller schedule']).toBe('Not running, scheduled by Jane Admin');
    });

    it("shows the server's message when health can't be read", async () => {
        const failure = new Error('failed');
        failure.body = { message: 'You need the Replayr Admin or Replayr Operator permission set.' };
        const element = await render(failure);

        const alert = element.shadowRoot.querySelector('[role="alert"]');
        expect(alert.textContent).toBe('You need the Replayr Admin or Replayr Operator permission set.');
        expect(element.shadowRoot.querySelector('table')).toBeNull();
        await expect(element).toBeAccessible();
    });

    it('shows the dates it has, and what has not happened yet', async () => {
        const element = await render({ ...HEALTHY, oldestQueued: '2026-11-02T01:00:00.000Z', handOffUser: null, handOffLastRun: null });

        expect(dateShown(element, 'Poller last finished a run')).toBe(HEALTHY.pollerLastRun);
        expect(dateShown(element, 'Oldest queued job waiting since')).toBe('2026-11-02T01:00:00.000Z');
        const shown = figures(element);
        expect(shown['Event trigger runs as']).toBe('Not run yet');
        expect(shown['Event trigger last ran']).toBe('Never');
    });

    it('shows it is reading, keeps Refresh usable and ignores a second click meanwhile', async () => {
        // A read that answers only when the test says so
        let answer;
        read.mockReturnValue(new Promise((resolve) => (answer = resolve)));
        const element = createElement('c-replayr-health', { is: ReplayrHealth });
        document.body.appendChild(element);
        await Promise.resolve();

        expect(element.shadowRoot.querySelector('lightning-spinner')).not.toBeNull();
        expect(statusText(element)).toBe('Reading health');
        const button = element.shadowRoot.querySelector('lightning-button');
        expect(button.disabled).toBeFalsy();
        button.click();

        answer(HEALTHY);
        await flushPromises();
        expect(read).toHaveBeenCalledTimes(1);
        expect(element.shadowRoot.querySelector('lightning-spinner')).toBeNull();
        expect(statusText(element)).toBe('Health updated');
    });

    it('recovers on Refresh after a failure', async () => {
        const failure = new Error('failed');
        failure.body = { message: 'Replayr couldn\'t read its health (QueryException).' };
        const element = await render(failure);
        read.mockResolvedValue(HEALTHY);

        element.shadowRoot.querySelector('lightning-button').click();
        await flushPromises();

        expect(element.shadowRoot.querySelector('[role="alert"]')).toBeNull();
        expect(element.shadowRoot.querySelector('table')).not.toBeNull();
    });

    it('falls back to its own message when the failure carries none (a lost connection)', async () => {
        const element = await render(new Error('Network error'));

        expect(element.shadowRoot.querySelector('[role="alert"]').textContent).toBe("Replayr couldn't read its health.");
        expect(statusText(element)).toBe('');
    });

    it('reads again on Refresh', async () => {
        const element = await render(HEALTHY);
        read.mockResolvedValue({ ...HEALTHY, outcomeUnknown: 3, warnings: ['Jobs need a person: 3 Outcome unknown, 0 Retries used up.'] });

        element.shadowRoot.querySelector('lightning-button').click();
        await flushPromises();

        expect(read).toHaveBeenCalledTimes(2);
        expect(figures(element)['Outcome unknown']).toBe('3');
        expect(element.shadowRoot.querySelectorAll('li')).toHaveLength(1);
    });

    it('groups the figures and marks counts that need a person with a named icon', async () => {
        const element = await render({ ...HEALTHY, outcomeUnknown: 2, warnings: ['Jobs need a person: 2 Outcome unknown, 0 Retries used up.'] });

        const titles = [...element.shadowRoot.querySelectorAll('h3.slds-text-title_bold')].map((h3) => h3.textContent);
        expect(titles).toEqual(['Background work', 'Jobs', 'Housekeeping']);
        const marked = [...element.shadowRoot.querySelectorAll('td lightning-icon')].map((icon) => icon.closest('tr').querySelector('th').textContent);
        expect(marked).toEqual(['Outcome unknown']);
        expect(element.shadowRoot.querySelector('td lightning-icon').alternativeText).toBe('Needs attention');
        expect(element.shadowRoot.querySelector('.slds-theme_warning')).not.toBeNull();
        await expect(element).toBeAccessible();
    });
});
