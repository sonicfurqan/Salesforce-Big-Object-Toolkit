import { LightningElement, api, track } from "lwc";
import { NavigationMixin } from "lightning/navigation";
import { ShowToastEvent } from "lightning/platformShowToastEvent";
import getObjectOptions from "@salesforce/apex/BIGOTOOL_FieldLogWizardController.getObjectOptions";
import getFieldOptions from "@salesforce/apex/BIGOTOOL_FieldLogWizardController.getFieldOptions";
import getConfigForEdit from "@salesforce/apex/BIGOTOOL_FieldLogWizardController.getConfigForEdit";
import saveConfig from "@salesforce/apex/BIGOTOOL_FieldLogWizardController.saveConfig";

const STEPS = [
  { label: "Object", value: "1" },
  { label: "Fields", value: "2" },
  { label: "Events & Mode", value: "3" },
  { label: "Retention", value: "4" },
  { label: "Review", value: "5" }
];

const ASYNC_MODES = [
  { label: "Platform Event (recommended)", value: "PlatformEvent" },
  { label: "Queueable", value: "Queueable" },
  { label: "Synchronous", value: "Synchronous" }
];

export default class BigotoolFieldLogWizard extends NavigationMixin(LightningElement) {
  steps = STEPS;
  asyncModeOptions = ASYNC_MODES;

  @api recordId;

  @track currentStep = "1";
  @track isLoading = false;
  @track saved = false;
  @track isActive = true;
  savedConfigId;

  // Step 1
  @track objectOptions = [];
  @track sourceObject = "";
  @track sourceObjectLabel = "";
  objectSearch = "";

  // Step 2
  @track allFields = [];
  @track selectedFieldNames = [];
  fieldSearch = "";
  @track trackedConfig = {}; // apiName -> { maskValue }

  // Step 3
  @track logOnCreate = false;
  @track logOnUpdate = true;
  @track logOnDelete = false;
  @track logOnUndelete = false;
  @track asyncMode = "PlatformEvent";

  // Step 4
  @track retentionDays = 0;

  // Config meta
  configName = "";

  connectedCallback() {
    if (this.recordId) {
      this.loadForEdit();
    } else {
      this.loadObjects();
    }
  }

  get isEditMode() {
    return !!this.recordId;
  }

  get cardTitle() {
    return this.isEditMode ? "Edit Field History Configuration" : "Field History Wizard";
  }

  async loadForEdit() {
    this.isLoading = true;
    try {
      const detail = await getConfigForEdit({ configId: this.recordId });
      this.sourceObject = detail.sourceObject;
      this.sourceObjectLabel = detail.sourceObjectLabel || "";
      this.configName = detail.configName || "";
      this.isActive = detail.isActive === true;
      this.logOnCreate = detail.logOnCreate === true;
      this.logOnUpdate = detail.logOnUpdate !== false;
      this.logOnDelete = detail.logOnDelete === true;
      this.logOnUndelete = detail.logOnUndelete === true;
      this.asyncMode = detail.asyncMode || "PlatformEvent";
      this.retentionDays = detail.retentionDays == null ? 0 : detail.retentionDays;

      const names = [];
      const cfg = {};
      (detail.fields || []).forEach((f) => {
        names.push(f.fieldApiName);
        cfg[f.fieldApiName] = { maskValue: f.maskValue === true };
      });
      this.selectedFieldNames = names;
      this.trackedConfig = cfg;

      await this.loadFields();
    } catch (e) {
      this.notifyError("Unable to load configuration", e);
    } finally {
      this.isLoading = false;
    }
  }

  async loadObjects() {
    this.isLoading = true;
    try {
      this.objectOptions = await getObjectOptions();
    } catch (e) {
      this.notifyError("Unable to load objects", e);
    } finally {
      this.isLoading = false;
    }
  }

  get filteredObjectOptions() {
    const term = this.objectSearch.toLowerCase();
    if (!term) {
      return this.objectOptions;
    }
    return this.objectOptions.filter((o) => o.label.toLowerCase().includes(term));
  }

  get availableFields() {
    const term = this.fieldSearch.toLowerCase();
    const selected = new Set(this.selectedFieldNames);
    return this.allFields
      .filter((f) => !selected.has(f.apiName))
      .filter((f) => !term || f.label.toLowerCase().includes(term) || f.apiName.toLowerCase().includes(term));
  }

  get trackedFields() {
    return this.selectedFieldNames.map((apiName) => {
      const meta = this.allFields.find((f) => f.apiName === apiName) || {};
      const cfg = this.trackedConfig[apiName] || {};
      return {
        apiName,
        label: meta.label || apiName,
        dataType: meta.dataType,
        maskValue: cfg.maskValue === true
      };
    });
  }

  get reviewFields() {
    return this.trackedFields.map((f) => ({
      ...f,
      maskLabel: f.maskValue ? "Masked" : "Plain"
    }));
  }

  get eventSummary() {
    const events = [];
    if (this.logOnCreate) events.push("Create");
    if (this.logOnUpdate) events.push("Update");
    if (this.logOnDelete) events.push("Delete");
    if (this.logOnUndelete) events.push("Undelete");
    return events.length ? events.join(", ") : "None selected";
  }

  get retentionSummary() {
    return Number(this.retentionDays) > 0 ? `${this.retentionDays} days` : "Infinite (no purge)";
  }

  get activeSummary() {
    return this.isActive ? "Active" : "Inactive";
  }

  get selectedFieldCount() {
    return this.selectedFieldNames.length;
  }

  // Step navigation guards
  get isStep1() {
    return this.currentStep === "1";
  }
  get isStep2() {
    return this.currentStep === "2";
  }
  get isStep3() {
    return this.currentStep === "3";
  }
  get isStep4() {
    return this.currentStep === "4";
  }
  get isStep5() {
    return this.currentStep === "5";
  }
  get isFirstStep() {
    return this.currentStep === "1";
  }
  get isLastStep() {
    return this.currentStep === "5";
  }

  get nextDisabled() {
    if (this.isStep1) return !this.sourceObject;
    if (this.isStep2) return this.selectedFieldNames.length === 0;
    return false;
  }

  // Step 1 handlers
  handleObjectSearch(event) {
    this.objectSearch = event.target.value;
  }

  handleObjectSelect(event) {
    this.sourceObject = event.currentTarget.dataset.value;
    this.sourceObjectLabel = event.currentTarget.dataset.label || "";
    this.configName = `${this.sourceObject}_FieldLog`;
  }

  // Step 2 handlers
  async loadFields() {
    if (!this.sourceObject) return;
    this.isLoading = true;
    try {
      this.allFields = await getFieldOptions({
        objectApiName: this.sourceObject
      });
    } catch (e) {
      this.notifyError("Unable to load fields", e);
    } finally {
      this.isLoading = false;
    }
  }

  handleFieldSearch(event) {
    this.fieldSearch = event.target.value;
  }

  handleAddField(event) {
    const apiName = event.currentTarget.dataset.value;
    if (!this.selectedFieldNames.includes(apiName)) {
      this.selectedFieldNames = [...this.selectedFieldNames, apiName];
      this.trackedConfig = {
        ...this.trackedConfig,
        [apiName]: { maskValue: false }
      };
    }
  }

  handleRemoveField(event) {
    const apiName = event.currentTarget.dataset.value;
    this.selectedFieldNames = this.selectedFieldNames.filter((n) => n !== apiName);
    const copy = { ...this.trackedConfig };
    delete copy[apiName];
    this.trackedConfig = copy;
  }

  handleMaskToggle(event) {
    const apiName = event.currentTarget.dataset.value;
    this.trackedConfig = {
      ...this.trackedConfig,
      [apiName]: {
        ...(this.trackedConfig[apiName] || {}),
        maskValue: event.target.checked
      }
    };
  }

  // Step 3 handlers
  handleLogOnCreate(event) {
    this.logOnCreate = event.target.checked;
  }
  handleLogOnUpdate(event) {
    this.logOnUpdate = event.target.checked;
  }
  handleLogOnDelete(event) {
    this.logOnDelete = event.target.checked;
  }
  handleLogOnUndelete(event) {
    this.logOnUndelete = event.target.checked;
  }
  handleAsyncMode(event) {
    this.asyncMode = event.detail.value;
  }

  // Step 4 handlers
  handleRetention(event) {
    this.retentionDays = event.target.value;
  }

  handleConfigName(event) {
    this.configName = event.target.value;
  }

  handleActiveToggle(event) {
    this.isActive = event.target.checked;
  }

  // Navigation
  handleNext() {
    const idx = Number(this.currentStep);
    if (idx === 1) {
      this.loadFields();
    }
    if (idx < STEPS.length) {
      this.currentStep = String(idx + 1);
    }
  }

  handlePrevious() {
    const idx = Number(this.currentStep);
    if (idx > 1) {
      this.currentStep = String(idx - 1);
    }
  }

  async handleGenerate() {
    this.isLoading = true;
    try {
      const input = {
        configId: this.recordId || null,
        configName: this.configName,
        sourceObject: this.sourceObject,
        sourceObjectLabel: this.sourceObjectLabel,
        isActive: this.isActive,
        logOnCreate: this.logOnCreate,
        logOnUpdate: this.logOnUpdate,
        logOnDelete: this.logOnDelete,
        logOnUndelete: this.logOnUndelete,
        asyncMode: this.asyncMode,
        retentionDays: Number(this.retentionDays) || 0,
        fields: this.trackedFields.map((f) => ({
          fieldApiName: f.apiName,
          fieldLabel: f.label,
          trackOldNew: true,
          maskValue: f.maskValue
        }))
      };
      this.savedConfigId = await saveConfig({
        inputJson: JSON.stringify(input)
      });
      this.saved = true;
      this.dispatchEvent(
        new ShowToastEvent({
          title: "Field history configuration saved",
          message: `Tracking ${this.selectedFieldCount} field(s) on ${this.sourceObject}.`,
          variant: "success"
        })
      );
      this.navigateToRecord();
    } catch (e) {
      this.notifyError("Unable to save configuration", e);
    } finally {
      this.isLoading = false;
    }
  }

  handleStartOver() {
    this.currentStep = "1";
    this.sourceObject = "";
    this.sourceObjectLabel = "";
    this.objectSearch = "";
    this.allFields = [];
    this.selectedFieldNames = [];
    this.fieldSearch = "";
    this.trackedConfig = {};
    this.logOnCreate = false;
    this.logOnUpdate = true;
    this.logOnDelete = false;
    this.logOnUndelete = false;
    this.asyncMode = "PlatformEvent";
    this.retentionDays = 0;
    this.configName = "";
    this.isActive = true;
    this.saved = false;
    this.savedConfigId = undefined;
  }

  handleCancel() {
    if (this.isEditMode) {
      // Navigate back to the record being edited
      this[NavigationMixin.Navigate]({
        type: "standard__recordPage",
        attributes: {
          recordId: this.recordId,
          actionName: "view"
        }
      });
    } else {
      // Navigate to the list view of Field_Log_Config__c
      this[NavigationMixin.Navigate]({
        type: "standard__objectPage",
        attributes: {
          objectApiName: "Field_Log_Config__c",
          actionName: "list"
        },
        state: {
          filterName: "Recent"
        }
      });
    }
  }

  navigateToRecord() {
    if (!this.savedConfigId) {
      return;
    }
    this[NavigationMixin.Navigate]({
      type: "standard__recordPage",
      attributes: {
        recordId: this.savedConfigId,
        objectApiName: "Field_Log_Config__c",
        actionName: "view"
      }
    });
  }

  notifyError(title, error) {
    let message = "Unknown error";
    if (error && error.body && error.body.message) {
      message = error.body.message;
    } else if (error && error.message) {
      message = error.message;
    }
    this.dispatchEvent(new ShowToastEvent({ title, message, variant: "error" }));
  }
}
