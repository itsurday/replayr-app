import { LightningElement, api } from 'lwc';
import run from '@salesforce/apex/ConsoleTestMode.run';

// Test mode for one endpoint in the console (ConsoleTestMode): Preview builds the request for a record and never
// sends; once a preview shows the endpoint is Side-effect-free, Send a test makes the real call and shows the reply
export default class ReplayrTestMode extends LightningElement {
    @api endpointId;
    recordId;
    _targetObject;

    /** The Request mapping's object, for the record picker; blank when the endpoint has no Request mapping. */
    @api
    get targetObject() {
        return this._targetObject;
    }
    // Another object (the Request mapping was changed): the record and result of the old one go
    set targetObject(value) {
        if (value !== this._targetObject) {
            this.recordId = undefined;
            this.outcome = undefined;
        }
        this._targetObject = value;
    }
    outcome;
    error;
    running = false;
    status = '';

    get needsRecord() {
        return Boolean(this.targetObject);
    }

    get cantRun() {
        return this.running || (this.needsRecord && !this.recordId);
    }

    get canSend() {
        return this.outcome?.sideEffectFree === true;
    }

    get sendNote() {
        return this.outcome && !this.canSend ? "This endpoint isn't Side-effect-free, so test mode only ever previews it." : '';
    }

    get requestLine() {
        return `${this.outcome.method} ${this.outcome.url}`;
    }

    get hasHeaders() {
        return this.outcome?.headers?.length > 0;
    }

    get headerRows() {
        return this.outcome.headers.map((header) => ({ ...header, key: header.name, text: `${header.name}: ${header.value}` }));
    }

    get replyLine() {
        const outcome = this.outcome;
        if (outcome.statusCode === null || outcome.statusCode === undefined) {
            return 'No reply arrived.';
        }
        return [`HTTP ${outcome.statusCode}`, outcome.status, `in ${outcome.durationMs} ms`].filter(Boolean).join(' ');
    }

    handleRecord(event) {
        this.recordId = event.detail.recordId ?? undefined;
        this.outcome = undefined;
    }

    handlePreview() {
        return this.test(false);
    }

    handleSend() {
        return this.test(true);
    }

    // The picker is unavailable while a test runs, and an answer for another record is dropped, so a Send button
    // never belongs to a record that wasn't previewed
    async test(send) {
        if (this.running) {
            return;
        }
        const recordId = this.recordId;
        this.running = true;
        this.error = undefined;
        this.status = send ? 'Sending the test' : 'Building the request';
        try {
            const outcome = await run({ endpointId: this.endpointId, recordId, send });
            if (recordId === this.recordId) {
                this.outcome = outcome;
                this.status = outcome.sent ? `Test sent: ${this.replyLine}` : 'Request built, not sent.';
            }
        } catch (e) {
            this.outcome = undefined;
            this.error = e?.body?.message ?? "Replayr couldn't run the test.";
            this.status = '';
        } finally {
            this.running = false;
        }
    }
}
