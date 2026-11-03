import { createElement } from 'lwc';
import ReplayrSettings from 'c/replayrSettings';
import read from '@salesforce/apex/ConsoleSettings.read';
import saveRetention from '@salesforce/apex/ConsoleSettings.saveRetention';
import startBackgroundWork from '@salesforce/apex/ConsoleSettings.startBackgroundWork';

jest.mock('@salesforce/apex/ConsoleSettings.read', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex/ConsoleSettings.saveRetention', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex/ConsoleSettings.startBackgroundWork', () => ({ default: jest.fn() }), { virtual: true });

const SETTINGS = { retentionDays: 30, minRetentionDays: 1, maxRetentionDays: 3650 };

const flushPromises = () => Array.from({ length: 10 }).reduce((chain) => chain.then(() => undefined), Promise.resolve());

async function render(answer = SETTINGS) {
    if (answer instanceof Error) {
        read.mockRejectedValue(answer);
    } else {
        read.mockResolvedValue(answer);
    }
    const element = createElement('c-replayr-settings', { is: ReplayrSettings });
    document.body.appendChild(element);
    await flushPromises();
    return element;
}

const button = (element, label) => [...element.shadowRoot.querySelectorAll('lightning-button')].find((b) => b.label === label);
// The message beside each button: the first live region is Save's, the second Start's
const statuses = (element) => [...element.shadowRoot.querySelectorAll('[role="status"]')].map((p) => p.textContent);
const alerts = (element) => [...element.shadowRoot.querySelectorAll('[role="alert"]')].map((p) => p.textContent);

describe('c-replayr-settings', () => {
    afterEach(() => {
        while (document.body.firstChild) {
            document.body.removeChild(document.body.firstChild);
        }
        jest.clearAllMocks();
    });

    it('shows the retention, its range and the setup steps', async () => {
        const element = await render();

        const days = element.shadowRoot.querySelector('lightning-input');
        expect(days.value).toBe(30);
        expect(days.max).toBe(3650);
        expect(days.fieldLevelHelp).toContain('From 1 to 3650 days');
        expect(element.shadowRoot.querySelectorAll('ol li')).toHaveLength(6);
        await expect(element).toBeAccessible();
    });

    it('saves the retention and says so', async () => {
        const element = await render();
        element.shadowRoot.querySelector('lightning-input').dispatchEvent(new CustomEvent('change', { detail: { value: '90' } }));
        saveRetention.mockResolvedValue({ ...SETTINGS, retentionDays: 90 });

        button(element, 'Save').click();
        await flushPromises();

        expect(saveRetention).toHaveBeenCalledWith({ days: 90 });
        expect(statuses(element)).toEqual(['Saved: finished jobs are kept for 90 days.', '']);
    });

    it("shows the server's reason when a value is refused", async () => {
        const element = await render();
        const refusal = new Error('refused');
        refusal.body = { message: 'Keep finished jobs for 1 to 3650 days.' };
        saveRetention.mockRejectedValue(refusal);

        button(element, 'Save').click();
        await flushPromises();

        expect(alerts(element)).toEqual(['Keep finished jobs for 1 to 3650 days.']);
    });

    it('refuses a blank or partial number of days before asking the server', async () => {
        const element = await render();
        const days = element.shadowRoot.querySelector('lightning-input');
        days.dispatchEvent(new CustomEvent('change', { detail: { value: '' } }));
        button(element, 'Save').click();
        await flushPromises();
        expect(alerts(element)).toEqual(['Give a whole number of days, from 1 to 3650.']);

        days.dispatchEvent(new CustomEvent('change', { detail: { value: '30.5' } }));
        button(element, 'Save').click();
        await flushPromises();
        expect(alerts(element)).toEqual(['Give a whole number of days, from 1 to 3650.']);
        expect(saveRetention).not.toHaveBeenCalled();
    });

    it('sets background work off, and says when it could not', async () => {
        const element = await render();
        startBackgroundWork.mockResolvedValueOnce(true);
        button(element, 'Start background work').click();
        await flushPromises();
        expect(statuses(element)[1]).toContain('Sent. Check Health');
        expect(statuses(element)[0]).toBe('');

        startBackgroundWork.mockResolvedValueOnce(false);
        button(element, 'Start background work').click();
        await flushPromises();
        expect(alerts(element)).toEqual(["Replayr couldn't send it: your access doesn't include publishing its event."]);
        await expect(element).toBeAccessible();
    });

    it("still shows the setup steps when the settings can't be read", async () => {
        const failure = new Error('failed');
        failure.body = { message: 'Settings need the Replayr Admin permission set (or another that may edit endpoints).' };
        const element = await render(failure);

        expect(element.shadowRoot.querySelector('[role="alert"]').textContent).toContain('Replayr Admin');
        expect(element.shadowRoot.querySelector('lightning-input')).toBeNull();
        expect(element.shadowRoot.querySelectorAll('ol li')).toHaveLength(6);
    });
});
