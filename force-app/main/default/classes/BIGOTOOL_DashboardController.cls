/**
 * Read API for the Big Object Tooling monitoring dashboard (bigotoolDashboard).
 *
 * Aggregates three sources:
 *   - Field_Log_Config__c / Archive_Config__c   (config coverage, standard SOQL)
 *   - Archive_Job_Log__b                          (job run history, Big Object)
 *   - BIGOTOOL_Settings__c                        (global kill-switch state)
 *
 * Big Objects do not support aggregate SOQL (no COUNT/GROUP BY) and are not
 * committed/queryable in test context, so the job rows are read with a bounded
 * LIMIT and folded in Apex via the @TestVisible summarizeJobs() method, which is
 * unit-tested with in-memory rows.
 */
public with sharing class BIGOTOOL_DashboardController {
  @TestVisible
  private static final Integer JOB_SCAN_LIMIT = 2000;
  @TestVisible
  private static final Integer RECENT_LIMIT = 10;

  public class ConfigSummary {
    @AuraEnabled
    public Integer logTotal = 0;
    @AuraEnabled
    public Integer logActive = 0;
    @AuraEnabled
    public Integer logTriggered = 0;
    @AuraEnabled
    public Integer archiveTotal = 0;
    @AuraEnabled
    public Integer archiveActive = 0;
  }

  public class JobTypeStat {
    @AuraEnabled
    public String jobType;
    @AuraEnabled
    public Integer runs = 0;
    @AuraEnabled
    public Long recordsProcessed = 0;
    @AuraEnabled
    public Long recordsFailed = 0;
    public JobTypeStat(String jobType) {
      this.jobType = jobType;
    }
  }

  public class JobRow {
    @AuraEnabled
    public String configName;
    @AuraEnabled
    public String jobType;
    @AuraEnabled
    public String status;
    @AuraEnabled
    public Long recordsProcessed;
    @AuraEnabled
    public Long recordsFailed;
    @AuraEnabled
    public Datetime runDateTime;
    @AuraEnabled
    public String errorSummary;
    @AuraEnabled
    public String rowKey;
  }

  public class JobSummary {
    @AuraEnabled
    public Integer totalRuns = 0;
    @AuraEnabled
    public Integer successRuns = 0;
    @AuraEnabled
    public Integer failedRuns = 0;
    @AuraEnabled
    public Long totalProcessed = 0;
    @AuraEnabled
    public Long totalFailed = 0;
    @AuraEnabled
    public List<JobTypeStat> byType = new List<JobTypeStat>();
    @AuraEnabled
    public List<JobRow> recent = new List<JobRow>();
  }

  public class DashboardData {
    @AuraEnabled
    public Boolean remoteSiteConfigured = true;
    @AuraEnabled
    public String requiredRemoteSiteUrl;
    @AuraEnabled
    public ConfigSummary config = new ConfigSummary();
    @AuraEnabled
    public JobSummary jobs = new JobSummary();
    @AuraEnabled
    public BIGOTOOL_Toggles.SettingsState toggles = new BIGOTOOL_Toggles.SettingsState();
    @AuraEnabled
    public Datetime generatedAt;
  }

  @AuraEnabled(cacheable=true)
  public static DashboardData getDashboard() {
    DashboardData data = new DashboardData();
    BIGOTOOL_RemoteSiteGuard.RemoteSiteCheck remoteSiteCheck = BIGOTOOL_RemoteSiteGuard.checkCurrentOrg();
    data.remoteSiteConfigured = remoteSiteCheck.isConfigured;
    data.requiredRemoteSiteUrl = remoteSiteCheck.requiredUrl;
    data.generatedAt = Datetime.now();
    if (!data.remoteSiteConfigured) {
      return data;
    }
    data.config = loadConfigSummary();
    data.jobs = summarizeJobs(loadJobRecords());
    data.toggles = loadToggles();
    return data;
  }

  private static ConfigSummary loadConfigSummary() {
    ConfigSummary cs = new ConfigSummary();

    for (AggregateResult ar : [
      SELECT Is_Active__c active, Trigger_Generated__c triggered, COUNT(Id) cnt
      FROM Field_Log_Config__c
      GROUP BY Is_Active__c, Trigger_Generated__c
    ]) {
      Integer cnt = (Integer) ar.get('cnt');
      cs.logTotal += cnt;
      if (ar.get('active') == true) {
        cs.logActive += cnt;
      }
      if (ar.get('triggered') == true) {
        cs.logTriggered += cnt;
      }
    }

    for (AggregateResult ar : [
      SELECT Is_Active__c active, COUNT(Id) cnt
      FROM Archive_Config__c
      GROUP BY Is_Active__c
    ]) {
      Integer cnt = (Integer) ar.get('cnt');
      cs.archiveTotal += cnt;
      if (ar.get('active') == true) {
        cs.archiveActive += cnt;
      }
    }

    return cs;
  }

  private static List<Archive_Job_Log__b> loadJobRecords() {
    // Big Object DML is not committed in test context, so this returns empty
    // during tests; summarizeJobs is exercised separately with in-memory rows.
    return [
      SELECT
        ConfigName__c,
        JobType__c,
        Status__c,
        RecordsProcessed__c,
        RecordsFailed__c,
        RunDateTime__c,
        ErrorSummary__c
      FROM Archive_Job_Log__b
      LIMIT :JOB_SCAN_LIMIT
    ];
  }

  @TestVisible
  private static JobSummary summarizeJobs(List<Archive_Job_Log__b> records) {
    JobSummary summary = new JobSummary();
    if (records == null || records.isEmpty()) {
      return summary;
    }

    Map<String, JobTypeStat> typeMap = new Map<String, JobTypeStat>();

    for (Archive_Job_Log__b r : records) {
      summary.totalRuns += 1;

      Long processed = r.RecordsProcessed__c == null ? 0 : (Long) r.RecordsProcessed__c;
      Long failed = r.RecordsFailed__c == null ? 0 : (Long) r.RecordsFailed__c;
      summary.totalProcessed += processed;
      summary.totalFailed += failed;

      String status = String.isBlank(r.Status__c) ? '' : r.Status__c.toLowerCase();
      if (status == 'failed' || status == 'error') {
        summary.failedRuns += 1;
      } else if (status == 'success' || status == 'completed') {
        summary.successRuns += 1;
      }

      String type = String.isBlank(r.JobType__c) ? 'Unknown' : r.JobType__c;
      JobTypeStat stat = typeMap.get(type);
      if (stat == null) {
        stat = new JobTypeStat(type);
        typeMap.put(type, stat);
      }
      stat.runs += 1;
      stat.recordsProcessed += processed;
      stat.recordsFailed += failed;
    }

    summary.byType = typeMap.values();

    List<Archive_Job_Log__b> sorted = records.clone();
    sorted.sort(new JobRecencyComparator());
    Integer limitN = Math.min(RECENT_LIMIT, sorted.size());
    for (Integer i = 0; i < limitN; i++) {
      summary.recent.add(toJobRow(sorted[i], i));
    }

    return summary;
  }

  private static JobRow toJobRow(Archive_Job_Log__b r, Integer idx) {
    JobRow row = new JobRow();
    row.configName = r.ConfigName__c;
    row.jobType = r.JobType__c;
    row.status = r.Status__c;
    row.recordsProcessed = r.RecordsProcessed__c == null ? 0 : (Long) r.RecordsProcessed__c;
    row.recordsFailed = r.RecordsFailed__c == null ? 0 : (Long) r.RecordsFailed__c;
    row.runDateTime = r.RunDateTime__c;
    row.errorSummary = r.ErrorSummary__c;
    row.rowKey = String.valueOf(r.RunDateTime__c == null ? 0 : r.RunDateTime__c.getTime()) + '|' + idx;
    return row;
  }

  private static BIGOTOOL_Toggles.SettingsState loadToggles() {
    return BIGOTOOL_Toggles.currentSettings();
  }

  /** Returns the org-default custom setting values for the configuration popup. */
  @AuraEnabled
  public static BIGOTOOL_Toggles.SettingsState getOrgSettings() {
    return BIGOTOOL_Toggles.orgSettings();
  }

  /**
   * Persists the org-default custom setting from the dashboard configuration
   * popup. Gated by the BIGOTOOL_Can_Configure custom permission.
   */
  @AuraEnabled
  public static BIGOTOOL_Toggles.SettingsState saveOrgSettings(
    Boolean masterSwitch,
    Boolean loggingEnabled,
    Boolean archivingEnabled,
    Boolean debugMode,
    Decimal maxBatchConcurrency
  ) {
    if (!FeatureManagement.checkPermission('BIGOTOOL_Can_Configure')) {
      throw new AuraHandledException('You do not have permission to manage BIGOTOOL settings.');
    }
    return BIGOTOOL_Toggles.saveOrgSettings(
      masterSwitch,
      loggingEnabled,
      archivingEnabled,
      debugMode,
      maxBatchConcurrency
    );
  }

  public class JobRecencyComparator implements Comparator<Archive_Job_Log__b> {
    public Integer compare(Archive_Job_Log__b a, Archive_Job_Log__b b) {
      Long ta = a.RunDateTime__c == null ? 0 : a.RunDateTime__c.getTime();
      Long tb = b.RunDateTime__c == null ? 0 : b.RunDateTime__c.getTime();
      if (tb > ta) {
        return 1;
      }
      if (tb < ta) {
        return -1;
      }
      return 0;
    }
  }
}
