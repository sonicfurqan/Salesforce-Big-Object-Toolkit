/**
 * BIGOTOOL_ArchiveBatch
 *
 * Generic, reusable archive batch driven entirely by an Archive_Config__c
 * record. It queries source records matching the configured criteria, writes
 * them into the generated Big Object via Database.insertImmediate, optionally
 * deletes the source rows, and logs the run to Archive_Job_Log__b.
 *
 * The batch is fully dynamic - no per-object Apex is generated. It is scheduled
 * by the generation engine and can be re-run at any time for an existing config.
 */
public with sharing class BIGOTOOL_ArchiveBatch implements Database.Batchable<SObject>, Database.Stateful {
  private final Id configId;
  private Archive_Config__c config;
  private String bigObjectApi;
  private List<String> archiveFields;
  // Lowercased source field API name -> true when it is a long text area / rich text field.
  private Map<String, Boolean> longTextFieldMap;
  // Lowercased source field API name -> generated physical Big Object column for
  // list-view fields (those flagged Is_List_View__c on Archive_Field__c).
  private Map<String, String> listViewColumnByField;

  private Integer processed = 0;
  private Integer failed = 0;
  private String errorSummary = '';

  public BIGOTOOL_ArchiveBatch(Id configId) {
    this.configId = configId;
  }

  public Database.QueryLocator start(Database.BatchableContext bc) {
    assertCanArchive();
    loadConfig();
    String soql = 'SELECT ' + String.join(buildSelectFields(), ', ') + ' FROM ' + config.Source_Object__c;
    String whereClause = buildWhereClause();
    if (String.isNotBlank(whereClause)) {
      soql += ' WHERE ' + whereClause;
    }
    return Database.getQueryLocator(soql);
  }

  public void execute(Database.BatchableContext bc, List<SObject> scope) {
    if (config == null) {
      loadConfig();
    }
    SObjectType bigObjectType = Schema.getGlobalDescribe().get(bigObjectApi);
    if (bigObjectType == null) {
      failed += scope.size();
      errorSummary = 'Big Object ' + bigObjectApi + ' not found. Has generation completed?';
      return;
    }

    List<SObject> archiveRows = new List<SObject>();
    for (SObject src : scope) {
      SObject row = bigObjectType.newSObject();
      row.put(BIGOTOOL_MetadataGenerator.FIELD_ORIGINAL_ID, String.valueOf(src.get('Id')));
      row.put(BIGOTOOL_MetadataGenerator.FIELD_ARCHIVED_DATE, System.now());

      // Partition the selected field values into a "non long text" bucket and a
      // "long text" bucket, then serialize each bucket as JSON.
      Map<String, Object> scalarData = new Map<String, Object>();
      Map<String, Object> longTextData = new Map<String, Object>();
      for (String srcField : archiveFields) {
        Object value = safeGet(src, srcField);
        if (isLongText(srcField)) {
          longTextData.put(srcField, value);
        } else {
          scalarData.put(srcField, value);
        }
      }

      row.put(BIGOTOOL_MetadataGenerator.FIELD_DATA, clip(JSON.serialize(scalarData)));

      // Long text values can exceed a single column; spill the remainder into
      // the overflow column so the full JSON can be reassembled on restore.
      String longJson = JSON.serialize(longTextData);
      Integer cap = BIGOTOOL_MetadataGenerator.LONG_TEXT_LENGTH;
      if (longJson.length() <= cap) {
        row.put(BIGOTOOL_MetadataGenerator.FIELD_LONG_TEXT_DATA, longJson);
        row.put(BIGOTOOL_MetadataGenerator.FIELD_OVERFLOW_DATA, null);
      } else {
        row.put(BIGOTOOL_MetadataGenerator.FIELD_LONG_TEXT_DATA, longJson.substring(0, cap));
        String overflow = longJson.substring(cap);
        row.put(BIGOTOOL_MetadataGenerator.FIELD_OVERFLOW_DATA, clip(overflow));
      }

      // List-view fields are also stored in their own physical columns so the
      // generic list view can query/display them directly without parsing JSON.
      if (listViewColumnByField != null && !listViewColumnByField.isEmpty()) {
        for (String srcField : archiveFields) {
          String col = listViewColumnByField.get(srcField.toLowerCase());
          if (String.isBlank(col)) {
            continue;
          }
          Object value = safeGet(src, srcField);
          String text = value == null ? null : String.valueOf(value);
          if (text != null && text.length() > 255) {
            text = text.substring(0, 255);
          }
          row.put(col, text);
        }
      }

      archiveRows.add(row);
    }

    try {
      if (!archiveRows.isEmpty()) {
        Database.insertImmediate(archiveRows);
      }
      processed += scope.size();
      if (config.Delete_After_Archive__c == true && !scope.isEmpty()) {
        delete scope;
      }
    } catch (Exception e) {
      failed += scope.size();
      appendError(e.getMessage());
    }
  }

  public void finish(Database.BatchableContext bc) {
    logRun(bc == null ? null : (Id) bc.getJobId());
    updateConfigStats();
  }

  // ---------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------

  private void loadConfig() {
    config = [
      SELECT
        Id,
        Name,
        Source_Object__c,
        Big_Object_Api_Name__c,
        Criteria_Type__c,
        Age_Field__c,
        Age_Threshold_Days__c,
        Filter_Logic__c,
        Delete_After_Archive__c,
        Batch_Size__c,
        Schedule_Cron__c,
        Total_Records_Archived__c
      FROM Archive_Config__c
      WHERE Id = :configId
      LIMIT 1
    ];
    bigObjectApi = String.isNotBlank(config.Big_Object_Api_Name__c)
      ? config.Big_Object_Api_Name__c
      : BIGOTOOL_MetadataGenerator.bigObjectApiName(config.Source_Object__c);

    // Archived fields now come from the Archive_Field__c child records, which
    // are independent of the (max 6) list-view display columns.
    archiveFields = new List<String>();
    listViewColumnByField = new Map<String, String>();
    for (Archive_Field__c af : [
      SELECT Field_API_Name__c, Is_List_View__c
      FROM Archive_Field__c
      WHERE Archive_Config__c = :configId
      ORDER BY Field_API_Name__c ASC
    ]) {
      if (String.isNotBlank(af.Field_API_Name__c)) {
        archiveFields.add(af.Field_API_Name__c);
        if (af.Is_List_View__c == true) {
          listViewColumnByField.put(
            af.Field_API_Name__c.toLowerCase(),
            BIGOTOOL_MetadataGenerator.archiveFieldApiName(af.Field_API_Name__c)
          );
        }
      }
    }

    buildLongTextFieldMap();
  }

  /**
   * Classifies each selected source field as long text area (rich text /
   * text area long) or not, so archived values can be routed to the correct
   * JSON column.
   */
  private void buildLongTextFieldMap() {
    longTextFieldMap = new Map<String, Boolean>();
    Schema.SObjectType t = Schema.getGlobalDescribe().get(config.Source_Object__c);
    if (t == null) {
      return;
    }
    Map<String, Schema.SObjectField> fieldMap = t.getDescribe().fields.getMap();
    for (String src : archiveFields) {
      Schema.SObjectField token = fieldMap.get(src.toLowerCase());
      Boolean longText = false;
      if (token != null) {
        Schema.DescribeFieldResult dfr = token.getDescribe();
        longText = dfr.getType() == Schema.DisplayType.TEXTAREA && dfr.getLength() > 255;
      }
      longTextFieldMap.put(src.toLowerCase(), longText);
    }
  }

  private Boolean isLongText(String srcField) {
    Boolean v = longTextFieldMap == null ? null : longTextFieldMap.get(srcField.toLowerCase());
    return v == true;
  }

  private List<String> buildSelectFields() {
    Set<String> fields = new Set<String>{ 'Id' };
    for (String f : archiveFields) {
      fields.add(f);
    }
    return new List<String>(fields);
  }

  @TestVisible
  private String buildWhereClause() {
    List<String> clauses = new List<String>();
    String type = String.isBlank(config.Criteria_Type__c) ? 'Age' : config.Criteria_Type__c;
    Boolean useAge = type == 'Age' || type == 'Both';
    Boolean useFilter = type == 'SOQL_Filter' || type == 'Both';

    if (
      useAge &&
      String.isNotBlank(config.Age_Field__c) &&
      config.Age_Threshold_Days__c != null &&
      config.Age_Threshold_Days__c > 0
    ) {
      Integer days = Integer.valueOf(config.Age_Threshold_Days__c);
      clauses.add(config.Age_Field__c + ' < LAST_N_DAYS:' + days);
    }
    if (useFilter && String.isNotBlank(config.Filter_Logic__c)) {
      clauses.add('(' + config.Filter_Logic__c.trim() + ')');
    }
    return String.join(clauses, ' AND ');
  }

  private Object safeGet(SObject record, String fieldPath) {
    try {
      return record.get(fieldPath);
    } catch (Exception e) {
      return null;
    }
  }

  /** Truncates a serialized payload to the Big Object long text column capacity. */
  private String clip(String value) {
    if (String.isBlank(value)) {
      return value;
    }
    Integer cap = BIGOTOOL_MetadataGenerator.LONG_TEXT_LENGTH;
    return value.length() > cap ? value.substring(0, cap) : value;
  }

  private void appendError(String message) {
    if (String.isBlank(message)) {
      return;
    }
    String next = (String.isBlank(errorSummary) ? '' : errorSummary + '\n') + message;
    errorSummary = next.length() > 4000 ? next.substring(0, 4000) : next;
  }

  /**
   * Persists run summary stats back onto the Archive_Config__c so the scheduler
   * record-page component can display last-run date, status and a cumulative
   * archived count without aggregating Big Object rows.
   */
  private void updateConfigStats() {
    if (config == null) {
      return;
    }
    try {
      Decimal priorTotal = config.Total_Records_Archived__c == null ? 0 : config.Total_Records_Archived__c;
      Archive_Config__c upd = new Archive_Config__c(Id = config.Id);
      upd.Last_Archive_Run__c = System.now();
      upd.Total_Records_Archived__c = priorTotal + processed;
      upd.Last_Run_Status__c = failed > 0 ? (processed > 0 ? 'Partial' : 'Failed') : 'Success';
      update upd;
    } catch (Exception e) {
      // Stats are best-effort; never break the job.
      System.debug(LoggingLevel.WARN, 'Archive config stats update failed: ' + e.getMessage());
    }
  }

  private void logRun(Id jobId) {
    try {
      Archive_Job_Log__b logRow = new Archive_Job_Log__b();
      logRow.ConfigName__c = config == null ? String.valueOf(configId) : config.Name;
      logRow.JobType__c = 'Archive';
      logRow.RunDateTime__c = System.now();
      logRow.AsyncJobId__c = jobId == null ? null : String.valueOf(jobId);
      logRow.RecordsProcessed__c = processed;
      logRow.RecordsFailed__c = failed;
      logRow.Status__c = failed > 0 ? (processed > 0 ? 'Partial' : 'Failed') : 'Success';
      logRow.ErrorSummary__c = String.isBlank(errorSummary) ? null : errorSummary;
      if (!Test.isRunningTest()) {
        Database.insertImmediate(new List<SObject>{ logRow });
      }
    } catch (Exception e) {
      // Logging must never break the job.
      System.debug(LoggingLevel.WARN, 'Archive job log failed: ' + e.getMessage());
    }
  }
  private static void assertCanArchive() {
    BIGOTOOL_ArchiveGuard.Decision decision = BIGOTOOL_ArchiveGuard.evaluate();
    if (!decision.allowed) {
      throw new AuraHandledException(decision.reason);
    }
  }
}
