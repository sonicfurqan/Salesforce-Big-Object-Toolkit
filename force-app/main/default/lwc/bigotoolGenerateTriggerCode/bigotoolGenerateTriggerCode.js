import { LightningElement, api } from "lwc";
import { ShowToastEvent } from "lightning/platformShowToastEvent";
import { CloseActionScreenEvent } from "lightning/actions";
import generateTriggerCode from "@salesforce/apex/BIGOTOOL_FieldLogWizardController.generateTriggerCode";
import getTriggerCodeStatus from "@salesforce/apex/BIGOTOOL_FieldLogWizardController.getTriggerCodeStatus";

export default class BigotoolGenerateTriggerCode extends LightningElement {
  @api recordId;

  isLoading = false;
  confirmed = false;
  result;
  _statusLoaded = false;

  renderedCallback() {
    if (this.recordId && !this._statusLoaded) {
      this._statusLoaded = true;
      this.loadStatus();
    }
  }

  async loadStatus() {
    this.isLoading = true;
    try {
      const status = await getTriggerCodeStatus({ configId: this.recordId });
      if (status && status.alreadyGenerated) {
        // Code was already generated previously — skip the confirmation and
        // show the how-to screen directly.
        this.result = status;
      }
    } catch (e) {
      this.notifyError("Unable to load trigger status", e);
    } finally {
      this.isLoading = false;
    }
  }

  get showConfirm() {
    return !this.confirmed && !this.result;
  }

  get showResult() {
    return !!this.result;
  }

  async handleConfirm() {
    this.confirmed = true;
    this.isLoading = true;
    try {
      this.result = await generateTriggerCode({ configId: this.recordId });
      this.dispatchEvent(
        new ShowToastEvent({
          title: "Trigger code generated",
          message: `Trigger ${this.result.triggerName} is ready to add for ${this.result.objectApiName}.`,
          variant: "success"
        })
      );
    } catch (e) {
      this.confirmed = false;
      this.notifyError("Unable to generate trigger code", e);
    } finally {
      this.isLoading = false;
    }
  }

  handleCancel() {
    this.dispatchEvent(new CloseActionScreenEvent());
  }

  handleClose() {
    this.dispatchEvent(new CloseActionScreenEvent());
  }

  async handleCopy() {
    if (!this.result) {
      return;
    }
    try {
      if (navigator.clipboard && navigator.clipboard.writeText) {
        await navigator.clipboard.writeText(this.result.triggerBody);
        this.dispatchEvent(
          new ShowToastEvent({
            title: "Copied",
            message: "Trigger code copied to clipboard.",
            variant: "success"
          })
        );
      } else {
        this.selectCodeText();
      }
      // eslint-disable-next-line no-unused-vars
    } catch (error) {
      this.selectCodeText();
    }
  }

  selectCodeText() {
    const el = this.template.querySelector(".code-block");
    if (el) {
      const range = document.createRange();
      range.selectNodeContents(el);
      const sel = window.getSelection();
      sel.removeAllRanges();
      sel.addRange(range);
    }
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
