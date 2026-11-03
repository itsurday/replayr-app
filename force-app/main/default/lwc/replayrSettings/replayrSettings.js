import { LightningElement } from 'lwc';
import read from '@salesforce/apex/ConsoleSettings.read';
import saveRetention from '@salesforce/apex/ConsoleSettings.saveRetention';
import startBackgroundWork from '@salesforce/apex/ConsoleSettings.startBackgroundWork';

// The setup, in order: what to do, and where (the admin guide has the detail)
const STEPS = [
    {
        key: 'credential',
        text: 'Set up a Named Credential for each external system (Setup, Named Credentials), add "replayr" to its Allowed Namespaces for Callouts, and give its API name to a provider here.'
    },
    {
        key: 'user',
        text: 'Choose the integration user (a Salesforce Integration licence will do) and give it the Replayr Integration User set, plus a permission set of your own with principal access to each credential and Read on User External Credentials.'
    },
    { key: 'runas', text: 'Make the event trigger run as that user: deploy the run-as file from the admin guide, then Suspend and Resume the Replayr Work Waiting subscription (Setup, Platform Events).' },
    { key: 'start', text: 'Start background work below, then check Health: the event trigger and the poller should both run as the integration user.' },
    { key: 'check', text: 'Open each provider and use Check this provider.' },
    { key: 'senders', text: 'Give people whose changes send records the Replayr Sender set, and open each endpoint to flows.' }
];

// The console's Settings and setup section (ConsoleSettings): how long finished jobs are kept, setting background
// work off once, and the setup steps
export default class ReplayrSettings extends LightningElement {
    steps = STEPS;
    settings;
    days;
    error;
    saveError;
    saving = false;
    starting = false;
    // Each button's own message, beside it
    saveStatus = '';
    startStatus = '';
    startError;

    async connectedCallback() {
        try {
            this.settings = await read();
            this.days = this.settings.retentionDays;
        } catch (e) {
            this.error = e?.body?.message ?? "Replayr couldn't read its settings.";
        }
    }

    get rangeHelp() {
        return `From ${this.settings.minRetentionDays} to ${this.settings.maxRetentionDays} days. Jobs waiting for a person are never purged.`;
    }

    handleDays(event) {
        this.days = event.detail.value;
    }

    async handleSave() {
        if (this.saving) {
            return;
        }
        // Checked here first: a whole number in the range (blank or 30.5 never reaches the server)
        const input = this.refs.days;
        const days = Number(this.days);
        if (input.reportValidity() === false || String(this.days ?? '').trim() === '' || !Number.isInteger(days)) {
            this.saveError = `Give a whole number of days, from ${this.settings.minRetentionDays} to ${this.settings.maxRetentionDays}.`;
            input.focus();
            return;
        }
        this.saving = true;
        this.saveError = undefined;
        this.saveStatus = '';
        try {
            this.settings = await saveRetention({ days });
            this.days = this.settings.retentionDays;
            this.saveStatus = `Saved: finished jobs are kept for ${this.days} days.`;
        } catch (e) {
            this.saveError = e?.body?.message ?? "Replayr couldn't save the setting.";
        } finally {
            this.saving = false;
        }
    }

    async handleStart() {
        if (this.starting) {
            return;
        }
        this.starting = true;
        this.startError = undefined;
        this.startStatus = '';
        try {
            const published = await startBackgroundWork();
            if (published) {
                // Only the event is certain: whether it ran as the integration user shows in Health
                this.startStatus = 'Sent. Check Health in a minute: the event trigger and the poller should run as the integration user.';
            } else {
                this.startError = "Replayr couldn't send it: your access doesn't include publishing its event.";
            }
        } catch (e) {
            this.startError = e?.body?.message ?? "Replayr couldn't set background work off.";
        } finally {
            this.starting = false;
        }
    }
}
