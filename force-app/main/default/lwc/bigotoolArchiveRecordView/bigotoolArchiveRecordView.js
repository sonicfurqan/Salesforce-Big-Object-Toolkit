import { LightningElement, api, track } from "lwc";
import { NavigationMixin } from "lightning/navigation";
import { ShowToastEvent } from "lightning/platformShowToastEvent";
import getArchivedRecord from "@salesforce/apex/BIGOTOOL_ArchiveViewController.getArchivedRecord";
import canRestore from "@salesforce/apex/BIGOTOOL_ArchiveViewController.canRestore";
import restoreRecord from "@salesforce/apex/BIGOTOOL_ArchiveViewController.restoreRecord";

export default class BigotoolArchiveRecordView extends NavigationMixin(LightningElement) {
  @api configId;
  @api originalId;
  @api archivedDate;

  @track record;
  @track isLoading = false;
  @track error;

  @track canRestore = false;
  @track isRestoring = false;
  @track showNavigatePrompt = false;
  restoredRecordId;
  restoredObjectLabel;

  connectedCallback() {
    this.load();
    this.loadRestorePermission();
  }

  @api
  async refresh() {
    await this.load();
  }

  loadRestorePermission() {
    canRestore()
      .then((result) => {
        this.canRestore = result;
      })
      .catch(() => {
        this.canRestore = false;
      });
  }

  async load() {
    if (!this.configId || !this.originalId) {
      return;
    }
    this.isLoading = true;
    this.error = undefined;
    try {
      const result = await getArchivedRecord({
        configId: this.configId,
        originalId: this.originalId,
        archivedDate: this.archivedDate || null
      });
      this.record = this.decorate(result);
    } catch (e) {
      this.error = this.extractMessage(e);
      this.record = undefined;
    } finally {
      this.isLoading = false;
    }
  }

  async handleRestore() {
    this.isRestoring = true;
    try {
      const result = await restoreRecord({
        configId: this.configId,
        originalId: this.originalId,
        archivedDate: this.archivedDate || null
      });
      this.restoredRecordId = result.recordId;
      this.restoredObjectLabel = result.sourceObjectLabel || result.sourceObject;
      this.dispatchEvent(
        new ShowToastEvent({
          title: "Record restored",
          message: `The record was restored to ${this.restoredObjectLabel}.`,
          variant: "success"
        })
      );
      this.showNavigatePrompt = true;
    } catch (e) {
      this.dispatchEvent(
        new ShowToastEvent({
          title: "Restore failed",
          message: this.extractMessage(e),
          variant: "error"
        })
      );
    } finally {
      this.isRestoring = false;
    }
  }

  handleNavigateYes() {
    this.showNavigatePrompt = false;
    this[NavigationMixin.Navigate]({
      type: "standard__recordPage",
      attributes: {
        recordId: this.restoredRecordId,
        actionName: "view"
      }
    });
  }

  handleNavigateNo() {
    this.showNavigatePrompt = false;
  }

  decorate(result) {
    if (!result) {
      return result;
    }
    const fields = (result.fields || []).map((f) => {
      const type = (f.type || "STRING").toUpperCase();
      return {
        ...f,
        key: f.apiName,
        isBoolean: type === "BOOLEAN",
        isNumber: ["DOUBLE", "INTEGER", "LONG"].includes(type),
        isCurrency: type === "CURRENCY",
        isPercent: type === "PERCENT",
        isDate: type === "DATE",
        isDateTime: type === "DATETIME",
        isEmail: type === "EMAIL",
        isPhone: type === "PHONE",
        isUrl: type === "URL",
        isText: this.isPlainText(type),
        boolValue: f.value === true || f.value === "true",
        boolIcon: f.value === true || f.value === "true" ? "utility:check" : "utility:close",
        boolText: f.value === true || f.value === "true" ? "Yes" : "No",
        numberValue: f.value === null || f.value === undefined ? null : Number(f.value),
        empty: f.value === null || f.value === undefined || f.value === ""
      };
    });
    return { ...result, fields };
  }

  isPlainText(type) {
    return ![
      "BOOLEAN",
      "DOUBLE",
      "INTEGER",
      "LONG",
      "CURRENCY",
      "PERCENT",
      "DATE",
      "DATETIME",
      "EMAIL",
      "PHONE",
      "URL"
    ].includes(type);
  }

  get hasFields() {
    return this.record && this.record.fields && this.record.fields.length > 0;
  }

  get showRestore() {
    return this.canRestore && this.record;
  }

  extractMessage(error) {
    if (error && error.body && error.body.message) {
      return error.body.message;
    }
    if (error && error.message) {
      return error.message;
    }
    return "Unable to load archived record.";
  }
}
