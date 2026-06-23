/**
 * Writes captured field-change rows to the Big Object in an asynchronous
 * Queueable context (Async_Mode__c = 'Queueable'), keeping insertImmediate out
 * of the originating transaction.
 */
public with sharing class BIGOTOOL_LogFlushQueueable implements Queueable {
  private final List<FieldChangeLog__b> logs;

  public BIGOTOOL_LogFlushQueueable(List<FieldChangeLog__b> logs) {
    this.logs = logs;
  }

  public void execute(QueueableContext ctx) {
    BIGOTOOL_LogWriter.write(logs);
  }
}
