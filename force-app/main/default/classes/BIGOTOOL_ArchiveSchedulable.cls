/**
 * BIGOTOOL_ArchiveSchedulable
 *
 * Thin Schedulable wrapper that launches the reusable archive batch for a
 * given Archive_Config__c. Scheduled by the generation engine so the batch
 * runs in a later transaction (after the new Big Object metadata is committed).
 */
public with sharing class BIGOTOOL_ArchiveSchedulable implements Schedulable {
  private final Id configId;

  public BIGOTOOL_ArchiveSchedulable(Id configId) {
    this.configId = configId;
  }

  public void execute(SchedulableContext sc) {
    // Respect the global toggles and concurrency/system limits before launching
    // a batch. When blocked, skip this run quietly - the schedule stays in place
    // and the next fire time will re-evaluate.
    BIGOTOOL_ArchiveGuard.Decision decision = BIGOTOOL_ArchiveGuard.evaluate();
    if (!decision.allowed) {
      System.debug(LoggingLevel.WARN, 'BIGOTOOL archive run skipped: ' + decision.reason);
      return;
    }

    Integer batchSize = 200;
    try {
      Archive_Config__c cfg = [
        SELECT Batch_Size__c
        FROM Archive_Config__c
        WHERE Id = :configId
        LIMIT 1
      ];
      if (cfg.Batch_Size__c != null && cfg.Batch_Size__c > 0) {
        batchSize = Integer.valueOf(cfg.Batch_Size__c);
      }
    } catch (Exception e) {
      // Fall back to the default batch size.
    }
    Database.executeBatch(new BIGOTOOL_ArchiveBatch(configId), batchSize);
  }
}
