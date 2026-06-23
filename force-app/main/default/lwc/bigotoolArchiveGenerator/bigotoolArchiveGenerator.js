import { LightningElement, api, wire } from "lwc";
import { ShowToastEvent } from "lightning/platformShowToastEvent";
import { CloseActionScreenEvent } from "lightning/actions";
import { getRecordNotifyChange } from "lightning/uiRecordApi";
import getConfigSummary from "@salesforce/apex/BIGOTOOL_GenerationController.getConfigSummary";
import generate from "@salesforce/apex/BIGOTOOL_GenerationController.generate";

export default class BigotoolArchiveGenerator extends LightningElement {
  @api recordId;

  isLoading = true;
  isGenerating = false;
  config;
  result;
  errorMessage;

  @wire(getConfigSummary, { configId: "$recordId" })
  wiredConfig({ data, error }) {
    this.isLoading = false;
    if (data) {
      this.config = data;
    } else if (error) {
      this.errorMessage = this.extractMessage(error);
    }
  }

  get alreadyGenerated() {
    return this.config && this.config.Generation_Status__c === "Generated";
  }

  get showConfirm() {
    return !this.isLoading && !this.result && !this.alreadyGenerated && !this.errorMessage;
  }

  get showResult() {
    return !!this.result;
  }

  get sourceObject() {
    return this.config ? this.config.Source_Object__c : "";
  }

  get bigObjectApiName() {
    return this.config ? this.config.Big_Object_Api_Name__c : "";
  }

  get deletesSource() {
    return this.config && this.config.Delete_After_Archive__c;
  }

  get resultVariant() {
    return this.result && this.result.success ? "success" : "error";
  }

  get resultIcon() {
    return this.result && this.result.success
      ? "utility:success"
      : "utility:error";
  }

  get hasWarnings() {
    return this.result && this.result.warnings && this.result.warnings.length > 0;
  }

  async handleConfirm() {
    this.isGenerating = true;
    this.errorMessage = undefined;
    try {
      const response = await generate({ configId: this.recordId });
      this.result = response;
      getRecordNotifyChange([{ recordId: this.recordId }]);
      this.dispatchEvent(
        new ShowToastEvent({
          title: response.success ? "Generation complete" : "Generation finished with errors",
          message: response.message,
          variant: response.success ? "success" : "warning"
        })
      );
    } catch (e) {
      this.errorMessage = this.extractMessage(e);
      this.dispatchEvent(
        new ShowToastEvent({
          title: "Generation failed",
          message: this.errorMessage,
          variant: "error"
        })
      );
    } finally {
      this.isGenerating = false;
    }
  }

  handleCancel() {
    this.dispatchEvent(new CloseActionScreenEvent());
  }

  handleClose() {
    this.dispatchEvent(new CloseActionScreenEvent());
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
