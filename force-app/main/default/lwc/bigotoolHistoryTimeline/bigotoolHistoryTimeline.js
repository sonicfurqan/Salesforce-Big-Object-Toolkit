import { LightningElement, api, track } from "lwc";
import { ShowToastEvent } from "lightning/platformShowToastEvent";
import getHistory from "@salesforce/apex/BIGOTOOL_HistoryController.getHistory";

const PAGE_SIZE = 50;

export default class BigotoolHistoryTimeline extends LightningElement {
  @api recordId;
  @api title = "Field History";
  @api pageSize = PAGE_SIZE;

  @track entries = [];
  @track tableRows = [];
  allRows = [];
  rowKeys = new Set();

  objectApiName;
  cursor;
  hasMore = false;
  loading = false;
  error;
  canExport = false;

  // 'timeline' | 'table'
  viewMode = "timeline";

  // filter state
  fieldFilter = "";
  changeTypeFilter = "";
  userFilter = "";

  tableColumns = [
    { label: "Field", fieldName: "fieldLabel", type: "text", wrapText: true },
    { label: "Change Type", fieldName: "changeType", type: "text", initialWidth: 130 },
    { label: "Old Value", fieldName: "oldValue", type: "text", wrapText: true },
    { label: "New Value", fieldName: "newValue", type: "text", wrapText: true },
    { label: "Changed By", fieldName: "changedByName", type: "text", initialWidth: 160 },
    {
      label: "Changed Date/Time",
      fieldName: "changedDateTime",
      type: "date",
      initialWidth: 180,
      typeAttributes: {
        year: "numeric",
        month: "short",
        day: "2-digit",
        hour: "2-digit",
        minute: "2-digit"
      }
    }
  ];

  connectedCallback() {
    this.loadFirstPage();
  }

  get effectivePageSize() {
    const n = parseInt(this.pageSize, 10);
    return Number.isFinite(n) && n > 0 ? n : PAGE_SIZE;
  }

  get isTimelineView() {
    return this.viewMode === "timeline";
  }

  get isTableView() {
    return this.viewMode === "table";
  }

  get hasEntries() {
    return this.entries.length > 0;
  }

  get isEmpty() {
    return !this.loading && !this.error && this.allRows.length === 0;
  }

  get showLoadMore() {
    return this.hasMore && !this.loading;
  }

  get showExport() {
    return this.canExport && this.allRows.length > 0;
  }

  get totalLoadedLabel() {
    const n = this.allRows.length;
    return `${n} change${n === 1 ? "" : "s"} loaded`;
  }

  get fieldFilterOptions() {
    const seen = new Map();
    this.allRows.forEach((r) => {
      if (!seen.has(r.fieldApiName)) {
        seen.set(r.fieldApiName, r.fieldLabel || r.fieldApiName);
      }
    });
    const options = [{ label: "All fields", value: "" }];
    [...seen.entries()]
      .sort((a, b) => a[1].localeCompare(b[1]))
      .forEach(([value, label]) => options.push({ label, value }));
    return options;
  }

  get changeTypeOptions() {
    const set = new Set(this.allRows.map((r) => r.changeType).filter(Boolean));
    const options = [{ label: "All types", value: "" }];
    [...set].sort().forEach((t) => options.push({ label: t, value: t }));
    return options;
  }

  get userOptions() {
    const set = new Set(this.allRows.map((r) => r.changedByName).filter(Boolean));
    const options = [{ label: "All users", value: "" }];
    [...set].sort().forEach((u) => options.push({ label: u, value: u }));
    return options;
  }

  loadFirstPage() {
    this.allRows = [];
    this.rowKeys = new Set();
    this.entries = [];
    this.tableRows = [];
    this.cursor = undefined;
    this.hasMore = false;
    this.error = undefined;
    this.fetchPage(null);
  }

  loadMore() {
    if (this.hasMore && !this.loading) {
      this.fetchPage(this.cursor);
    }
  }

  fetchPage(cursor) {
    if (!this.recordId) {
      return;
    }
    this.loading = true;
    getHistory({ recordId: this.recordId, pageSize: this.effectivePageSize, cursor })
      .then((page) => {
        this.objectApiName = page.objectApiName;
        this.canExport = page.canExport;
        let added = 0;
        (page.rows || []).forEach((row) => {
          if (!this.rowKeys.has(row.rowKey)) {
            this.rowKeys.add(row.rowKey);
            this.allRows.push(row);
            added += 1;
          }
        });
        this.cursor = page.nextCursor;
        // Guard against a no-progress cursor (all duplicates) to avoid loops.
        this.hasMore = page.hasMore && added > 0;
        // Ordering is done here in the component (the Apex query no longer uses
        // ORDER BY): newest first, then by sequence ascending within a moment.
        this.sortRows();
        this.rebuildEntries();
        this.error = undefined;
      })
      .catch((e) => {
        this.error = this.reduceError(e);
      })
      .finally(() => {
        this.loading = false;
      });
  }

  handleFieldFilter(event) {
    this.fieldFilter = event.detail.value;
    this.rebuildEntries();
  }

  handleChangeTypeFilter(event) {
    this.changeTypeFilter = event.detail.value;
    this.rebuildEntries();
  }

  handleUserFilter(event) {
    this.userFilter = event.detail.value;
    this.rebuildEntries();
  }

  handleRefresh() {
    this.loadFirstPage();
  }

  handleViewToggle(event) {
    this.viewMode = event.target.value;
  }

  get timelineButtonVariant() {
    return this.viewMode === "timeline" ? "brand" : "neutral";
  }

  get tableButtonVariant() {
    return this.viewMode === "table" ? "brand" : "neutral";
  }

  sortRows() {
    this.allRows.sort((a, b) => {
      const ta = a.changedDateTime ? new Date(a.changedDateTime).getTime() : 0;
      const tb = b.changedDateTime ? new Date(b.changedDateTime).getTime() : 0;
      if (tb !== ta) {
        return tb - ta; // newest first
      }
      const sa = a.sequence == null ? 0 : a.sequence;
      const sb = b.sequence == null ? 0 : b.sequence;
      return sa - sb; // ascending within the same instant
    });
  }

  applyFilters() {
    return this.allRows.filter((r) => {
      if (this.fieldFilter && r.fieldApiName !== this.fieldFilter) {
        return false;
      }
      if (this.changeTypeFilter && r.changeType !== this.changeTypeFilter) {
        return false;
      }
      if (this.userFilter && r.changedByName !== this.userFilter) {
        return false;
      }
      return true;
    });
  }

  rebuildEntries() {
    const filtered = this.applyFilters();

    // Flat rows for the table view.
    this.tableRows = filtered.map((r) => ({
      id: r.rowKey,
      fieldLabel: r.masked ? `${r.fieldLabel} (masked)` : r.fieldLabel,
      changeType: r.changeType,
      oldValue: r.oldValue,
      newValue: r.newValue,
      changedByName: r.changedByName,
      changedDateTime: r.changedDateTime
    }));

    // Grouped entries for the timeline view.
    const groups = new Map();
    filtered.forEach((r) => {
      const groupKey = `${r.transactionId || ""}|${r.changedDateTime}|${r.changedByUserId || ""}`;
      if (!groups.has(groupKey)) {
        groups.set(groupKey, {
          key: groupKey,
          changedDateTime: r.changedDateTime,
          changedByName: r.changedByName,
          changeType: r.changeType,
          changes: []
        });
      }
      groups.get(groupKey).changes.push({
        key: r.rowKey,
        fieldApiName: r.fieldApiName,
        fieldLabel: r.fieldLabel,
        oldValue: r.oldValue,
        newValue: r.newValue,
        masked: r.masked
      });
    });

    this.entries = [...groups.values()].sort((a, b) => new Date(b.changedDateTime) - new Date(a.changedDateTime));
  }

  handleExport() {
    if (!this.canExport) {
      return;
    }
    const header = [
      "RecordId",
      "Object",
      "Field",
      "OldValue",
      "NewValue",
      "Masked",
      "ChangeType",
      "ChangedBy",
      "ChangedDateTime",
      "TransactionId"
    ];
    const lines = [header.map(this.csvCell).join(",")];
    this.allRows.forEach((r) => {
      lines.push(
        [
          this.recordId,
          this.objectApiName,
          r.fieldLabel,
          r.oldValue,
          r.newValue,
          r.masked,
          r.changeType,
          r.changedByName,
          r.changedDateTime,
          r.transactionId
        ]
          .map(this.csvCell)
          .join(",")
      );
    });
    // UTF-8 BOM for Excel compatibility.
    const csv = "\uFEFF" + lines.join("\r\n");

    // Encode the CSV content into a Data URL scheme
    const dataUrl = "data:text/csv;charset=utf-8," + encodeURIComponent(csv);

    const link = document.createElement("a");
    link.href = dataUrl;
    link.download = `field-history-${this.recordId}.csv`;

    // Target body appending is required for cross-browser LWC compatibility
    document.body.appendChild(link);
    link.click();
    document.body.removeChild(link);
    this.dispatchEvent(
      new ShowToastEvent({
        title: "Export ready",
        message: `Exported ${this.allRows.length} loaded change(s). For the full archive across millions of rows, use the bulk export service.`,
        variant: "success"
      })
    );
  }

  csvCell(value) {
    if (value === null || value === undefined) {
      return "";
    }
    const s = String(value);
    if (/[",\r\n]/.test(s)) {
      return `"${s.replace(/"/g, '""')}"`;
    }
    return s;
  }

  reduceError(error) {
    if (Array.isArray(error && error.body)) {
      return error.body.map((e) => e.message).join(", ");
    }
    if (error && error.body && error.body.message) {
      return error.body.message;
    }
    if (error && typeof error.message === "string") {
      return error.message;
    }
    return "Unable to load field history.";
  }
}
