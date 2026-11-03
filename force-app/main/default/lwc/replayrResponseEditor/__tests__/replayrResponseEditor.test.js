import { createElement } from 'lwc';
import ReplayrResponseEditor from 'c/replayrResponseEditor';
import saveResponse from '@salesforce/apex/ConsoleMappings.saveResponse';
import propose from '@salesforce/apex/ConsoleMappings.propose';

jest.mock('@salesforce/apex/ConsoleMappings.saveResponse', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex/ConsoleMappings.propose', () => ({ default: jest.fn() }), { virtual: true });

const ENDPOINT = 'a01000000000001AAA';
const MAPPING = {
    id: 'a03000000000002AAA',
    direction: 'Response',
    targetObject: 'Account',
    operation: 'Upsert',
    matchField: 'AccountNumber',
    listPath: 'items',
    rules: '{"fields": {"AccountNumber": "id", "Name": "name"}}'
};

const flushPromises = () => Array.from({ length: 10 }).reduce((chain) => chain.then(() => undefined), Promise.resolve());

async function render(mapping) {
    const element = createElement('c-replayr-response-editor', { is: ReplayrResponseEditor });
    element.endpointId = ENDPOINT;
    element.mapping = mapping;
    const events = [];
    element.addEventListener('saved', () => events.push('saved'));
    element.addEventListener('cancel', () => events.push('cancel'));
    document.body.appendChild(element);
    await flushPromises();
    return { element, events };
}

const inputs = (element) => [...element.shadowRoot.querySelectorAll('lightning-input')];
const input = (element, label) => inputs(element).find((i) => i.label === label);
const button = (element, label) => [...element.shadowRoot.querySelectorAll('lightning-button')].find((b) => b.label === label);
const ruleRows = (element) =>
    inputs(element)
        .filter((i) => i.label.startsWith('Field '))
        .map((i) => [i.value, input(element, i.label.replace('Field', 'JSON path')).value]);
const change = (target, value) => target.dispatchEvent(new CustomEvent('change', { detail: { value } }));

describe('c-replayr-response-editor', () => {
    afterEach(() => {
        while (document.body.firstChild) {
            document.body.removeChild(document.body.firstChild);
        }
        jest.clearAllMocks();
    });

    it('shows an existing mapping with its rules as rows, and focus on its heading', async () => {
        const { element } = await render(MAPPING);

        const heading = element.shadowRoot.querySelector('h4');
        expect(heading.textContent).toBe('Edit the Response mapping');
        expect(element.shadowRoot.activeElement).toBe(heading);
        expect(input(element, 'Object').value).toBe('Account');
        expect(element.shadowRoot.querySelector('lightning-combobox').value).toBe('Upsert');
        expect(input(element, 'Match Field').value).toBe('AccountNumber');
        expect(input(element, 'List Path').value).toBe('items');
        expect(ruleRows(element)).toEqual([
            ['AccountNumber', 'id'],
            ['Name', 'name']
        ]);
        await expect(element).toBeAccessible();
    });

    it('starts a new mapping with one empty rule, and an unreadable one the same way', async () => {
        let { element } = await render(undefined);
        expect(element.shadowRoot.querySelector('h4').textContent).toBe('New Response mapping');
        expect(ruleRows(element)).toEqual([['', '']]);
        document.body.removeChild(element);

        ({ element } = await render({ ...MAPPING, rules: 'not json' }));
        expect(ruleRows(element)).toEqual([['', '']]);
    });

    it('adds, edits and removes rules, then saves them with the rest through the server', async () => {
        const { element, events } = await render(MAPPING);
        button(element, 'Add a rule').click();
        await flushPromises();
        change(input(element, 'Field 3'), 'Phone');
        change(input(element, 'JSON path 3'), 'contact.phone');
        [...element.shadowRoot.querySelectorAll('lightning-button-icon')].find((b) => b.alternativeText === 'Remove rule 2').click();
        await flushPromises();
        saveResponse.mockResolvedValue(MAPPING.id);

        button(element, 'Save').click();
        await flushPromises();

        expect(saveResponse).toHaveBeenCalledWith({
            id: MAPPING.id,
            endpointId: ENDPOINT,
            targetObject: 'Account',
            operation: 'Upsert',
            matchField: 'AccountNumber',
            listPath: 'items',
            rulesJson: JSON.stringify([
                { field: 'AccountNumber', path: 'id' },
                { field: 'Phone', path: 'contact.phone' }
            ])
        });
        expect(events).toEqual(['saved']);
    });

    it("keeps the editor open with the server's reason when it refuses", async () => {
        const { element, events } = await render(MAPPING);
        const refusal = new Error('refused');
        refusal.body = { message: 'Not saved: Upsert needs a Match Field' };
        saveResponse.mockRejectedValue(refusal);

        button(element, 'Save').click();
        await flushPromises();

        expect(element.shadowRoot.querySelector('[role="alert"]').textContent).toBe('Not saved: Upsert needs a Match Field');
        expect(events).toEqual([]);
        await expect(element).toBeAccessible();
    });

    it('fills the rules and the List Path from a sample reply, and says what matched nothing', async () => {
        const { element } = await render(undefined);
        change(input(element, 'Object'), 'Account');
        change(element.shadowRoot.querySelector('lightning-textarea'), '{"items": [{"name": "Acme", "colour": "red"}]}');
        propose.mockResolvedValue({ listPath: 'items', listPathCandidates: [], rules: [{ field: 'Name', path: 'name' }], unmatched: ['colour'] });

        button(element, 'Propose rules').click();
        await flushPromises();

        expect(propose).toHaveBeenCalledWith({ sampleJson: '{"items": [{"name": "Acme", "colour": "red"}]}', targetObject: 'Account', listPath: null });
        // The empty starting row gives way to the proposal
        expect(ruleRows(element)).toEqual([['Name', 'name']]);
        expect(input(element, 'List Path').value).toBe('items');
        expect(element.shadowRoot.textContent).toContain('Not matched to a field: colour.');
        expect(element.shadowRoot.querySelector('[role="status"]').textContent).toContain('1 rule proposed and added');
    });

    it('keeps the rules already written, uses a List Path already typed, and adds only new fields', async () => {
        const { element } = await render(MAPPING);
        propose.mockResolvedValue({
            listPath: 'items',
            listPathCandidates: [],
            rules: [
                { field: 'Name', path: 'title' },
                { field: 'Phone', path: 'phone' }
            ],
            unmatched: []
        });

        button(element, 'Propose rules').click();
        await flushPromises();

        expect(propose).toHaveBeenCalledWith(expect.objectContaining({ listPath: 'items' }));
        expect(ruleRows(element)).toEqual([
            ['AccountNumber', 'id'],
            ['Name', 'name'],
            ['Phone', 'phone']
        ]);
    });

    it('keeps Save unavailable while a proposal is under way', async () => {
        const { element } = await render(MAPPING);
        let answer;
        propose.mockReturnValue(new Promise((settle) => (answer = settle)));

        button(element, 'Propose rules').click();
        await flushPromises();
        expect(button(element, 'Save').disabled).toBe(true);
        expect(button(element, 'Propose rules').disabled).toBe(true);

        answer({ listPath: 'items', listPathCandidates: [], rules: [], unmatched: [] });
        await flushPromises();
        expect(button(element, 'Save').disabled).toBe(false);
    });

    it('moves focus to a new row, and after a remove to the row that took its place', async () => {
        const { element } = await render(MAPPING);
        // The test stand-ins can't take focus, so the calls themselves are checked
        const focus = jest.spyOn(HTMLElement.prototype, 'focus');

        button(element, 'Add a rule').click();
        await flushPromises();
        expect(focus.mock.contexts).toContain(input(element, 'Field 3'));

        [...element.shadowRoot.querySelectorAll('lightning-button-icon')].find((b) => b.alternativeText === 'Remove rule 1').click();
        await flushPromises();
        expect(focus.mock.contexts.pop()).toBe(input(element, 'Field 1'));
        focus.mockRestore();
    });

    it('offers the lists found when there are several, and proposes again from the one chosen', async () => {
        const { element } = await render(undefined);
        propose.mockResolvedValueOnce({ listPath: null, listPathCandidates: ['orders', 'refunds'], rules: [], unmatched: [] });
        button(element, 'Propose rules').click();
        await flushPromises();

        const choice = element.shadowRoot.querySelector('lightning-radio-group');
        expect(choice.options.map((option) => option.value)).toEqual(['orders', 'refunds']);
        propose.mockResolvedValueOnce({ listPath: 'refunds', listPathCandidates: [], rules: [{ field: 'Name', path: 'who' }], unmatched: [] });
        change(choice, 'refunds');
        await flushPromises();

        expect(propose).toHaveBeenLastCalledWith(expect.objectContaining({ listPath: 'refunds' }));
        expect(ruleRows(element)).toEqual([['Name', 'who']]);
        expect(element.shadowRoot.querySelector('lightning-radio-group')).toBeNull();
    });

    it("shows why a sample can't be used, and closes on Cancel", async () => {
        const { element, events } = await render(undefined);
        const failure = new Error('failed');
        failure.body = { message: 'The sample is not valid JSON' };
        propose.mockRejectedValue(failure);

        button(element, 'Propose rules').click();
        await flushPromises();
        expect(element.shadowRoot.querySelector('[role="alert"]').textContent).toBe('The sample is not valid JSON');

        button(element, 'Cancel').click();
        expect(events).toEqual(['cancel']);
    });
});
