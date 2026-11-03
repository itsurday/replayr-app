import { LightningElement } from 'lwc';
import providers from '@salesforce/apex/ConsoleSetup.providers';
import PROVIDER_OBJECT from '@salesforce/schema/Provider__c';
import PROVIDER_NAME from '@salesforce/schema/Provider__c.Name';
import NAMED_CREDENTIAL from '@salesforce/schema/Provider__c.Named_Credential__c';
import PROVIDER_KEY from '@salesforce/schema/Provider__c.Key__c';
import MASKED_NAMES from '@salesforce/schema/Provider__c.Masked_Names__c';

const COLUMNS = [
    // The name opens the provider
    { label: 'Provider', type: 'button', typeAttributes: { label: { fieldName: 'name' }, name: 'open', variant: 'base', title: 'Open this provider' } },
    { label: 'Named Credential', fieldName: 'namedCredential' },
    { label: 'Key', fieldName: 'key' },
    { label: 'Endpoints', fieldName: 'endpointCount', type: 'number', initialWidth: 120 }
];

// The console's Providers and endpoints section: the providers, and one of them in full (replayrProvider).
// Records are edited and created through the standard record forms, which apply field access and validation
export default class ReplayrSetup extends LightningElement {
    columns = COLUMNS;
    providerObject = PROVIDER_OBJECT.objectApiName;
    providerFields = [PROVIDER_NAME, NAMED_CREDENTIAL, PROVIDER_KEY, MASKED_NAMES];
    setup;
    error;
    loading = false;
    openProviderId;
    creating = false;
    focusListPending = false;
    focusNewPending = false;

    connectedCallback() {
        this.load();
    }

    renderedCallback() {
        if (this.focusListPending && this.showList && this.refs?.listHeading) {
            this.focusListPending = false;
            this.refs.listHeading.focus();
        }
        if (this.focusNewPending && this.creating && this.refs?.newHeading) {
            this.focusNewPending = false;
            this.refs.newHeading.focus();
        }
    }

    // A failed read again keeps what was shown (an open provider stays open), with the error above the list
    async load() {
        this.loading = true;
        this.error = undefined;
        try {
            this.setup = await providers();
        } catch (e) {
            this.error = e?.body?.message ?? "Replayr couldn't read providers.";
        } finally {
            this.loading = false;
        }
    }

    get rows() {
        return (this.setup?.providers ?? []).map((provider) => ({ ...provider, endpointCount: provider.endpoints.length }));
    }

    get hasRows() {
        return this.rows.length > 0;
    }

    get isEmpty() {
        return Boolean(this.setup) && this.rows.length === 0;
    }

    get cut() {
        return this.setup?.cut === true;
    }

    get canCreateProviders() {
        return this.setup?.canCreateProviders === true;
    }

    get canCreateEndpoints() {
        return this.setup?.canCreateEndpoints === true;
    }

    get openProvider() {
        return this.setup?.providers.find((provider) => provider.id === this.openProviderId);
    }

    get showList() {
        return !this.creating && !this.openProvider;
    }

    get listClass() {
        return this.showList ? '' : 'slds-hide';
    }

    handleRowAction(event) {
        if (event.detail.action.name === 'open') {
            this.openProviderId = event.detail.row.id;
        }
    }

    handleNew() {
        this.creating = true;
        this.focusNewPending = true;
    }

    // A new provider: open it once the list has it, so its endpoints can be added next. The form stays until then,
    // rather than the list flashing by
    async handleCreated(event) {
        await this.load();
        this.openProviderId = event.detail.id;
        this.creating = false;
        if (!this.openProvider) {
            // Not in the list read again (it failed, or the provider is past the first 200): back to the list
            this.focusListPending = true;
        }
    }

    handleCancelNew() {
        this.creating = false;
        this.focusListPending = true;
    }

    handleBack() {
        this.openProviderId = undefined;
        this.focusListPending = true;
    }

    handleChanged() {
        this.load();
    }
}
