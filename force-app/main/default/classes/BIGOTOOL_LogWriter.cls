/**
 * Single choke-point for writing FieldChangeLog__b rows to the Big Object via
 * insertImmediate. Centralizing the write keeps the synchronous path, the
 * Queueable path, and the platform-event subscriber consistent.
 */
public with sharing class BIGOTOOL_LogWriter {
  @TestVisible
  private static List<FieldChangeLog__b> lastWritten;

  public static void write(List<FieldChangeLog__b> logs) {
    if (logs == null || logs.isEmpty()) {
      return;
    }
    lastWritten = logs;
    // Big Object DML is not committed/queryable in test context; guard so unit
    // tests exercise the surrounding logic without persisting rows.
    if (Test.isRunningTest()) {
      return;
    }
    Database.insertImmediate(logs);
  }
}
