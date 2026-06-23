import { LightningElement, wire, track } from 'lwc';
import { refreshApex } from '@salesforce/apex';
import getDashboard from '@salesforce/apex/BIGOTOOL_DashboardController.getDashboard';

const JOB_COLUMNS = [
  { label: 'Configuration', fieldName: 'configName', type: 'text', wrapText: true },
  { label: 'Job Type', fieldName: 'jobType', type: 'text', initialWidth: 120 },
  {
    label: 'Status',
    fieldName: 'status',
    type: 'text',
    initialWidth: 120,
    cellAttributes: { class: { fieldName: 'statusClass' } }
  },
  { label: 'Processed', fieldName: 'recordsProcessed', type: 'number', initialWidth: 120 },
  { label: 'Failed', fieldName: 'recordsFailed', type: 'number', initialWidth: 100 },
  {
    label: 'Run Date/Time',
    fieldName: 'runDateTime',
    type: 'date',
    initialWidth: 180,
    typeAttributes: {
      year: 'numeric',
      month: 'short',
      day: '2-digit',
      hour: '2-digit',
      minute: '2-digit'
    }
  },
  { label: 'Error', fieldName: 'errorSummary', type: 'text', wrapText: true }
];

export default class BigotoolDashboard extends LightningElement {
  @track data;
  jobColumns = JOB_COLUMNS;
  loading = true;
  error;
  wiredResult;

  @wire(getDashboard)
  wired(result) {
    this.wiredResult = result;
    const { data, error } = result;
    if (data) {
      this.data = this.decorate(data);
      this.error = undefined;
    } else if (error) {
      this.error = this.reduceError(error);
      this.data = undefined;
    }
    this.loading = false;
  }

  decorate(raw) {
    const d = JSON.parse(JSON.stringify(raw));
    if (d.jobs && d.jobs.recent) {
      d.jobs.recent = d.jobs.recent.map((r) => ({
        ...r,
        statusClass: this.statusClass(r.status)
      }));
    }
    return d;
  }

  statusClass(status) {
    const s = (status || '').toLowerCase();
    if (s === 'failed' || s === 'error') {
      return 'slds-text-color_error';
    }
    if (s === 'success' || s === 'completed') {
      return 'slds-text-color_success';
    }
    return '';
  }

  handleRefresh() {
    this.loading = true;
    refreshApex(this.wiredResult).finally(() => {
      this.loading = false;
    });
  }

  get hasData() {
    return !!this.data;
  }

  get config() {
    return this.data ? this.data.config : {};
  }

  get jobs() {
    return this.data ? this.data.jobs : {};
  }

  get toggles() {
    return this.data ? this.data.toggles : {};
  }

  get generatedAt() {
    return this.data ? this.data.generatedAt : null;
  }

  get hasRecentJobs() {
    return this.data && this.data.jobs && this.data.jobs.recent && this.data.jobs.recent.length > 0;
  }

  get hasTypeStats() {
    return this.data && this.data.jobs && this.data.jobs.byType && this.data.jobs.byType.length > 0;
  }

  get successRate() {
    const j = this.jobs;
    if (!j || !j.totalRuns) {
      return '—';
    }
    const rate = (j.successRuns / j.totalRuns) * 100;
    return `${rate.toFixed(0)}%`;
  }

  get masterSwitchLabel() {
    return this.toggles && this.toggles.masterSwitch ? 'ON' : 'OFF';
  }

  get masterSwitchClass() {
    const base = 'slds-badge slds-m-left_x-small ';
    return base + (this.toggles && this.toggles.masterSwitch ? 'slds-theme_success' : 'slds-theme_error');
  }

  get loggingLabel() {
    return this.toggles && this.toggles.loggingEnabled ? 'Enabled' : 'Disabled';
  }

  get archivingLabel() {
    return this.toggles && this.toggles.archivingEnabled ? 'Enabled' : 'Disabled';
  }

  get loggingClass() {
    return this.pillClass(this.toggles && this.toggles.loggingEnabled);
  }

  get archivingClass() {
    return this.pillClass(this.toggles && this.toggles.archivingEnabled);
  }

  pillClass(on) {
    const base = 'slds-badge ';
    return base + (on ? 'slds-theme_success' : 'slds-theme_warning');
  }

  reduceError(error) {
    if (Array.isArray(error && error.body)) {
      return error.body.map((e) => e.message).join(', ');
    }
    if (error && error.body && error.body.message) {
      return error.body.message;
    }
    if (error && typeof error.message === 'string') {
      return error.message;
    }
    return 'Unable to load the dashboard.';
  }
}
