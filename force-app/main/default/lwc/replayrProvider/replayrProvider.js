import { LightningElement, api } from 'lwc';
import checkProvider from '@salesforce/apex/ConsoleProviderCheck.check';
import PROVIDER_OBJECT from '@salesforce/schema/Provider__c';
import PROVIDER_NAME from '@salesforce/schema/Provider__c.Name';
import NAMED_CREDENTIAL from '@salesforce/schema/Provider__c.Named_Credential__c';
import PROVIDER_KEY from '@salesforce/schema/Provider__c.Key__c';
import MASKED_NAMES from '@salesforce/schema/Provider__c.Masked_Names__c';
import ENDPOINT_OBJECT from '@salesforce/schema/Endpoint__c';
import ENDPOINT_NAME from '@salesforce/schema/Endpoint__c.Name';
import ENDPOINT_PROVIDER from '@salesforce/schema/Endpoint__c.Provider__c';
import METHOD from '@salesforce/schema/Endpoint__c.Method__c';
import PATH from '@salesforce/schema/Endpoint__c.Path__c';
import ENDPOINT_KEY from '@salesforce/schema/Endpoint__c.Key__c';
import RETRY_SAFE from '@salesforce/schema/Endpoint__c.Retry_Safe__c';
import SIDE_EFFECT_FREE from '@salesforce/schema/Endpoint__c.Side_Effect_Free__c';
import MAX_ATTEMPTS from '@salesforce/schema/Endpoint__c.Max_Attempts__c';
import IDEMPOTENCY_HEADER from '@salesforce/schema/Endpoint__c.Idempotency_Header__c';
import ALLOW_SENDING from '@salesforce/schema/Endpoint__c.Allow_Sending__c';

const ENDPOINT_COLUMNS = [
    // The name opens the endpoint
    { label: 'Endpoint', type: 'button', typeAttributes: { label: { fieldName: 'name' }, name: 'open', variant: 'base', title: 'Open this endpoint' } },
    { label: 'Method', fieldName: 'method', initialWidth: 100 },
    { label: 'Path', fieldName: 'path' },
    { label: 'Key', fieldName: 'key' },
    { label: 'Retry-safe', fieldName: 'retrySafe', type: 'boolean', initialWidth: 110 },
    { label: 'Open to flows', fieldName: 'allowSending', type: 'boolean', initialWidth: 130 }
];
// How each finding of the check is shown: an icon and, for screen readers, its meaning in words
const FINDING_LOOK = {
    passed: { icon: 'utility:success', label: 'Passed' },
    failed: { icon: 'utility:error', label: 'Problem' },
    notChecked: { icon: 'utility:info', label: 'Not checked' }
};
// Everything an admin sets on an endpoint; the provider is fixed, so not shown in the form
const ENDPOINT_FIELDS = [ENDPOINT_NAME, METHOD, PATH, ENDPOINT_KEY, RETRY_SAFE, SIDE_EFFECT_FREE, MAX_ATTEMPTS, IDEMPOTENCY_HEADER, ALLOW_SENDING];

// One provider in the console: its record and its endpoints, each viewed, edited or created through the standard
// record forms. Sends "changed" after a save, so the list is read again, and "back" to return to it
export default class ReplayrProvider extends LightningElement {
    @api provider;
    @api canCreateEndpoints = false;
    providerObject = PROVIDER_OBJECT.objectApiName;
    providerFields = [PROVIDER_NAME, NAMED_CREDENTIAL, PROVIDER_KEY, MASKED_NAMES];
    endpointObject = ENDPOINT_OBJECT.objectApiName;
    endpointFields = ENDPOINT_FIELDS;
    endpointColumns = ENDPOINT_COLUMNS;
    providerField = ENDPOINT_PROVIDER.fieldApiName;
    openEndpointId;
    creatingEndpoint = false;
    // The last "check this provider" result (ConsoleProviderCheck)
    check;
    checkError;
    checking = false;
    checkStatus = '';
    // Focus follows each view change to its heading, so a screen reader announces it
    focusPending = true;

    renderedCallback() {
        const heading = this.refs?.heading;
        if (this.focusPending && heading) {
            this.focusPending = false;
            heading.focus();
        }
    }

    get heading() {
        if (this.creatingEndpoint) {
            return `New endpoint for ${this.provider.name}`;
        }
        if (this.openEndpointId) {
            // A new endpoint is open before the list read again has its name
            return `${this.provider.name}: ${this.openEndpoint?.name ?? 'new endpoint'}`;
        }
        return this.provider.name;
    }

    get openEndpoint() {
        return this.provider?.endpoints.find((endpoint) => endpoint.id === this.openEndpointId);
    }

    get showProvider() {
        return !this.creatingEndpoint && !this.openEndpointId;
    }

    get hasEndpoints() {
        return this.provider?.endpoints.length > 0;
    }

    get backLabel() {
        return this.showProvider ? 'Back to providers' : `Back to ${this.provider.name}`;
    }

    handleBack() {
        if (this.showProvider) {
            this.dispatchEvent(new CustomEvent('back'));
            return;
        }
        this.openEndpointId = undefined;
        this.creatingEndpoint = false;
        this.focusPending = true;
    }

    handleRowAction(event) {
        if (event.detail.action.name === 'open') {
            this.openEndpointId = event.detail.row.id;
            this.focusPending = true;
        }
    }

    handleNewEndpoint() {
        this.creatingEndpoint = true;
        this.focusPending = true;
    }

    get findings() {
        return (this.check?.findings ?? []).map((finding, index) => ({ ...finding, key: `finding-${index}`, ...FINDING_LOOK[finding.state] }));
    }

    async handleCheck() {
        if (this.checking) {
            return;
        }
        this.checking = true;
        this.checkError = undefined;
        this.checkStatus = 'Checking the provider';
        try {
            this.check = await checkProvider({ providerId: this.provider.id });
            const problems = this.check.findings.filter((finding) => finding.state === 'failed').length;
            this.checkStatus = this.check.checked
                ? `Check done: ${problems === 0 ? 'no problems' : `${problems} ${problems === 1 ? 'problem' : 'problems'}`}.`
                : this.check.message;
        } catch (e) {
            this.check = undefined;
            this.checkError = e?.body?.message ?? "Replayr couldn't check this provider.";
            this.checkStatus = '';
        } finally {
            this.checking = false;
        }
    }

    // A saved change (the Named Credential, say) makes an earlier check out of date
    handleSaved() {
        this.check = undefined;
        this.checkStatus = '';
        this.dispatchEvent(new CustomEvent('changed'));
    }

    // Always this provider: the form's own provider field is shown disabled, and a disabled field may not be sent
    handleEndpointSubmit(event) {
        event.preventDefault();
        this.refs.endpointForm.submit({ ...event.detail.fields, [this.providerField]: this.provider.id });
    }

    // A new endpoint: show it, and have the list read again so it appears under its provider
    handleEndpointCreated(event) {
        this.creatingEndpoint = false;
        this.openEndpointId = event.detail.id;
        this.focusPending = true;
        this.dispatchEvent(new CustomEvent('changed'));
    }
}
