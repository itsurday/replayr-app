import { LightningElement, api } from 'lwc';
import mappings from '@salesforce/apex/ConsoleMappings.mappings';
import saveRequest from '@salesforce/apex/ConsoleMappings.saveRequest';

// Braces can't be written in a template, so the hint lives here
const TEMPLATE_HINT =
    'The body Replayr sends, as JSON. Put a record\'s field in with {{FieldName}} (or {{Account.Name}} for a related record): inside quotes it is sent as text, without quotes as a JSON value.';

// An endpoint's mappings in the console: the Request template and the Response rules, and editing the Request
// mapping. The server checks a template as a job would before saving it
export default class ReplayrMappings extends LightningElement {
    templateHint = TEMPLATE_HINT;
    loaded;
    error;
    loading = false;
    // The Request mapping being edited: { id, targetObject, template }, or undefined
    editing;
    // The Response mapping editor is open (replayrResponseEditor)
    editingResponse = false;
    // Which button gets focus back when an editor closes
    focusButton;
    saveError;
    saving = false;
    status = '';
    focusEditorPending = false;
    focusButtonPending = false;
    _endpointId;

    @api
    get endpointId() {
        return this._endpointId;
    }
    // Another endpoint: nothing of the previous one stays, neither its mappings nor an open editor
    set endpointId(value) {
        this._endpointId = value;
        this.loaded = undefined;
        this.editing = undefined;
        this.editingResponse = false;
        this.saveError = undefined;
        this.status = '';
        this.load();
    }

    renderedCallback() {
        if (this.focusEditorPending && this.refs?.editorHeading) {
            this.focusEditorPending = false;
            this.refs.editorHeading.focus();
        }
        const button = this.focusButtonPending ? this.refs?.[this.focusButton ?? 'requestButton'] : undefined;
        if (button) {
            this.focusButtonPending = false;
            button.focus();
        }
    }

    // Only the answer for the endpoint still shown counts: a slow one for an earlier endpoint is dropped
    async load() {
        const wanted = this._endpointId;
        if (!wanted) {
            return;
        }
        this.loading = true;
        this.error = undefined;
        try {
            const answer = await mappings({ endpointId: wanted });
            if (wanted === this._endpointId) {
                this.loaded = answer;
            }
        } catch (e) {
            if (wanted === this._endpointId) {
                // Nothing out of date is shown as current
                this.loaded = undefined;
                this.error = e?.body?.message ?? "Replayr couldn't read mappings.";
            }
        } finally {
            if (wanted === this._endpointId) {
                this.loading = false;
            }
        }
    }

    get request() {
        return this.loaded?.rows.find((row) => row.direction === 'Request');
    }

    get response() {
        return this.loaded?.rows.find((row) => row.direction === 'Response');
    }

    // What test mode builds the body from: the Request mapping's object, if there is one
    get requestObject() {
        return this.request?.targetObject;
    }

    get responseSummary() {
        const row = this.response;
        const matching = row.matchField ? `, matching on ${row.matchField}` : '';
        const list = row.listPath ? `, each item of ${row.listPath}` : '';
        return `${row.operation ?? 'No operation'} ${row.targetObject}${matching}${list}`;
    }

    get canEdit() {
        return this.loaded?.canEdit === true;
    }

    get responseButtonLabel() {
        return this.response ? 'Edit Response mapping' : 'New Response mapping';
    }

    handleEditResponse() {
        this.editingResponse = true;
        this.status = '';
    }

    handleResponseCancel() {
        this.editingResponse = false;
        this.focusButton = 'responseButton';
        this.focusButtonPending = true;
    }

    async handleResponseSaved() {
        this.editingResponse = false;
        this.focusButton = 'responseButton';
        this.focusButtonPending = true;
        this.status = 'Response mapping saved.';
        await this.load();
    }

    get requestButtonLabel() {
        return this.request ? 'Edit Request mapping' : 'New Request mapping';
    }

    get editorHeading() {
        return this.editing?.id ? 'Edit the Request mapping' : 'New Request mapping';
    }

    handleEditRequest() {
        const row = this.request;
        this.editing = { id: row?.id, targetObject: row?.targetObject ?? '', template: row?.rules ?? '' };
        this.saveError = undefined;
        this.focusEditorPending = true;
    }

    handleObject(event) {
        this.editing = { ...this.editing, targetObject: event.detail.value };
    }

    handleTemplate(event) {
        this.editing = { ...this.editing, template: event.detail.value };
    }

    // Closing the editor puts focus back on the button that opened it
    handleCancel() {
        this.editing = undefined;
        this.focusButton = 'requestButton';
        this.focusButtonPending = true;
    }

    async handleSave() {
        if (this.saving) {
            return;
        }
        this.saving = true;
        this.saveError = undefined;
        try {
            const { id, targetObject, template } = this.editing;
            await saveRequest({ id, endpointId: this._endpointId, targetObject, template });
            this.editing = undefined;
            this.focusButton = 'requestButton';
            this.focusButtonPending = true;
            this.status = 'Request mapping saved.';
            await this.load();
        } catch (e) {
            this.saveError = e?.body?.message ?? "Replayr couldn't save the mapping.";
        } finally {
            this.saving = false;
        }
    }
}
