import { LightningElement, api } from "lwc";

export default class BigotoolSearchablePicklist extends LightningElement {
  @api label;
  @api placeholder = "Search...";
  @api allLabel = "All";

  _options = [];
  _value = "";

  searchTerm = "";
  open = false;
  highlightedValue = "";

  @api
  get options() {
    return this._options;
  }
  set options(val) {
    this._options = Array.isArray(val) ? val : [];
    this.syncSearchToValue();
  }

  @api
  get value() {
    return this._value;
  }
  set value(val) {
    this._value = val || "";
    this.syncSearchToValue();
  }

  syncSearchToValue() {
    if (this.open) {
      return;
    }
    const selected = (this._options || []).find((o) => o.value === this._value && o.value !== "");
    this.searchTerm = selected ? selected.label : "";
  }

  get hasSelection() {
    return !!this._value;
  }

  get filteredOptions() {
    const q = (this.searchTerm || "").toLowerCase().trim();
    const base = (this._options || []).filter((o) => o.value !== "");
    const list = q ? base.filter((o) => o.label.toLowerCase().includes(q)) : base;
    return list.map((o) => ({
      ...o,
      itemClass:
        "slds-listbox__option slds-listbox__option_plain slds-media slds-media_small slds-media_inline" +
        (o.value === this.highlightedValue ? " slds-has-focus" : "")
    }));
  }

  get hasOptions() {
    return this.filteredOptions.length > 0;
  }

  get comboboxClass() {
    return "slds-combobox slds-dropdown-trigger slds-dropdown-trigger_click" + (this.open ? " slds-is-open" : "");
  }

  handleFocus() {
    this.open = true;
  }

  handleInput(event) {
    this.searchTerm = event.target.value;
    this.open = true;
    if (this._value) {
      this._value = "";
      this.dispatchChange("");
    }
  }

  handleSelect(event) {
    const value = event.currentTarget.dataset.value;
    const opt = (this._options || []).find((o) => o.value === value);
    this._value = value;
    this.searchTerm = opt ? opt.label : "";
    this.open = false;
    this.dispatchChange(value);
  }

  handleClear() {
    this._value = "";
    this.searchTerm = "";
    this.open = false;
    this.dispatchChange("");
    const input = this.template.querySelector("input");
    if (input) {
      input.focus();
    }
  }

  handleBlur() {
    // Delay so a click on an option is registered before the dropdown closes.
    // eslint-disable-next-line @lwc/lwc/no-async-operation
    window.setTimeout(() => {
      this.open = false;
      this.syncSearchToValue();
    }, 200);
  }

  dispatchChange(value) {
    this.dispatchEvent(new CustomEvent("change", { detail: { value } }));
  }
}
