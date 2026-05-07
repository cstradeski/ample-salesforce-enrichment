import { LightningElement, api, track } from 'lwc';

export default class AmplemarketFieldPicker extends LightningElement {
    @api label;
    @api placeholder = 'Select a field';

    @track query = '';
    @track isOpen = false;
    @track highlightedIndex = 0;

    _value;
    _options = [];

    @api
    get value() {
        return this._value;
    }
    set value(v) {
        this._value = v;
        this.syncQueryFromValue();
    }

    @api
    get options() {
        return this._options;
    }
    set options(v) {
        this._options = Array.isArray(v) ? v : [];
        this.syncQueryFromValue();
    }

    syncQueryFromValue() {
        const found = this._options.find((o) => o.value === this._value);
        if (found) this.query = found.label;
        else if (this._value) this.query = this._value;
        else this.query = '';
    }

    get filteredOptions() {
        const q = (this.query || '').toLowerCase().trim();
        const all = this._options || [];
        // If the input matches the currently selected option exactly, treat as "no filter"
        // so the user sees the full list when they reopen the dropdown.
        const selectedLabel = (() => {
            const f = all.find((o) => o.value === this._value);
            return f ? f.label.toLowerCase() : null;
        })();
        const showAll = !q || (selectedLabel && q === selectedLabel);
        const filtered = showAll
            ? all
            : all.filter(
                  (o) =>
                      (o.label && o.label.toLowerCase().includes(q)) ||
                      (o.value && o.value.toLowerCase().includes(q))
              );
        return filtered.map((o, i) => ({
            ...o,
            cssClass:
                i === this.highlightedIndex
                    ? 'slds-media slds-listbox__option slds-listbox__option_plain slds-media_small slds-has-focus'
                    : 'slds-media slds-listbox__option slds-listbox__option_plain slds-media_small'
        }));
    }

    get hasNoMatches() {
        return this.isOpen && this.filteredOptions.length === 0;
    }

    get hasValue() {
        return !!this._value;
    }

    get comboboxClass() {
        return this.isOpen
            ? 'slds-combobox slds-dropdown-trigger slds-dropdown-trigger_click slds-is-open'
            : 'slds-combobox slds-dropdown-trigger slds-dropdown-trigger_click';
    }

    handleFocus(event) {
        this.isOpen = true;
        this.highlightedIndex = 0;
        // Select all so the user can immediately type to replace
        if (event.target && typeof event.target.select === 'function') {
            event.target.select();
        }
    }

    handleInput(event) {
        this.query = event.target.value;
        this.highlightedIndex = 0;
        this.isOpen = true;
    }

    // mousedown preventDefault stops the input from blurring before we can read the click
    handleOptionMouseDown(event) {
        event.preventDefault();
        const v = event.currentTarget.dataset.value;
        this.selectValue(v);
    }

    handleBlur() {
        // Small delay so option click can register first; mousedown handler usually beats this anyway.
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        setTimeout(() => {
            this.isOpen = false;
            // If user typed but didn't pick an option, restore the input to the selected label
            this.syncQueryFromValue();
        }, 150);
    }

    handleKeydown(event) {
        const opts = this.filteredOptions;
        switch (event.key) {
            case 'ArrowDown':
                event.preventDefault();
                if (!this.isOpen) {
                    this.isOpen = true;
                } else {
                    this.highlightedIndex = Math.min(this.highlightedIndex + 1, opts.length - 1);
                }
                break;
            case 'ArrowUp':
                event.preventDefault();
                this.highlightedIndex = Math.max(this.highlightedIndex - 1, 0);
                break;
            case 'Enter':
                event.preventDefault();
                if (this.isOpen && opts[this.highlightedIndex]) {
                    this.selectValue(opts[this.highlightedIndex].value);
                }
                break;
            case 'Escape':
                this.isOpen = false;
                this.syncQueryFromValue();
                break;
            default:
                break;
        }
    }

    selectValue(v) {
        this._value = v;
        this.syncQueryFromValue();
        this.isOpen = false;
        this.dispatchEvent(
            new CustomEvent('change', {
                detail: { value: v }
            })
        );
    }

    // mousedown (not click) so the input's blur handler doesn't fire first and re-sync the query.
    handleClearMouseDown(event) {
        event.preventDefault();
        event.stopPropagation();
        this.selectValue('');
    }
}
