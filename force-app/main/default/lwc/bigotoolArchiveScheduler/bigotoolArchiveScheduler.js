import { LightningElement, api, wire } from "lwc";
import { ShowToastEvent } from "lightning/platformShowToastEvent";
import { refreshApex } from "@salesforce/apex";
import { getRecordNotifyChange } from "lightning/uiRecordApi";
import getStatus from "@salesforce/apex/BIGOTOOL_SchedulerController.getStatus";
import startSchedule from "@salesforce/apex/BIGOTOOL_SchedulerController.startSchedule";
import pauseSchedule from "@salesforce/apex/BIGOTOOL_SchedulerController.pauseSchedule";
import deleteSchedule from "@salesforce/apex/BIGOTOOL_SchedulerController.deleteSchedule";
import runNow from "@salesforce/apex/BIGOTOOL_SchedulerController.runNow";

export default class BigotoolArchiveScheduler extends LightningElement {
  @api recordId;

  status;
  error;
  isBusy = false;
  _wiredStatus;

  // Confirmation modal state.
  showConfirm = false;
  confirmTitle = "";
  confirmMessage = "";
  confirmAction;

  @wire(getStatus, { configId: "$recordId" })
  wiredStatus(result) {
    this._wiredStatus = result;
    if (result.data) {
      this.status = result.data;
      this.error = undefined;
    } else if (result.error) {
      this.error = this.extractMessage(result.error);
    }
  }

  // --- Derived UI state -------------------------------------------------------

  get isGenerated() {
    return this.status && this.status.isGenerated;
  }

  get notGenerated() {
    return this.status && !this.status.isGenerated;
  }

  get isActive() {
    return this.status && this.status.state === "Active";
  }

  get isPaused() {
    return this.status && this.status.state === "Paused";
  }

  get isNotScheduled() {
    return this.status && this.status.state === "NotScheduled";
  }

  get stateLabel() {
    if (!this.status) {
      return "";
    }
    switch (this.status.state) {
      case "Active":
        return "Active";
      case "Paused":
        return "Paused";
      default:
        return "Not Scheduled";
    }
  }

  get badgeClass() {
    const base = "slds-badge slds-m-left_x-small ";
    if (this.isActive) {
      return base + "slds-theme_success";
    }
    if (this.isPaused) {
      return base + "slds-theme_warning";
    }
    return base;
  }

  get statusIcon() {
    if (this.isActive) {
      return "utility:success";
    }
    if (this.isPaused) {
      return "utility:pause";
    }
    return "utility:clock";
  }

  get totalArchivedDisplay() {
    if (!this.status || this.status.totalArchived == null) {
      return "0";
    }
    return Number(this.status.totalArchived).toLocaleString();
  }

  get canStart() {
    return this.isGenerated && (this.isNotScheduled || this.isPaused);
  }

  get startLabel() {
    return this.isPaused ? "Resume Schedule" : "Start Schedule";
  }

  get disableActions() {
    return this.isBusy || !this.isGenerated;
  }

  // --- Actions ----------------------------------------------------------------

  handleStart() {
    this.runAction(startSchedule, "Schedule started.");
  }

  handlePauseRequest() {
    this.confirmTitle = "Pause Schedule";
    this.confirmMessage =
      "Pausing stops all future scheduled archive runs until you resume. Continue?";
    this.confirmAction = "pause";
    this.showConfirm = true;
  }

  handleDeleteRequest() {
    this.confirmTitle = "Delete Schedule";
    this.confirmMessage =
      "Deleting removes the scheduled job entirely. You can recreate it later with Start Schedule. Continue?";
    this.confirmAction = "delete";
    this.showConfirm = true;
  }

  handleRunRequest() {
    this.confirmTitle = "Run Archive Now";
    this.confirmMessage =
      "This launches the archive batch immediately against matching " +
      (this.status ? this.status.sourceObject : "source") +
      " records. Depending on your configuration this may permanently delete source records after archiving. Continue?";
    this.confirmAction = "run";
    this.showConfirm = true;
  }

  handleConfirmCancel() {
    this.showConfirm = false;
    this.confirmAction = undefined;
  }

  handleConfirmProceed() {
    const action = this.confirmAction;
    this.showConfirm = false;
    this.confirmAction = undefined;
    if (action === "pause") {
      this.runAction(pauseSchedule, "Schedule paused.");
    } else if (action === "delete") {
      this.runAction(deleteSchedule, "Schedule deleted.");
    } else if (action === "run") {
      this.runArchiveNow();
    }
  }

  async runAction(apexFn, successMessage) {
    this.isBusy = true;
    try {
      const updated = await apexFn({ configId: this.recordId });
      this.status = updated;
      this.toast("Success", successMessage, "success");
      await refreshApex(this._wiredStatus);
      getRecordNotifyChange([{ recordId: this.recordId }]);
    } catch (e) {
      this.toast("Action failed", this.extractMessage(e), "error");
    } finally {
      this.isBusy = false;
    }
  }

  async runArchiveNow() {
    this.isBusy = true;
    try {
      await runNow({ configId: this.recordId });
      this.toast(
        "Archive started",
        "The archive batch is running in the background. Stats refresh when it completes.",
        "success"
      );
      await refreshApex(this._wiredStatus);
    } catch (e) {
      this.toast("Run failed", this.extractMessage(e), "error");
    } finally {
      this.isBusy = false;
    }
  }

  handleRefresh() {
    refreshApex(this._wiredStatus);
  }

  // --- Utils ------------------------------------------------------------------

  toast(title, message, variant) {
    this.dispatchEvent(new ShowToastEvent({ title, message, variant }));
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
}
