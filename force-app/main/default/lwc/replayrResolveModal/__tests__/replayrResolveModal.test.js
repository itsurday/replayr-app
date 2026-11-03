import { createElement } from 'lwc';
import ReplayrResolveModal from 'c/replayrResolveModal';

const flushPromises = () => Array.from({ length: 10 }).reduce((chain) => chain.then(() => undefined), Promise.resolve());

async function render(count) {
    const element = createElement('c-replayr-resolve-modal', { is: ReplayrResolveModal });
    element.count = count;
    const closed = jest.fn();
    element.addEventListener('close', (event) => closed(event.detail));
    document.body.appendChild(element);
    await flushPromises();
    return { element, closed };
}

const button = (element, label) => [...element.shadowRoot.querySelectorAll('lightning-button')].find((b) => b.label === label);

describe('c-replayr-resolve-modal', () => {
    afterEach(() => {
        while (document.body.firstChild) {
            document.body.removeChild(document.body.firstChild);
        }
    });

    it('names how many jobs it resolves', async () => {
        const { element } = await render(3);
        expect(element.shadowRoot.querySelector('lightning-modal-header').label).toBe('Resolve 3 jobs');
        await expect(element).toBeAccessible();
    });

    it('closes with the outcome and the note, trimmed', async () => {
        const { element, closed } = await render(1);
        element.shadowRoot.querySelector('lightning-radio-group').dispatchEvent(new CustomEvent('change', { detail: { value: 'Failed' } }));
        element.shadowRoot.querySelector('lightning-textarea').dispatchEvent(new CustomEvent('change', { detail: { value: '  Acme confirmed it never arrived. ' } }));

        button(element, 'Resolve').click();

        expect(closed).toHaveBeenCalledWith({ outcome: 'Failed', note: 'Acme confirmed it never arrived.' });
    });

    it('asks for a note before closing', async () => {
        const { element, closed } = await render(1);
        const note = element.shadowRoot.querySelector('lightning-textarea');
        note.setCustomValidity = jest.fn();
        note.reportValidity = jest.fn();
        note.focus = jest.fn();

        button(element, 'Resolve').click();

        expect(closed).not.toHaveBeenCalled();
        expect(note.setCustomValidity).toHaveBeenCalledWith(expect.stringContaining('Say why'));
        expect(note.reportValidity).toHaveBeenCalled();
        expect(note.focus).toHaveBeenCalled();

        // Typing a note clears the error
        note.dispatchEvent(new CustomEvent('change', { detail: { value: 'Checked.' } }));
        expect(note.setCustomValidity).toHaveBeenLastCalledWith('');
    });

    it('closes with nothing on Cancel', async () => {
        const { element, closed } = await render(1);
        button(element, 'Cancel').click();
        expect(closed).toHaveBeenCalledTimes(1);
        // No outcome: an event without a detail carries null
        expect(closed.mock.calls[0][0]).toBeNull();
    });
});
