import { LightningElement } from 'lwc';

// The Replayr console (decisions.md, ADR-021): one app page, its sections inside, added as they are built
export default class ReplayrConsole extends LightningElement {
    section = 'health';

    get showHealth() {
        return this.section === 'health';
    }

    get showJobs() {
        return this.section === 'jobs';
    }

    get showSetup() {
        return this.section === 'setup';
    }

    get showSettings() {
        return this.section === 'settings';
    }

    handleSelect(event) {
        this.section = event.detail.name;
    }
}
