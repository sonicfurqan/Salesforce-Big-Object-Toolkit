/**
 * BIGOTOOL_ArchiveGuard
 *
 * Centralized pre-flight check for launching an archive batch. Combines two
 * concerns so every entry point (scheduler, on-demand "Run Now", the generation
 * engine's scheduled job) behaves consistently:
 *
 *   1. Feature toggles exposed by BIGOTOOL_Toggles.
 *   2. System / concurrency limits - the platform flex-queue ceiling and the
 *      configurable Max_Batch_Concurrency__c throttle. A new batch is only
 *      launched when the number of in-flight Apex batch jobs is below the limit.
 */
public with sharing class BIGOTOOL_ArchiveGuard {
  // Salesforce flex queue: at most 5 batches actively processing and up to 100
  // jobs held/queued. Treat the holding ceiling as the hard system limit.
  @TestVisible
  private static final Integer FLEX_QUEUE_LIMIT = 100;
  // Default throttle when Max_Batch_Concurrency__c is not configured: align with
  // the platform's 5 concurrently-processing batch jobs.
  @TestVisible
  private static final Integer DEFAULT_MAX_CONCURRENCY = 5;

  /** Outcome of a guard evaluation. */
  public class Decision {
    public Boolean allowed;
    public String reason;
    public Decision(Boolean allowed, String reason) {
      this.allowed = allowed;
      this.reason = reason;
    }
  }

  /**
   * Evaluates whether an archive batch may launch right now. Never throws; the
   * caller decides whether to skip silently (scheduler) or surface the reason
   * (interactive controller).
   */
  public static Decision evaluate() {
    BIGOTOOL_Toggles.SettingsState settings = BIGOTOOL_Toggles.currentSettings();

    if (!settings.masterSwitch) {
      return new Decision(false, 'Archiving is blocked: the global Master Switch is OFF.');
    }
    if (!settings.archivingEnabled) {
      return new Decision(false, 'Archiving is disabled in BIGOTOOL Settings (Archiving Enabled is OFF).');
    }

    Integer maxConcurrency = BIGOTOOL_Toggles.maxBatchConcurrency(DEFAULT_MAX_CONCURRENCY);
    Integer inFlight = activeBatchJobCount();
    if (inFlight >= FLEX_QUEUE_LIMIT) {
      return new Decision(
        false,
        'Cannot start archiving: the Apex flex queue is full (' + inFlight + ' jobs in flight). Try again later.'
      );
    }
    if (inFlight >= maxConcurrency) {
      return new Decision(
        false,
        'Cannot start archiving: ' +
          inFlight +
          ' batch job(s) already running, which meets the Max Batch Concurrency limit of ' +
          maxConcurrency +
          '.'
      );
    }
    return new Decision(true, null);
  }

  /** Convenience wrapper returning only the allow/deny flag. */
  public static Boolean canRun() {
    return evaluate().allowed;
  }

  /**
   * Counts Apex batch jobs that are queued, holding, preparing or processing -
   * i.e. occupying flex-queue / concurrency capacity. In test context the live
   * AsyncApexJob count is non-deterministic, so a controllable override is used.
   */
  @TestVisible
  private static Integer testActiveJobCount = null;

  @TestVisible
  private static Integer activeBatchJobCount() {
    if (Test.isRunningTest()) {
      return testActiveJobCount == null ? 0 : testActiveJobCount;
    }
    return [
      SELECT COUNT()
      FROM AsyncApexJob
      WHERE JobType = 'BatchApex' AND Status IN ('Holding', 'Queued', 'Preparing', 'Processing')
    ];
  }
}
