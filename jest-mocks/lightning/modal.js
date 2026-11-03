// Jest stand-in for lightning/modal, which @salesforce/sfdx-lwc-jest doesn't stub (jest.config.js maps it here).
// A dialog's close(result) becomes a "close" event, so tests can read what it closed with
import { LightningElement, api } from 'lwc';

export default class LightningModal extends LightningElement {
    @api label;
    @api size;
    @api description;

    close(result) {
        this.dispatchEvent(new CustomEvent('close', { detail: result }));
    }
}
