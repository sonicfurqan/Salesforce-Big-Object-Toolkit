/**
 * Reusable field-history trigger handler. Generated per-object triggers delegate
 * here, passing the object name and trigger context. The handler gates on the
 * runtime toggles, diffs the change, and routes the resulting rows to the Big
 * Object using the configured async mode.
 *
 *   trigger AccountFieldLogTrigger on Account
 *       (after insert, after update, after delete, after undelete) {
 *       BIGOTOOL_ChangeCapture.run('Account', Trigger.operationType,
 *                                  Trigger.oldMap, Trigger.newMap);
 *   }
 */
public with sharing class BIGOTOOL_ChangeCapture {
  /**
   * Transaction-scoped kill switch. When a restore writes a record back to its
   * source object, the Restore Profile can request that generated field-history
   * automation is suppressed so the restore does not re-fire change logging.
   */
  public static Boolean bypass = false;

  public static void run(String objName, System.TriggerOperation op, Map<Id, SObject> oldMap, Map<Id, SObject> newMap) {
    if (bypass) {
      return;
    }
    if (!BIGOTOOL_Toggles.loggingEnabled(objName)) {
      return;
    }

    List<FieldChangeLog__b> logs = BIGOTOOL_Differ.diff(objName, op, oldMap, newMap);
    if (logs.isEmpty()) {
      return;
    }

    switch on BIGOTOOL_Toggles.asyncMode(objName) {
      when 'Queueable' {
        System.enqueueJob(new BIGOTOOL_LogFlushQueueable(logs));
      }
      when 'Synchronous' {
        BIGOTOOL_LogWriter.write(logs);
      }
      when else {
        // PlatformEvent (default): decouple the Big Object write from this txn.
        BIGOTOOL_EventPublisher.publish(logs);
      }
    }
  }
}
