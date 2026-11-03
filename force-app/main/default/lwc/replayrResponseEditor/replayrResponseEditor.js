import { LightningElement, api } from 'lwc';
import saveResponse from '@salesforce/apex/ConsoleMappings.saveResponse';
import propose from '@salesforce/apex/ConsoleMappings.propose';

const OPERATIONS = [
    { label: 'Insert: a new record for each item', value: 'Insert' },
    { label: 'Update: an existing record', value: 'Update' },
    { label: 'Upsert: update if found, otherwise insert', value: 'Upsert' }
];

let nextKey = 0;
const newRow = (field = '', path = '') => ({ key: `rule-${nextKey++}`, field, path });

// The rows of {"fields": {"Field__c": "json.path"}}, as stored on a Response mapping
function rowsOf(rulesJson) {
    let rules;
    try {
        rules = JSON.parse(rulesJson ?? '{}');
    } catch (notJson) {
        // Rules saved by hand that aren't JSON: start from an empty table rather than lose the editor. The error is
        // kept, not dropped: a bare catch {} makes Code Analyzer's PMD fail on the file, and an unused one fails lint
        rules = { fields: {}, notJson };
    }
    return Object.entries(rules?.fields ?? {}).map(([field, path]) => newRow(field, String(path)));
}

// Edits an endpoint's Response mapping: object, Operation, Match Field, List Path and the rules as a table, which
// can be proposed from a sample reply (ConsoleMappings.propose). The server checks it as the worker would before
// saving. Sends "saved" or "cancel"
export default class ReplayrResponseEditor extends LightningElement {
    @api endpointId;
    operations = OPERATIONS;
    targetObject = '';
    operation;
    matchField = '';
    listPath = '';
    rows = [newRow()];
    mappingId;
    sample = '';
    candidates = [];
    unmatched = [];
    proposing = false;
    saving = false;
    error;
    status = '';
    // Focus goes to the editor's heading when it opens
    focusPending = true;
    // After adding or removing a rule: the row whose Field gets focus, or 'add' for the Add a rule button
    focusRowKey;
    _mapping;

    /** The mapping being edited (a ConsoleMappings.MappingRow), or undefined for a new one. */
    @api
    get mapping() {
        return this._mapping;
    }
    set mapping(value) {
        this._mapping = value;
        this.mappingId = value?.id;
        this.targetObject = value?.targetObject ?? '';
        this.operation = value?.operation;
        this.matchField = value?.matchField ?? '';
        this.listPath = value?.listPath ?? '';
        const rows = rowsOf(value?.rules);
        this.rows = rows.length ? rows : [newRow()];
    }

    renderedCallback() {
        if (this.focusPending && this.refs?.heading) {
            this.focusPending = false;
            this.refs.heading.focus();
        }
        if (this.focusRowKey) {
            const target =
                this.focusRowKey === 'add'
                    ? this.refs?.addRule
                    : this.template.querySelector(`lightning-input[data-key="${this.focusRowKey}"][data-part="field"]`);
            this.focusRowKey = undefined;
            target?.focus();
        }
    }

    get cantSave() {
        return this.saving || this.proposing;
    }

    get heading() {
        return this.mappingId ? 'Edit the Response mapping' : 'New Response mapping';
    }

    // Each row's inputs named with its number, for screen readers
    get tableRows() {
        return this.rows.map((row, index) => ({ ...row, fieldLabel: `Field ${index + 1}`, pathLabel: `JSON path ${index + 1}`, removeLabel: `Remove rule ${index + 1}` }));
    }

    get hasCandidates() {
        return this.candidates.length > 0;
    }

    get candidateOptions() {
        return this.candidates.map((path) => ({ label: path || 'The whole reply', value: path }));
    }

    get unmatchedText() {
        return this.unmatched.length ? `Not matched to a field: ${this.unmatched.join(', ')}.` : '';
    }

    handleObject(event) {
        this.targetObject = event.detail.value;
    }

    handleOperation(event) {
        this.operation = event.detail.value;
    }

    handleMatchField(event) {
        this.matchField = event.detail.value;
    }

    handleListPath(event) {
        this.listPath = event.detail.value;
    }

    handleRowChange(event) {
        const { key, part } = event.target.dataset;
        this.rows = this.rows.map((row) => (row.key === key ? { ...row, [part]: event.detail.value } : row));
    }

    // Focus goes to the new row, so it's clear one was added
    handleAddRow() {
        const row = newRow();
        this.rows = [...this.rows, row];
        this.focusRowKey = row.key;
    }

    // Focus goes to the row that took its place, or the one before, rather than being lost with the button
    handleRemoveRow(event) {
        const key = event.target.dataset.key;
        const index = this.rows.findIndex((row) => row.key === key);
        const rest = this.rows.filter((row) => row.key !== key);
        this.rows = rest.length ? rest : [newRow()];
        this.focusRowKey = rest.length ? this.rows[Math.min(index, this.rows.length - 1)].key : 'add';
    }

    handleSample(event) {
        this.sample = event.detail.value;
    }

    handleCandidate(event) {
        this.proposeRules(event.detail.value);
    }

    // A List Path the admin typed is used; otherwise the proposal finds one
    handlePropose() {
        this.proposeRules(this.listPath?.trim() ? this.listPath.trim() : null);
    }

    // Fills the table from the sample; when several lists were found, offers them to choose from
    async proposeRules(listPath) {
        if (this.proposing) {
            return;
        }
        this.proposing = true;
        this.error = undefined;
        try {
            const proposal = await propose({ sampleJson: this.sample, targetObject: this.targetObject, listPath });
            this.candidates = proposal.rules.length === 0 ? proposal.listPathCandidates ?? [] : [];
            this.unmatched = proposal.unmatched ?? [];
            if (!this.hasCandidates && proposal.listPath !== null && proposal.listPath !== undefined) {
                this.listPath = proposal.listPath;
            }
            const added = this.addProposed(proposal.rules);
            this.status = this.hasCandidates
                ? 'Several lists were found: choose the one whose items become records.'
                : `${added} ${added === 1 ? 'rule' : 'rules'} proposed and added. Rules already in the table were kept. Check them, then choose the Operation and Match Field.`;
        } catch (e) {
            this.error = e?.body?.message ?? "Replayr couldn't read the sample.";
            this.status = '';
        } finally {
            this.proposing = false;
        }
    }

    // Proposed rules join the table only for fields not in it yet: rules the admin wrote or changed are kept
    addProposed(proposed) {
        const kept = this.rows.filter((row) => row.field.trim() || row.path.trim());
        const taken = new Set(kept.map((row) => row.field.trim().toLowerCase()));
        const added = proposed.filter((rule) => !taken.has(rule.field.toLowerCase())).map((rule) => newRow(rule.field, rule.path));
        if (added.length) {
            this.rows = [...kept, ...added];
        }
        return added.length;
    }

    handleCancel() {
        this.dispatchEvent(new CustomEvent('cancel'));
    }

    async handleSave() {
        if (this.saving) {
            return;
        }
        this.saving = true;
        this.error = undefined;
        try {
            // Plain values and the rules as JSON: Lightning can't pass a custom Apex class from the browser
            await saveResponse({
                id: this.mappingId,
                endpointId: this.endpointId,
                targetObject: this.targetObject,
                operation: this.operation,
                matchField: this.matchField,
                listPath: this.listPath,
                rulesJson: JSON.stringify(this.rows.map(({ field, path }) => ({ field, path })))
            });
            this.dispatchEvent(new CustomEvent('saved'));
        } catch (e) {
            this.error = e?.body?.message ?? "Replayr couldn't save the mapping.";
        } finally {
            this.saving = false;
        }
    }
}
