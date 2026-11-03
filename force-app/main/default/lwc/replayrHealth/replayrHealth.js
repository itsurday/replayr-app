import { LightningElement } from 'lwc';
import read from '@salesforce/apex/ConsoleHealth.read';

const NEVER = 'Never';

// The console's health panel: whether Replayr's background work is set up and moving (ConsoleHealth).
// Read on demand, never cached, since it reports live state
export default class ReplayrHealth extends LightningElement {
    health;
    error;
    loading = false;
    // Announced to screen readers; an error is announced by its own alert instead
    status = '';

    connectedCallback() {
        this.refresh();
    }

    // The button stays enabled, so keyboard focus stays on it; a click during a read is ignored
    async refresh() {
        if (this.loading) {
            return;
        }
        this.loading = true;
        this.error = undefined;
        this.status = 'Reading health';
        try {
            this.health = await read();
            this.status = 'Health updated';
        } catch (e) {
            this.health = undefined;
            this.error = e?.body?.message ?? "Replayr couldn't read its health.";
            this.status = '';
        } finally {
            this.loading = false;
        }
    }

    get hasWarnings() {
        return this.health?.warnings?.length > 0;
    }

    // Warnings are shown as text only: they contain user names
    get warnings() {
        return (this.health?.warnings ?? []).map((text, index) => ({ key: `warning-${index}`, text }));
    }

    // The figures in three short tables, so the ones a person acts on stand apart from the housekeeping
    get groups() {
        const health = this.health;
        return [
            {
                title: 'Background work',
                rows: [
                    textRow('Poller schedule', scheduleText(health)),
                    dateRow('Poller last finished a run', health.pollerLastRun),
                    textRow('Event trigger runs as', health.handOffUser ?? 'Not run yet'),
                    dateRow('Event trigger last ran', health.handOffLastRun)
                ]
            },
            {
                title: 'Jobs',
                rows: [
                    health.oldestQueued ? dateRow('Oldest queued job waiting since', health.oldestQueued) : textRow('Oldest queued job', 'None waiting'),
                    countRow('Outcome unknown', health.outcomeUnknown),
                    countRow('Retries used up', health.retriesUsedUp)
                ]
            },
            {
                title: 'Housekeeping',
                rows: [dateRow('Alerts last checked', health.lastAlertCheck), dateRow('Purge last started', health.lastPurge)]
            }
        ];
    }
}

function scheduleText(health) {
    if (health.pollerScheduled === true) {
        return `Scheduled, runs as ${health.pollerOwner}`;
    }
    if (health.pollerScheduled === false) {
        return health.pollerOwner ? `Not running, scheduled by ${health.pollerOwner}` : 'Not scheduled';
    }
    return 'Not visible to you (needs View Setup and Configuration)';
}

function textRow(label, text) {
    return { label, key: label, text };
}

// Jobs that need a person get a warning icon, named for screen readers, so the state isn't shown by colour alone
function countRow(label, count) {
    return { ...textRow(label, String(count)), attention: count > 0 };
}

function dateRow(label, date) {
    return date ? { label, key: label, date } : textRow(label, NEVER);
}
