/**
 * BIGOTOOL_SchedulerController
 *
 * LWC controller backing the Archive Config "Scheduler" record-page component.
 * Surfaces the current state of the scheduled archive job (active / paused /
 * not scheduled), the last run date, and the cumulative records archived, and
 * exposes actions to start, pause, delete the schedule and run the archive
 * batch on demand.
 *
 * The scheduled job is identified by a deterministic name derived from the
 * config Id, matching BIGOTOOL_MetadataGenerator.scheduleBatch.
 */
public with sharing class BIGOTOOL_SchedulerController {
  @TestVisible
  private static final String JOB_PREFIX = 'BIGOTOOL Archive ';
  // Daily at 02:00 fallback when the config has no explicit cron expression.
  private static final String DEFAULT_CRON = '0 0 2 * * ?';

  /** Snapshot returned to the LWC. */
  public class SchedulerStatus {
    @AuraEnabled
    public Id configId;
    @AuraEnabled
    public String state; // Active | Paused | NotScheduled
    @AuraEnabled
    public String cronState; // raw CronTrigger.State when scheduled
    @AuraEnabled
    public String cronExpression;
    @AuraEnabled
    public Datetime nextRun;
    @AuraEnabled
    public Datetime previousRun;
    @AuraEnabled
    public Datetime lastArchiveRun;
    @AuraEnabled
    public Decimal totalArchived;
    @AuraEnabled
    public String lastRunStatus;
    @AuraEnabled
    public String generationStatus;
    @AuraEnabled
    public Boolean isGenerated;
    @AuraEnabled
    public String sourceObject;
  }

  // ---------------------------------------------------------------------------
  // Status
  // ---------------------------------------------------------------------------

  @AuraEnabled(cacheable=true)
  public static SchedulerStatus getStatus(Id configId) {
    assertCanConfigure();
    Archive_Config__c cfg = loadConfig(configId);

    SchedulerStatus s = new SchedulerStatus();
    s.configId = cfg.Id;
    s.cronExpression = cfg.Schedule_Cron__c;
    s.lastArchiveRun = cfg.Last_Archive_Run__c;
    s.totalArchived = cfg.Total_Records_Archived__c == null ? 0 : cfg.Total_Records_Archived__c;
    s.lastRunStatus = cfg.Last_Run_Status__c;
    s.generationStatus = cfg.Generation_Status__c;
    s.isGenerated = cfg.Generation_Status__c == 'Generated';
    s.sourceObject = cfg.Source_Object__c;

    CronTrigger ct = findTrigger(configId);
    if (ct != null) {
      s.state = 'Active';
      s.cronState = ct.State;
      s.nextRun = ct.NextFireTime;
      s.previousRun = ct.PreviousFireTime;
      if (String.isNotBlank(ct.CronExpression)) {
        s.cronExpression = ct.CronExpression;
      }
    } else if (cfg.Schedule_Paused__c == true) {
      s.state = 'Paused';
    } else {
      s.state = 'NotScheduled';
    }
    return s;
  }

  // ---------------------------------------------------------------------------
  // Actions
  // ---------------------------------------------------------------------------

  /** Schedules (or resumes) the archive job using the config cron, or a default. */
  @AuraEnabled
  public static SchedulerStatus startSchedule(Id configId) {
    assertCanConfigure();
    Archive_Config__c cfg = loadConfig(configId);
    if (cfg.Generation_Status__c != 'Generated') {
      throw new AuraHandledException('Generate the archive metadata before scheduling.');
    }
    assertCanArchive();
    if (findTrigger(configId) != null) {
      throw new AuraHandledException('A schedule is already active for this configuration.');
    }

    String cron = String.isNotBlank(cfg.Schedule_Cron__c) ? cfg.Schedule_Cron__c : DEFAULT_CRON;
    if (!Test.isRunningTest()) {
      System.schedule(jobName(configId), cron, new BIGOTOOL_ArchiveSchedulable(configId));
    }

    cfg.Schedule_Paused__c = false;
    update cfg;
    return getStatusInternal(configId);
  }

  /** Aborts the scheduled job but flags the config as intentionally paused. */
  @AuraEnabled
  public static SchedulerStatus pauseSchedule(Id configId) {
    assertCanConfigure();
    Archive_Config__c cfg = loadConfig(configId);
    abortTrigger(configId);
    cfg.Schedule_Paused__c = true;
    update cfg;
    return getStatusInternal(configId);
  }

  /** Aborts the scheduled job and clears the paused flag (back to Not Scheduled). */
  @AuraEnabled
  public static SchedulerStatus deleteSchedule(Id configId) {
    assertCanConfigure();
    Archive_Config__c cfg = loadConfig(configId);
    abortTrigger(configId);
    cfg.Schedule_Paused__c = false;
    update cfg;
    return getStatusInternal(configId);
  }

  /** Kicks off the archive batch immediately. Returns the AsyncApexJob Id. */
  @AuraEnabled
  public static Id runNow(Id configId) {
    assertCanConfigure();
    Archive_Config__c cfg = loadConfig(configId);
    if (cfg.Generation_Status__c != 'Generated') {
      throw new AuraHandledException('Generate the archive metadata before running the batch.');
    }
    assertCanArchive();
    Integer batchSize = (cfg.Batch_Size__c != null && cfg.Batch_Size__c > 0) ? Integer.valueOf(cfg.Batch_Size__c) : 200;
    if (Test.isRunningTest()) {
      return null;
    }
    return Database.executeBatch(new BIGOTOOL_ArchiveBatch(configId), batchSize);
  }

  // ---------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------

  @TestVisible
  private static String jobName(Id configId) {
    return JOB_PREFIX + configId;
  }

  private static CronTrigger findTrigger(Id configId) {
    String name = jobName(configId);
    List<CronTrigger> triggers = [
      SELECT Id, State, NextFireTime, PreviousFireTime, CronExpression
      FROM CronTrigger
      WHERE CronJobDetail.Name = :name AND State != 'DELETED' AND State != 'COMPLETE' AND State != 'ERROR'
      ORDER BY CreatedDate DESC
      LIMIT 1
    ];
    return triggers.isEmpty() ? null : triggers[0];
  }

  private static void abortTrigger(Id configId) {
    String name = jobName(configId);
    for (CronTrigger ct : [SELECT Id FROM CronTrigger WHERE CronJobDetail.Name = :name]) {
      try {
        System.abortJob(ct.Id);
      } catch (Exception e) {
        // Job may already be finishing; ignore.
      }
    }
  }

  private static SchedulerStatus getStatusInternal(Id configId) {
    Archive_Config__c cfg = loadConfig(configId);
    SchedulerStatus s = new SchedulerStatus();
    s.configId = cfg.Id;
    s.cronExpression = cfg.Schedule_Cron__c;
    s.lastArchiveRun = cfg.Last_Archive_Run__c;
    s.totalArchived = cfg.Total_Records_Archived__c == null ? 0 : cfg.Total_Records_Archived__c;
    s.lastRunStatus = cfg.Last_Run_Status__c;
    s.generationStatus = cfg.Generation_Status__c;
    s.isGenerated = cfg.Generation_Status__c == 'Generated';
    s.sourceObject = cfg.Source_Object__c;

    CronTrigger ct = findTrigger(configId);
    if (ct != null) {
      s.state = 'Active';
      s.cronState = ct.State;
      s.nextRun = ct.NextFireTime;
      s.previousRun = ct.PreviousFireTime;
      if (String.isNotBlank(ct.CronExpression)) {
        s.cronExpression = ct.CronExpression;
      }
    } else if (cfg.Schedule_Paused__c == true) {
      s.state = 'Paused';
    } else {
      s.state = 'NotScheduled';
    }
    return s;
  }

  private static Archive_Config__c loadConfig(Id configId) {
    if (configId == null) {
      throw new AuraHandledException('A configuration record is required.');
    }
    List<Archive_Config__c> rows = [
      SELECT
        Id,
        Name,
        Source_Object__c,
        Big_Object_Api_Name__c,
        Generation_Status__c,
        Schedule_Cron__c,
        Schedule_Paused__c,
        Batch_Size__c,
        Last_Archive_Run__c,
        Total_Records_Archived__c,
        Last_Run_Status__c
      FROM Archive_Config__c
      WHERE Id = :configId
      LIMIT 1
    ];
    if (rows.isEmpty()) {
      throw new AuraHandledException('Configuration not found.');
    }
    return rows[0];
  }

  private static void assertCanConfigure() {
    if (!FeatureManagement.checkPermission('BIGOTOOL_Can_Configure')) {
      throw new AuraHandledException('You do not have permission to configure archiving.');
    }
  }

  /**
   * Blocks scheduling / on-demand runs when the global toggles are off or the
   * system/concurrency limits are exceeded, surfacing the specific reason.
   */
  private static void assertCanArchive() {
    BIGOTOOL_ArchiveGuard.Decision decision = BIGOTOOL_ArchiveGuard.evaluate();
    if (!decision.allowed) {
      throw new AuraHandledException(decision.reason);
    }
  }
}
