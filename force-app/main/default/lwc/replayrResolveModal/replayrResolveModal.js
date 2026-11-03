import { api } from 'lwc';
import LightningModal from 'lightning/modal';

const NOTE_LIMIT = 255;

// Asks how jobs whose outcome is unknown, or whose retries were used up, really ended, and why (JobActions.resolve).
// Closes with { outcome, note }, or undefined when cancelled
export default class ReplayrResolveModal extends LightningModal {
    @api count = 0;
    outcome = 'Succeeded';
    note = '';
    noteLimit = NOTE_LIMIT;

    get options() {
        return [
            { label: 'Succeeded: the call did its work', value: 'Succeeded' },
            { label: 'Failed: it did not', value: 'Failed' }
        ];
    }

    get heading() {
        return this.count === 1 ? 'Resolve 1 job' : `Resolve ${this.count} jobs`;
    }

    handleOutcome(event) {
        this.outcome = event.detail.value;
    }

    handleNote(event) {
        this.note = event.detail.value;
        // The "Say why" error goes as soon as there is a note
        this.refs.note.setCustomValidity('');
    }

    handleCancel() {
        this.close();
    }

    handleResolve() {
        const note = this.refs.note;
        if (!this.note.trim()) {
            note.setCustomValidity('Say why: for example who confirmed it with the other system.');
            note.reportValidity();
            // Focus on the note, so a screen reader reads the error out
            note.focus();
            return;
        }
        note.setCustomValidity('');
        this.close({ outcome: this.outcome, note: this.note.trim() });
    }
}
