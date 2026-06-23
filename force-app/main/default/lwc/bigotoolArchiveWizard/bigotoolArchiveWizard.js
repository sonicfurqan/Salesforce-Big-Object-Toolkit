import { LightningElement, api, track } from "lwc";
import { NavigationMixin } from "lightning/navigation";
import { ShowToastEvent } from "lightning/platformShowToastEvent";
import getObjectOptions from "@salesforce/apex/BIGOTOOL_ArchiveWizardController.getObjectOptions";
import getFieldOptions from "@salesforce/apex/BIGOTOOL_ArchiveWizardController.getFieldOptions";
import getDateFieldOptions from "@salesforce/apex/BIGOTOOL_ArchiveWizardController.getDateFieldOptions";
import getUniqueFieldOptions from "@salesforce/apex/BIGOTOOL_ArchiveWizardController.getUniqueFieldOptions";
import getRestoreProfiles from "@salesforce/apex/BIGOTOOL_ArchiveWizardController.getRestoreProfiles";
import previewMatchingCount from "@salesforce/apex/BIGOTOOL_ArchiveWizardController.previewMatchingCount";
import getConfigForEdit from "@salesforce/apex/BIGOTOOL_ArchiveWizardController.getConfigForEdit";
import saveConfig from "@salesforce/apex/BIGOTOOL_ArchiveWizardController.saveConfig";

const STEPS = [
  { label: "Object", value: "1" },
  { label: "Criteria", value: "2" },
  { label: "Fields", value: "3" },
  { label: "Schedule", value: "4" },
  { label: "Restore", value: "5" },
  { label: "Review", value: "6" }
];

const CRITERIA_OPTIONS = [
  { label: "Age (records older than N days)", value: "Age" },
  { label: "SOQL Filter", value: "SOQL_Filter" },
  { label: "Both (age AND filter)", value: "Both" }
];

const CONFLICT_OPTIONS = [
  { label: "Skip existing", value: "Skip" },
  { label: "Overwrite existing", value: "Overwrite" },
  { label: "Clone as new", value: "Clone" }
];

const FREQUENCY_OPTIONS = [
  { label: "Daily (1 AM)", value: "0 0 1 * * ?" },
  { label: "Weekly (Sun 1 AM)", value: "0 0 1 ? * SUN" },
  { label: "Monthly (1st, 1 AM)", value: "0 0 1 1 * ?" },
  { label: "Custom / Manual", value: "" }
];

export default class BigotoolArchiveWizard extends NavigationMixin(LightningElement) {
  steps = STEPS;
  criteriaOptions = CRITERIA_OPTIONS;
  conflictOptions = CONFLICT_OPTIONS;
  frequencyOptions = FREQUENCY_OPTIONS;

  @api recordId;

  @track currentStep = "1";
  @track isLoading = false;
  @track saved = false;
  savedConfigId;

  // Step 1 - Object
  @track objectOptions = [];
  @track sourceObject = "";
  @track sourceObjectLabel = "";
  objectSearch = "";
  @track isActive = true;
  configName = "";

  // Step 2 - Criteria
  @track criteriaType = "Age";
  @track dateFieldOptions = [];
  @track ageField = "";
  @track ageThresholdDays = 365;
  @track filterLogic = "";
  @track previewCount = null;
  @track previewError = "";

  // Step 3 - Fields (list-view columns)
  @track allFields = [];
  @track selectedFieldNames = [];
  fieldSearch = "";

  // Step 4 - Schedule
  @track frequency = "0 0 1 * * ?";
  @track scheduleCron = "0 0 1 * * ?";
  @track batchSize = 200;
  @track deleteAfterArchive = false;

  // Step 5 - Restore
  @track enableRestore = false;
  @track restoreLockedOn = false;
  @track restoreProfileOptions = [];
  @track restoreProfileId = "";
  @track uniqueFieldOptions = [];
  @track matchField = "Id";
  @track onConflict = "Skip";
  @track reparentOwner = false;
  @track bypassAutomation = true;

  connectedCallback() {
    if (this.recordId) {
      this.loadForEdit();
    } else {
      this.loadObjects();
    }
    this.loadRestoreProfiles();
  }

  get isEditMode() {
    return !!this.recordId;
  }

  get cardTitle() {
    return this.isEditMode ? "Edit Archive Configuration" : "Archive Wizard";
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

  async loadRestoreProfiles() {
    try {
      this.restoreProfileOptions = await getRestoreProfiles();
    } catch (e) {
      // Non-fatal; restore step can still create a new profile.
      this.restoreProfileOptions = [];
    }
  }

  async loadForEdit() {
    this.isLoading = true;
    try {
      const detail = await getConfigForEdit({ configId: this.recordId });
      this.sourceObject = detail.sourceObject;
      this.configName = detail.configName || "";
      this.isActive = detail.isActive === true;
      this.criteriaType = detail.criteriaType || "Age";
      this.ageField = detail.ageField || "";
      this.ageThresholdDays = detail.ageThresholdDays == null ? 365 : detail.ageThresholdDays;
      this.filterLogic = detail.filterLogic || "";
      this.selectedFieldNames = detail.listViewFields || [];
      this.deleteAfterArchive = detail.deleteAfterArchive === true;
      this.batchSize = detail.batchSize == null ? 200 : detail.batchSize;
      this.scheduleCron = detail.scheduleCron || "";
      this.frequency = this.matchFrequency(this.scheduleCron);
      if (detail.restoreProfile) {
        this.enableRestore = true;
        this.restoreLockedOn = true;
        this.restoreProfileId = detail.restoreProfile.profileId || "";
        this.matchField = detail.restoreProfile.matchField || "Id";
        this.onConflict = detail.restoreProfile.onConflict || "Skip";
        this.reparentOwner = detail.restoreProfile.reparentOwner === true;
        this.bypassAutomation = detail.restoreProfile.bypassAutomation === true;
      }
      await this.loadFieldMetadata();
    } catch (e) {
      this.notifyError("Unable to load configuration", e);
    } finally {
      this.isLoading = false;
    }
  }

  matchFrequency(cron) {
    const found = FREQUENCY_OPTIONS.find((o) => o.value === cron);
    return found ? found.value : "";
  }

  async loadFieldMetadata() {
    if (!this.sourceObject) {
      return;
    }
    this.isLoading = true;
    try {
      const [fields, dateFields, uniqueFields] = await Promise.all([
        getFieldOptions({ objectApiName: this.sourceObject }),
        getDateFieldOptions({ objectApiName: this.sourceObject }),
        getUniqueFieldOptions({ objectApiName: this.sourceObject })
      ]);
      this.allFields = fields;
      this.dateFieldOptions = dateFields.map((f) => ({
        label: `${f.label} (${f.apiName})`,
        value: f.apiName
      }));
      this.uniqueFieldOptions = uniqueFields.map((f) => ({
        label: `${f.label} (${f.apiName})`,
        value: f.apiName
      }));
    } catch (e) {
      this.notifyError("Unable to load fields", e);
    } finally {
      this.isLoading = false;
    }
  }

  // ---- Step 1 ----
  handleObjectSearch(event) {
    this.objectSearch = event.target.value;
  }

  get filteredObjectOptions() {
    const term = this.objectSearch.toLowerCase();
    if (!term) {
      return this.objectOptions;
    }
    return this.objectOptions.filter((o) => o.label.toLowerCase().includes(term));
  }

  handleObjectSelect(event) {
    this.sourceObject = event.currentTarget.dataset.value;
    this.sourceObjectLabel = event.currentTarget.dataset.label || "";
    this.configName = `${this.sourceObject}_Archive`;
  }

  handleActiveToggle(event) {
    this.isActive = event.target.checked;
  }

  handleConfigName(event) {
    this.configName = event.target.value;
  }

  // ---- Step 2 ----
  handleCriteriaType(event) {
    this.criteriaType = event.detail.value;
    this.previewCount = null;
    this.previewError = "";
  }

  get showAge() {
    return this.criteriaType === "Age" || this.criteriaType === "Both";
  }

  get showFilter() {
    return this.criteriaType === "SOQL_Filter" || this.criteriaType === "Both";
  }

  handleAgeField(event) {
    this.ageField = event.detail.value;
  }

  handleAgeThreshold(event) {
    this.ageThresholdDays = event.target.value;
  }

  handleFilterLogic(event) {
    this.filterLogic = event.target.value;
  }

  async handlePreview() {
    this.previewError = "";
    this.previewCount = null;
    this.isLoading = true;
    try {
      const input = this.buildInput();
      this.previewCount = await previewMatchingCount({
        inputJson: JSON.stringify(input)
      });
    } catch (e) {
      this.previewError = this.extractMessage(e);
    } finally {
      this.isLoading = false;
    }
  }

  get hasPreview() {
    return this.previewCount !== null && this.previewCount !== undefined;
  }

  // ---- Step 3 ----
  handleFieldSearch(event) {
    this.fieldSearch = event.target.value;
  }

  get availableFields() {
    const term = this.fieldSearch.toLowerCase();
    const selected = new Set(this.selectedFieldNames);
    return this.allFields
      .filter((f) => !selected.has(f.apiName))
      .filter((f) => !term || f.label.toLowerCase().includes(term) || f.apiName.toLowerCase().includes(term));
  }

  get selectedFields() {
    return this.selectedFieldNames.map((apiName) => {
      const meta = this.allFields.find((f) => f.apiName === apiName) || {};
      return { apiName, label: meta.label || apiName };
    });
  }

  get canRemoveFields() {
    return !this.isEditMode;
  }

  get selectedFieldCount() {
    return this.selectedFieldNames.length;
  }

  handleAddField(event) {
    const apiName = event.currentTarget.dataset.value;
    if (!this.selectedFieldNames.includes(apiName)) {
      this.selectedFieldNames = [...this.selectedFieldNames, apiName];
    }
  }

  handleRemoveField(event) {
    if (!this.canRemoveFields) {
      return;
    }
    const apiName = event.currentTarget.dataset.value;
    this.selectedFieldNames = this.selectedFieldNames.filter((n) => n !== apiName);
  }

  // ---- Step 4 ----
  handleFrequency(event) {
    this.frequency = event.detail.value;
    if (this.frequency) {
      this.scheduleCron = this.frequency;
    }
  }

  get isCustomCron() {
    return this.frequency === "";
  }

  handleCron(event) {
    this.scheduleCron = event.target.value;
  }

  handleBatchSize(event) {
    this.batchSize = event.target.value;
  }

  handleDeleteAfter(event) {
    this.deleteAfterArchive = event.target.checked;
  }

  // ---- Step 5 ----
  handleEnableRestore(event) {
    if (this.restoreLockedOn) {
      return;
    }
    this.enableRestore = event.target.checked;
  }

  get restoreToggleDisabled() {
    return this.restoreLockedOn;
  }

  handleRestoreProfile(event) {
    this.restoreProfileId = event.detail.value;
  }

  get matchFieldOptions() {
    return this.uniqueFieldOptions;
  }

  handleMatchField(event) {
    this.matchField = event.detail.value;
  }

  handleOnConflict(event) {
    this.onConflict = event.detail.value;
  }

  handleReparentOwner(event) {
    this.reparentOwner = event.target.checked;
  }

  handleBypassAutomation(event) {
    this.bypassAutomation = event.target.checked;
  }

  // ---- Step navigation ----
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
  get isStep6() {
    return this.currentStep === "6";
  }
  get isFirstStep() {
    return this.currentStep === "1";
  }
  get isLastStep() {
    return this.currentStep === "6";
  }

  get nextDisabled() {
    if (this.isStep1) {
      return !this.sourceObject;
    }
    if (this.isStep2) {
      if (this.showAge && (!this.ageField || !(Number(this.ageThresholdDays) > 0))) {
        return true;
      }
      if (this.showFilter && !this.filterLogic) {
        return true;
      }
    }
    return false;
  }

  async handleNext() {
    const idx = Number(this.currentStep);
    if (idx === 1 && !this.isEditMode) {
      await this.loadFieldMetadata();
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

  // ---- Review summaries ----
  get criteriaSummary() {
    const parts = [];
    if (this.showAge) {
      parts.push(`Older than ${this.ageThresholdDays} day(s) on ${this.ageField}`);
    }
    if (this.showFilter) {
      parts.push(`Filter: ${this.filterLogic}`);
    }
    return parts.length ? parts.join(" AND ") : "None";
  }

  get scheduleSummary() {
    const freq = FREQUENCY_OPTIONS.find((o) => o.value === this.frequency);
    const label = freq && freq.value ? freq.label : "Manual / Custom";
    return `${label}${this.scheduleCron ? ` · ${this.scheduleCron}` : ""}`;
  }

  get restoreSummary() {
    if (!this.enableRestore) {
      return "No restore profile";
    }
    return `Match on ${this.matchField} · on conflict: ${this.onConflict}`;
  }

  get deleteSummary() {
    return this.deleteAfterArchive ? "Delete source after archive" : "Keep source records";
  }

  get activeSummary() {
    return this.isActive ? "Active" : "Inactive";
  }

  buildInput() {
    const input = {
      configId: this.recordId || null,
      configName: this.configName,
      sourceObject: this.sourceObject,
      isActive: this.isActive,
      criteriaType: this.criteriaType,
      ageField: this.showAge ? this.ageField : null,
      ageThresholdDays: this.showAge ? Number(this.ageThresholdDays) || null : null,
      filterLogic: this.showFilter ? this.filterLogic : null,
      listViewFields: this.selectedFieldNames,
      deleteAfterArchive: this.deleteAfterArchive,
      batchSize: Number(this.batchSize) || 200,
      scheduleCron: this.scheduleCron
    };
    if (this.enableRestore && this.matchField) {
      input.restoreProfile = {
        profileId: this.restoreProfileId || null,
        matchField: this.matchField,
        onConflict: this.onConflict,
        reparentOwner: this.reparentOwner,
        bypassAutomation: this.bypassAutomation
      };
    } else if (this.enableRestore && this.restoreProfileId) {
      input.restoreProfile = { profileId: this.restoreProfileId };
    }
    return input;
  }

  async handleGenerate() {
    this.isLoading = true;
    try {
      this.savedConfigId = await saveConfig({
        inputJson: JSON.stringify(this.buildInput())
      });
      this.saved = true;
      this.dispatchEvent(
        new ShowToastEvent({
          title: "Archive configuration saved",
          message: `Archiving configured for ${this.sourceObject}.`,
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
    this.isActive = true;
    this.configName = "";
    this.criteriaType = "Age";
    this.ageField = "";
    this.ageThresholdDays = 365;
    this.filterLogic = "";
    this.previewCount = null;
    this.previewError = "";
    this.allFields = [];
    this.dateFieldOptions = [];
    this.selectedFieldNames = [];
    this.fieldSearch = "";
    this.frequency = "0 0 1 * * ?";
    this.scheduleCron = "0 0 1 * * ?";
    this.batchSize = 200;
    this.deleteAfterArchive = false;
    this.enableRestore = false;
    this.restoreLockedOn = false;
    this.restoreProfileId = "";
    this.uniqueFieldOptions = [];
    this.matchField = "Id";
    this.onConflict = "Skip";
    this.reparentOwner = false;
    this.bypassAutomation = true;
    this.saved = false;
    this.savedConfigId = undefined;
  }

  handleCancel() {
    if (this.isEditMode) {
      this[NavigationMixin.Navigate]({
        type: "standard__recordPage",
        attributes: { recordId: this.recordId, actionName: "view" }
      });
    } else {
      this[NavigationMixin.Navigate]({
        type: "standard__objectPage",
        attributes: { objectApiName: "Archive_Config__c", actionName: "list" },
        state: { filterName: "Recent" }
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
        objectApiName: "Archive_Config__c",
        actionName: "view"
      }
    });
  }

  extractMessage(error) {
    if (error && error.body && error.body.message) {
      return error.body.message;
    }
    if (error && error.message) {
      return error.message;
    }
    return "Unknown error";
  }

  notifyError(title, error) {
    this.dispatchEvent(
      new ShowToastEvent({ title, message: this.extractMessage(error), variant: "error" })
    );
  }
}
