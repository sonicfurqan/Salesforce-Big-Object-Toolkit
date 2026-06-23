import { LightningElement, api, track } from "lwc";
import getConfigIdForBigObject from "@salesforce/apex/BIGOTOOL_ArchiveViewController.getConfigIdForBigObject";
import getListConfig from "@salesforce/apex/BIGOTOOL_ArchiveViewController.getListConfig";
import getRecords from "@salesforce/apex/BIGOTOOL_ArchiveViewController.getRecords";
import canExport from "@salesforce/apex/BIGOTOOL_ArchiveViewController.canExport";
import exportCsv from "@salesforce/apex/BIGOTOOL_ArchiveViewController.exportCsv";

const PAGE_SIZE = 50;

export default class BigotoolArchiveListView extends LightningElement {
  // When placed on an Archive_Config__c record page, recordId is the config Id.
  @api recordId;
  // Allows the component to be configured explicitly (App/Home pages).
  @api configId;
  // Allows the component to be driven by a Big Object API name (generated tab).
  @api bigObjectApiName;

  @track columns = [];
  @track rows = [];
  @track title = "Archived Records";
  @track objectName = "";
  @track isLoading = false;
  @track error;
  @track hasMore = false;

  nextOffset = 0;
  resolvedConfigId;
  bigObjectApiName;

  // Filters
  @track originalIdFilter = "";
  @track fromDate;
  @track toDate;
  @track showFilters = false;

  // Record viewer modal
  @track showRecordModal = false;
  @track selectedOriginalId;
  @track selectedArchivedDate;

  // Export
  @track canExportData = false;
  @track showExportModal = false;
  @track isExporting = false;

  get effectiveConfigId() {
    return this.configId || this.recordId || this.resolvedConfigId;
  }

  connectedCallback() {
    if (this.configId || this.recordId || this.bigObjectApiName) {
      this.init();
    }
  }

  async init() {
    this.isLoading = true;
    this.error = undefined;
    try {
      // When only a Big Object name is supplied (e.g. a generated tab), resolve
      // its driving Archive Config first.
      if (!this.configId && !this.recordId && this.bigObjectApiName) {
        this.resolvedConfigId = await getConfigIdForBigObject({
          bigObjectApiName: this.bigObjectApiName
        });
      }
      const cfg = await getListConfig({ configId: this.effectiveConfigId });
      this.title = cfg.title;
      this.objectName = cfg.objectName || cfg.bigObjectName || "";
      this.columns = this.buildColumns(cfg.columns);
      try {
        this.canExportData = await canExport();
      } catch (e) {
        this.canExportData = false;
      }
      await this.loadRecords(true);
    } catch (e) {
      this.error = this.extractMessage(e);
    } finally {
      this.isLoading = false;
    }
  }

  buildColumns(cols) {
    const dynamic = (cols || []).map((c) => ({
      label: c.label,
      fieldName: c.apiName,
      type: c.type || "text",
      wrapText: false
    }));
    // Leading "Original Record Id" link opens the dynamic record viewer.
    const idColumn = {
      label: "Original Record Id",
      fieldName: "originalId",
      type: "button",
      initialWidth: 200,
      typeAttributes: {
        label: { fieldName: "originalId" },
        variant: "base",
        name: "view"
      }
    };
    const dateColumn = {
      label: "Archived Date",
      fieldName: "archivedDate",
      type: "date",
      typeAttributes: {
        year: "numeric",
        month: "short",
        day: "2-digit",
        hour: "2-digit",
        minute: "2-digit"
      }
    };
    return [idColumn, dateColumn, ...dynamic];
  }

  async loadRecords(reset) {
    this.isLoading = true;
    this.error = undefined;
    try {
      const page = await getRecords({
        configId: this.effectiveConfigId,
        originalIdFilter: this.originalIdFilter || null,
        fromDate: this.fromDate || null,
        toDate: this.toDate || null,
        pageSize: PAGE_SIZE,
        offset: reset ? 0 : this.nextOffset
      });
      const flattened = (page.rows || []).map((r) => this.flatten(r));
      this.rows = reset ? flattened : [...this.rows, ...flattened];
      this.hasMore = page.hasMore === true;
      this.nextOffset = page.nextOffset != null ? page.nextOffset : this.rows.length;
    } catch (e) {
      this.error = this.extractMessage(e);
    } finally {
      this.isLoading = false;
    }
  }

  flatten(row) {
    const flat = {
      originalId: row.originalId,
      archivedDate: row.archivedDate,
      rowKey: row.rowKey
    };
    if (row.values) {
      Object.keys(row.values).forEach((k) => {
        flat[k] = row.values[k];
      });
    }
    return flat;
  }

  // ---- Filters ----
  handleOriginalIdChange(event) {
    this.originalIdFilter = event.target.value;
  }

  handleFromDateChange(event) {
    this.fromDate = event.target.value;
  }

  handleToDateChange(event) {
    this.toDate = event.target.value;
  }

  handleApplyFilters() {
    this.nextOffset = 0;
    this.loadRecords(true);
  }

  handleClearFilters() {
    this.originalIdFilter = "";
    this.fromDate = undefined;
    this.toDate = undefined;
    this.nextOffset = 0;
    this.loadRecords(true);
  }

  handleRefresh() {
    this.nextOffset = 0;
    this.loadRecords(true);
  }

  handleLoadMore() {
    this.loadRecords(false);
  }

  handleToggleFilters() {
    this.showFilters = !this.showFilters;
  }

  // ---- Row action: open record viewer ----
  handleRowAction(event) {
    const row = event.detail.row;
    this.selectedOriginalId = row.originalId;
    this.selectedArchivedDate = row.archivedDate;
    this.showRecordModal = true;
  }

  closeRecordModal() {
    this.showRecordModal = false;
    this.selectedOriginalId = undefined;
    this.selectedArchivedDate = undefined;
  }

  // ---- Export ----
  handleExportClick() {
    this.showExportModal = true;
  }

  closeExportModal() {
    this.showExportModal = false;
  }

  handleExportLoaded() {
    const csv = this.buildLoadedCsv();
    this.downloadCsv(csv, `${this.objectName || "archive"}_loaded.csv`);
    this.showExportModal = false;
  }

  async handleExportFull() {
    this.isExporting = true;
    this.error = undefined;
    try {
      const csv = await exportCsv({
        configId: this.effectiveConfigId,
        originalIdFilter: this.originalIdFilter || null,
        fromDate: this.fromDate || null,
        toDate: this.toDate || null
      });
      this.downloadCsv(csv, `${this.objectName || "archive"}_full.csv`);
      this.showExportModal = false;
    } catch (e) {
      this.error = this.extractMessage(e);
    } finally {
      this.isExporting = false;
    }
  }

  buildLoadedCsv() {
    const header = ["Original Record Id", "Archived Date"];
    this.columns
      .filter((c) => c.fieldName !== "originalId" && c.fieldName !== "archivedDate")
      .forEach((c) => header.push(c.label));
    const lines = [header.map((h) => this.escapeCsv(h)).join(",")];

    const dataCols = this.columns.filter(
      (c) => c.fieldName !== "originalId" && c.fieldName !== "archivedDate"
    );
    this.rows.forEach((r) => {
      const cells = [
        this.escapeCsv(r.originalId),
        this.escapeCsv(r.archivedDate == null ? "" : String(r.archivedDate))
      ];
      dataCols.forEach((c) => {
        const v = r[c.fieldName];
        cells.push(this.escapeCsv(v == null ? "" : String(v)));
      });
      lines.push(cells.join(","));
    });
    return lines.join("\n");
  }

  escapeCsv(value) {
    if (value == null) {
      return "";
    }
    const s = String(value);
    if (s.indexOf('"') >= 0 || s.indexOf(",") >= 0 || s.indexOf("\n") >= 0 || s.indexOf("\r") >= 0) {
      return '"' + s.replace(/"/g, '""') + '"';
    }
    return s;
  }

  downloadCsv(csv, fileName) {



    // Encode the CSV content into a Data URL scheme
    const dataUrl = "data:text/csv;charset=utf-8," + encodeURIComponent("\uFEFF" + csv);

    const link = document.createElement("a");
    link.href = dataUrl;
    link.download = fileName;

    // Target body appending is required for cross-browser LWC compatibility
    document.body.appendChild(link);
    link.click();
    document.body.removeChild(link);


  }

  get hasRows() {
    return this.rows && this.rows.length > 0;
  }

  get hasColumns() {
    return this.columns && this.columns.length > 0;
  }

  get rowCountLabel() {
    return `${this.rows.length} record${this.rows.length === 1 ? "" : "s"}`;
  }

  get showFiltersClass() {
    return this.showFilters ? "slds-is-active" : "";
  }

  get exportFullDisabled() {
    return this.isExporting || !this.canExportData;
  }

  extractMessage(error) {
    if (error && error.body && error.body.message) {
      return error.body.message;
    }
    if (error && error.message) {
      return error.message;
    }
    return "Unable to load archived records.";
  }
}
