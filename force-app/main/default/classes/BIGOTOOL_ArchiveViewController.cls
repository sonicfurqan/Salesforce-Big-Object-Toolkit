/**
 * Read API for the generic archived-data viewer LWCs:
 *   - bigotoolArchiveListView   (dynamic list view over any generated Big Object)
 *   - bigotoolArchiveRecordView (dynamic record layout for a single archived row)
 *
 * Everything is driven by an Archive_Config__c record, so a single pair of
 * components works for every Big Object the tool generates. Archived field
 * values are reconstructed from the three JSON columns written by
 * BIGOTOOL_ArchiveBatch (FieldData__c, LongTextData__c + OverflowData__c).
 *
 * Runs WITHOUT sharing because Big Objects do not enforce record-level sharing;
 * access is governed by the BIGOTOOL_Archive_Viewer / Administrator permission
 * sets (object + field level on the generated Big Object).
 */
public without sharing class BIGOTOOL_ArchiveViewController {
  @TestVisible
  private static final Integer DEFAULT_PAGE_SIZE = 50;
  @TestVisible
  private static final Integer MAX_PAGE_SIZE = 200;
  @TestVisible
  private static final Integer FULL_SCAN_CAP = 2000;
  // Hard ceiling for a single synchronous "full archive" CSV export.
  @TestVisible
  private static final Integer MAX_EXPORT_ROWS = 50000;

  // ---------------------------------------------------------------------------
  // DTOs
  // ---------------------------------------------------------------------------

  public class ColumnDef {
    @AuraEnabled
    public String apiName;
    @AuraEnabled
    public String label;
    @AuraEnabled
    public String type;
  }

  public class ListConfig {
    @AuraEnabled
    public Id configId;
    @AuraEnabled
    public String bigObjectApiName;
    @AuraEnabled
    public String sourceObject;
    @AuraEnabled
    public String title;
    @AuraEnabled
    public List<ColumnDef> columns = new List<ColumnDef>();
  }

  public class ArchiveRow {
    @AuraEnabled
    public String originalId;
    @AuraEnabled
    public Datetime archivedDate;
    @AuraEnabled
    public String rowKey;
    @AuraEnabled
    public Map<String, Object> values = new Map<String, Object>();
  }

  public class ListPage {
    @AuraEnabled
    public List<ArchiveRow> rows = new List<ArchiveRow>();
    @AuraEnabled
    public Boolean hasMore = false;
    @AuraEnabled
    public Datetime nextCursor;
    @AuraEnabled
    public Integer nextOffset;
  }

  public class FieldView {
    @AuraEnabled
    public String apiName;
    @AuraEnabled
    public String label;
    @AuraEnabled
    public String type;
    @AuraEnabled
    public Object value;
    @AuraEnabled
    public String displayValue;
  }

  public class RecordView {
    @AuraEnabled
    public String originalId;
    @AuraEnabled
    public Datetime archivedDate;
    @AuraEnabled
    public String sourceObject;
    @AuraEnabled
    public List<FieldView> fields = new List<FieldView>();
  }

  public class RestoreResult {
    @AuraEnabled
    public String recordId;
    @AuraEnabled
    public String sourceObject;
    @AuraEnabled
    public String sourceObjectLabel;
    @AuraEnabled
    public Boolean skipped = false;
    @AuraEnabled
    public String outcome;
  }

  // ---------------------------------------------------------------------------
  // List view configuration (columns)
  // ---------------------------------------------------------------------------

  /**
   * Resolves the Archive_Config__c Id for a generated Big Object API name. Lets
   * the generic list view component be configured with just the Big Object name
   * (e.g. on a generated FlexiPage tab) and discover its driving config.
   */
  @AuraEnabled(cacheable=true)
  public static Id getConfigIdForBigObject(String bigObjectApiName) {
    if (String.isBlank(bigObjectApiName)) {
      throw new AuraHandledException('A Big Object API name is required.');
    }
    List<Archive_Config__c> cfgs = [
      SELECT Id
      FROM Archive_Config__c
      WHERE Big_Object_Api_Name__c = :bigObjectApiName
      ORDER BY CreatedDate ASC
      LIMIT 1
    ];
    if (cfgs.isEmpty()) {
      throw new AuraHandledException('No Archive Configuration found for ' + bigObjectApiName + '.');
    }
    return cfgs[0].Id;
  }

  @AuraEnabled(cacheable=true)
  public static ListConfig getListConfig(Id configId) {
    Archive_Config__c cfg = loadConfig(configId);
    String boApi = bigObjectApi(cfg);

    ListConfig lc = new ListConfig();
    lc.configId = cfg.Id;
    lc.bigObjectApiName = boApi;
    lc.sourceObject = cfg.Source_Object__c;
    lc.title = 'Archived ' + cfg.Source_Object__c;

    for (LvColumn col : listColumns(cfg, boApi)) {
      ColumnDef cd = new ColumnDef();
      cd.apiName = col.fieldName;
      cd.label = col.label;
      cd.type = col.type;
      lc.columns.add(cd);
    }
    return lc;
  }

  /** Internal description of a single list-view column. */
  private class LvColumn {
    String sourceField; // source object field API name
    String fieldName; // key used in ArchiveRow.values + datatable column fieldName
    String columnApi; // physical Big Object column API name (when materialized)
    String label;
    String type;
    Boolean physical; // true => read from physical column; false => parse JSON
  }

  /**
   * Resolves the list-view columns for a config. Preference order:
   *   1. Archive_Field__c children flagged Is_List_View__c (materialized as their
   *      own physical Big Object columns).
   *   2. Legacy List_View_Fields__c CSV (values parsed from the JSON columns).
   * Physical columns are only used when they actually exist on the Big Object,
   * so configs edited but not yet regenerated still render via JSON fallback.
   */
  private static List<LvColumn> listColumns(Archive_Config__c cfg, String boApi) {
    Set<String> existing = bigObjectFieldNames(boApi);

    List<Archive_Field__c> flagged = new List<Archive_Field__c>();
    for (Archive_Field__c af : cfg.Archive_Fields__r) {
      if (af.Is_List_View__c == true && String.isNotBlank(af.Field_API_Name__c)) {
        System.debug('af ' + af);
        flagged.add(af);
      }
    }

    List<LvColumn> cols = new List<LvColumn>();
    if (!flagged.isEmpty()) {
      for (Archive_Field__c af : flagged) {
        String src = af.Field_API_Name__c;
        String colApi = BIGOTOOL_MetadataGenerator.archiveFieldApiName(src);
        Boolean physical = existing.contains(colApi.toLowerCase());
        LvColumn c = new LvColumn();
        c.sourceField = src;
        c.columnApi = colApi;
        c.physical = physical;
        c.fieldName = physical ? colApi : src;
        c.label = String.isBlank(af.Field_Label__c) ? src : af.Field_Label__c;
        c.type = physical ? 'text' : datatableType(af.Field_Type__c);
        cols.add(c);
      }
      return cols;
    }

    return cols;
  }

  /** Lowercased set of field API names present on the Big Object (empty if absent). */
  private static Set<String> bigObjectFieldNames(String boApi) {
    Set<String> names = new Set<String>();
    if (String.isBlank(boApi)) {
      return names;
    }
    Schema.SObjectType t = Schema.getGlobalDescribe().get(boApi);
    if (t == null) {
      return names;
    }
    for (String f : t.getDescribe().fields.getMap().keySet()) {
      names.add(f.toLowerCase());
    }
    return names;
  }

  // ---------------------------------------------------------------------------
  // List view data (paged + filterable on the two index fields)
  // ---------------------------------------------------------------------------

  @AuraEnabled(cacheable=true)
  public static ListPage getRecords(
    Id configId,
    String originalIdFilter,
    Datetime fromDate,
    Datetime toDate,
    Integer pageSize,
    Integer offset
  ) {
    Archive_Config__c cfg = loadConfig(configId);
    String boApi = bigObjectApi(cfg);
    List<LvColumn> columns = listColumns(cfg, boApi);

    LvColumn orignalId = new LvColumn();
    orignalId.sourceField = BIGOTOOL_MetadataGenerator.FIELD_ORIGINAL_ID;
    orignalId.columnApi = BIGOTOOL_MetadataGenerator.FIELD_ORIGINAL_ID;
    orignalId.physical = true;
    orignalId.fieldName = BIGOTOOL_MetadataGenerator.FIELD_ORIGINAL_ID;
    orignalId.label = 'Original Id';
    orignalId.type = 'text';
    columns.add(orignalId);

    LvColumn fieldArchivedDate = new LvColumn();
    fieldArchivedDate.sourceField = BIGOTOOL_MetadataGenerator.FIELD_ARCHIVED_DATE;
    fieldArchivedDate.columnApi = BIGOTOOL_MetadataGenerator.FIELD_ARCHIVED_DATE;
    fieldArchivedDate.physical = true;
    fieldArchivedDate.fieldName = BIGOTOOL_MetadataGenerator.FIELD_ARCHIVED_DATE;
    fieldArchivedDate.label = 'Archived Date';
    fieldArchivedDate.type = 'datetime';
    columns.add(fieldArchivedDate);

    System.debug('columns ' + columns);
    Integer pageLimit = (pageSize == null || pageSize <= 0) ? DEFAULT_PAGE_SIZE : pageSize;
    if (pageLimit > MAX_PAGE_SIZE) {
      pageLimit = MAX_PAGE_SIZE;
    }
    Integer skip = (offset == null || offset < 0) ? 0 : offset;

    ListPage page = new ListPage();
    List<SObject> windowed = fetchWindow(boApi, columns, originalIdFilter, fromDate, toDate, skip, pageLimit);

    // fetchWindow returns up to pageLimit+1 rows; the extra row signals hasMore.
    page.hasMore = windowed.size() > pageLimit;
    if (page.hasMore) {
      windowed.remove(windowed.size() - 1);
    }
    for (SObject r : windowed) {
      page.rows.add(toRow(r, columns));
    }
    page.nextOffset = skip + page.rows.size();
    return page;
  }

  /**
   * Returns a window of archived rows ([offset, offset+limit] plus one sentinel
   * row to indicate "has more"). Uses the composite index:
   *   - With an Original Record Id: equality on the leading index field lets the
   *     date range push into the WHERE clause and ORDER BY ArchivedDate paginate.
   *   - Without it: a deterministic ORDER BY over the index fields drives offset
   *     pagination; any date filter is applied in memory after a capped fetch.
   */
  private static List<SObject> fetchWindow(
    String boApi,
    List<LvColumn> columns,
    String originalIdFilter,
    Datetime fromDate,
    Datetime toDate,
    Integer offset,
    Integer pageLimit
  ) {
    String selectClause = String.join(selectColumns(columns, false), ', ');
    Boolean hasOriginalId = String.isNotBlank(originalIdFilter);
    Boolean hasDate = fromDate != null || toDate != null;

    if (hasOriginalId) {
      String soql =
        'SELECT ' +
        selectClause +
        ' FROM ' +
        boApi +
        ' WHERE ' +
        BIGOTOOL_MetadataGenerator.FIELD_ORIGINAL_ID +
        ' = :originalIdFilter';
      if (fromDate != null) {
        soql += ' AND ' + BIGOTOOL_MetadataGenerator.FIELD_ARCHIVED_DATE + ' >= :fromDate';
      }
      if (toDate != null) {
        soql += ' AND ' + BIGOTOOL_MetadataGenerator.FIELD_ARCHIVED_DATE + ' <= :toDate';
      }
      soql +=
        ' ORDER BY ' +
        BIGOTOOL_MetadataGenerator.FIELD_ORIGINAL_ID +
        ' ASC, ' +
        BIGOTOOL_MetadataGenerator.FIELD_ARCHIVED_DATE +
        ' DESC';
      Integer queryLimit = offset + pageLimit + 1;
      soql += ' LIMIT :queryLimit';
      System.debug('soql ' + soql);
      return sublist(Database.query(soql), offset);
    }

    String soql =
      'SELECT ' +
      selectClause +
      ' FROM ' +
      boApi +
      ' ORDER BY ' +
      BIGOTOOL_MetadataGenerator.FIELD_ORIGINAL_ID +
      ' ASC, ' +
      BIGOTOOL_MetadataGenerator.FIELD_ARCHIVED_DATE +
      ' DESC';
    Integer queryCap = hasDate ? FULL_SCAN_CAP : (offset + pageLimit + 1);
    soql += ' LIMIT :queryCap';
    System.debug('soql ' + soql);
    List<SObject> raw = Database.query(soql);
    if (hasDate) {
      raw = applyDateFilter(raw, fromDate, toDate);
    }
    return sublist(raw, offset);
  }

  /** Returns rows from index `offset` onwards (empty when offset past the end). */
  private static List<SObject> sublist(List<SObject> rows, Integer offset) {
    List<SObject> out = new List<SObject>();
    if (rows == null) {
      return out;
    }
    for (Integer i = offset; i < rows.size(); i++) {
      out.add(rows[i]);
    }
    return out;
  }

  /** Big Object columns to SELECT: index + JSON columns + any physical list columns. */
  private static List<String> selectColumns(List<LvColumn> columns, Boolean includeJson) {
    Set<String> cols = new Set<String>(includeJson ? jsonColumns() : new List<String>());
    if (columns != null) {
      for (LvColumn c : columns) {
        if (c.physical == true && String.isNotBlank(c.columnApi)) {
          cols.add(c.columnApi);
        }
      }
    }
    return new List<String>(cols);
  }

  private static List<SObject> applyDateFilter(List<SObject> rows, Datetime fromDate, Datetime toDate) {
    if (fromDate == null && toDate == null) {
      return rows;
    }
    List<SObject> out = new List<SObject>();
    for (SObject r : rows) {
      Datetime d = (Datetime) r.get(BIGOTOOL_MetadataGenerator.FIELD_ARCHIVED_DATE);
      if (fromDate != null && (d == null || d < fromDate)) {
        continue;
      }
      if (toDate != null && (d == null || d > toDate)) {
        continue;
      }
      out.add(r);
    }
    return out;
  }

  // ---------------------------------------------------------------------------
  // Single archived record (dynamic layout)
  // ---------------------------------------------------------------------------

  @AuraEnabled(cacheable=true)
  public static RecordView getArchivedRecord(Id configId, String originalId, Datetime archivedDate) {
    if (String.isBlank(originalId)) {
      throw new AuraHandledException('An Original Record Id is required.');
    }
    Archive_Config__c cfg = loadConfig(configId);
    String boApi = bigObjectApi(cfg);

    String soql =
      'SELECT ' +
      String.join(jsonColumns(), ', ') +
      ' FROM ' +
      boApi +
      ' WHERE ' +
      BIGOTOOL_MetadataGenerator.FIELD_ORIGINAL_ID +
      ' = :originalId';
    if (archivedDate != null) {
      soql += ' AND ' + BIGOTOOL_MetadataGenerator.FIELD_ARCHIVED_DATE + ' = :archivedDate';
    }
    soql += ' LIMIT 1';

    List<SObject> rows = Database.query(soql);
    if (rows.isEmpty()) {
      throw new AuraHandledException('Archived record not found.');
    }
    SObject row = rows[0];
    Map<String, Object> values = mergeValues(row);

    RecordView rv = new RecordView();
    rv.originalId = String.valueOf(row.get(BIGOTOOL_MetadataGenerator.FIELD_ORIGINAL_ID));
    rv.archivedDate = (Datetime) row.get(BIGOTOOL_MetadataGenerator.FIELD_ARCHIVED_DATE);
    rv.sourceObject = cfg.Source_Object__c;

    for (Archive_Field__c af : cfg.Archive_Fields__r) {
      if (String.isBlank(af.Field_API_Name__c)) {
        continue;
      }
      FieldView fv = new FieldView();
      fv.apiName = af.Field_API_Name__c;
      fv.label = String.isBlank(af.Field_Label__c) ? af.Field_API_Name__c : af.Field_Label__c;
      fv.type = String.isBlank(af.Field_Type__c) ? 'STRING' : af.Field_Type__c;
      fv.value = values.get(af.Field_API_Name__c);
      fv.displayValue = fv.value == null ? '' : String.valueOf(fv.value);
      rv.fields.add(fv);
    }
    return rv;
  }

  // ---------------------------------------------------------------------------
  // Restore (re-create the archived row in its original source object)
  // ---------------------------------------------------------------------------

  /** True when the running user holds the restore custom permission. */
  @AuraEnabled(cacheable=true)
  public static Boolean canRestore() {
    return FeatureManagement.checkPermission('BIGOTOOL_Can_Restore');
  }

  /**
   * Re-creates an archived record in its original source object from the JSON
   * payload columns. Only createable source fields are written, and values are
   * coerced back into their native Apex types. Gated by the BIGOTOOL_Can_Restore
   * custom permission. Returns the new record Id so the UI can navigate to it.
   */
  @AuraEnabled
  public static RestoreResult restoreRecord(Id configId, String originalId, Datetime archivedDate) {
    if (!canRestore()) {
      throw new AuraHandledException('You do not have permission to restore archived records.');
    }
    if (String.isBlank(originalId)) {
      throw new AuraHandledException('An Original Record Id is required.');
    }

    Archive_Config__c cfg = loadConfig(configId);
    String boApi = bigObjectApi(cfg);
    RestoreSettings settings = resolveRestoreSettings(cfg);

    // The Restore Profile may redirect the restore into a different target
    // object; default to the original source object.
    String targetApi = String.isNotBlank(settings.targetObject) ? settings.targetObject : cfg.Source_Object__c;
    Schema.SObjectType targetType = Schema.getGlobalDescribe().get(targetApi);
    if (targetType == null) {
      throw new AuraHandledException('Target object ' + targetApi + ' no longer exists.');
    }
    Schema.DescribeSObjectResult targetDescribe = targetType.getDescribe();
    if (!targetDescribe.isCreateable()) {
      throw new AuraHandledException('You do not have permission to create ' + targetApi + ' records.');
    }

    String soql =
      'SELECT ' +
      String.join(jsonColumns(), ', ') +
      ' FROM ' +
      boApi +
      ' WHERE ' +
      BIGOTOOL_MetadataGenerator.FIELD_ORIGINAL_ID +
      ' = :originalId';
    if (archivedDate != null) {
      soql += ' AND ' + BIGOTOOL_MetadataGenerator.FIELD_ARCHIVED_DATE + ' = :archivedDate';
    }
    soql += ' LIMIT 1';

    List<SObject> rows = Database.query(soql);
    if (rows.isEmpty()) {
      throw new AuraHandledException('Archived record not found.');
    }
    Map<String, Object> values = mergeValues(rows[0]);

    Map<String, Schema.SObjectField> fieldMap = targetDescribe.fields.getMap();
    SObject restored = targetType.newSObject();
    Boolean anyValueSet = false;

    for (Archive_Field__c af : cfg.Archive_Fields__r) {
      String fieldApi = af.Field_API_Name__c;
      if (String.isBlank(fieldApi)) {
        continue;
      }
      Schema.SObjectField token = fieldMap.get(fieldApi.toLowerCase());
      if (token == null) {
        continue;
      }
      Schema.DescribeFieldResult dfr = token.getDescribe();
      if (!dfr.isCreateable()) {
        continue;
      }
      // State & Country picklists: writing both the integration-value text field
      // (e.g. BillingState) and its ISO-code picklist sibling (BillingStateCode)
      // triggers FIELD_INTEGRITY_EXCEPTION "Mismatched integration value and ISO
      // code". When the code sibling exists and is present in the payload, skip
      // the text field and let the platform derive it from the code.
      if (shouldSkipForStateCountryPicklist(fieldApi, fieldMap, values)) {
        continue;
      }
      Object raw = values.get(fieldApi);
      if (raw == null) {
        continue;
      }
      Object coerced = coerceValue(raw, dfr.getType());
      if (coerced == null) {
        continue;
      }
      try {
        restored.put(dfr.getSObjectField(), coerced);
        anyValueSet = true;
      } catch (Exception ignored) {
        // Skip values that cannot be assigned to the target field.
      }
    }

    // Owner reparenting: by default the running user owns the restored record;
    // when the profile requests it, restore the archived OwnerId instead.
    if (settings.reparentOwner && fieldMap.containsKey('ownerid') && values.get('OwnerId') != null) {
      try {
        restored.put('OwnerId', String.valueOf(values.get('OwnerId')));
      } catch (Exception ignored) {
        // Leave the running user as owner if the archived owner is invalid.
      }
    }

    if (!anyValueSet) {
      throw new AuraHandledException('No restorable field values were found for this archived record.');
    }

    // Conflict handling: locate an existing record using the match field
    // (defaults to the original record Id) and Skip / Overwrite / Clone per the
    // Restore Profile.
    SObject existing = findConflict(targetApi, settings.matchField, originalId, values);
    RestoreResult rr = new RestoreResult();
    rr.sourceObject = targetApi;
    rr.sourceObjectLabel = targetDescribe.getLabel();

    if (existing != null && settings.onConflict == 'Skip') {
      rr.skipped = true;
      rr.outcome = 'Skipped';
      rr.recordId = existing.Id;
      return rr;
    }

    Boolean priorBypass = BIGOTOOL_ChangeCapture.bypass;
    if (settings.bypassAutomation) {
      BIGOTOOL_ChangeCapture.bypass = true;
    }
    try {
      if (existing != null && settings.onConflict == 'Overwrite') {
        restored.put('Id', existing.Id);
        update restored;
        rr.outcome = 'Overwritten';
      } else {
        // Insert path for both no-conflict and the Clone strategy.
        insert restored;
        rr.outcome = existing != null ? 'Cloned' : 'Restored';
      }
    } catch (Exception e) {
      throw new AuraHandledException('Failed to restore record: ' + e.getMessage());
    } finally {
      BIGOTOOL_ChangeCapture.bypass = priorBypass;
    }

    rr.recordId = restored.Id;
    return rr;
  }

  /** Resolved restore behaviour with sensible defaults when no profile exists. */
  private class RestoreSettings {
    String targetObject;
    String matchField;
    String onConflict = 'Skip';
    Boolean reparentOwner = false;
    Boolean bypassAutomation = false;
  }

  /** Reads the first Restore Profile on the config and applies defaults. */
  private static RestoreSettings resolveRestoreSettings(Archive_Config__c cfg) {
    RestoreSettings s = new RestoreSettings();
    if (cfg.Restore_Profiles__r != null && !cfg.Restore_Profiles__r.isEmpty()) {
      Restore_Profile__c p = cfg.Restore_Profiles__r[0];
      s.targetObject = p.Target_Object__c;
      s.matchField = p.Match_Field__c;
      if (String.isNotBlank(p.On_Conflict__c)) {
        s.onConflict = p.On_Conflict__c;
      }
      s.reparentOwner = p.Reparent_Owner__c == true;
      s.bypassAutomation = p.Bypass_Automation__c == true;
    }
    return s;
  }

  /**
   * True when {@code fieldApi} is a State/Country integration-value text field
   * whose ISO-code picklist sibling ({@code fieldApi + 'Code'}) exists on the
   * target object and is present in the archived payload. Setting both halves
   * causes a mismatch error, so the text half is skipped in favour of the code.
   */
  private static Boolean shouldSkipForStateCountryPicklist(
    String fieldApi,
    Map<String, Schema.SObjectField> fieldMap,
    Map<String, Object> values
  ) {
    String codeApi = fieldApi + 'Code';
    Schema.SObjectField codeToken = fieldMap.get(codeApi.toLowerCase());
    if (codeToken == null) {
      return false;
    }
    if (codeToken.getDescribe().getType() != Schema.DisplayType.PICKLIST) {
      return false;
    }
    // Only skip when the code value is actually available to carry the data.
    return values.containsKey(codeApi) && values.get(codeApi) != null;
  }

  /** Finds a pre-existing target record for conflict handling, or null. */
  private static SObject findConflict(
    String targetApi,
    String matchField,
    String originalId,
    Map<String, Object> values
  ) {
    String field = String.isBlank(matchField) ? 'Id' : matchField.trim();
    Object matchValue = field.equalsIgnoreCase('Id') ? (Object) originalId : values.get(field);
    if (matchValue == null) {
      return null;
    }
    String q = 'SELECT Id FROM ' + targetApi + ' WHERE ' + field + ' = :matchValue LIMIT 1';
    try {
      List<SObject> found = Database.query(q);
      return found.isEmpty() ? null : found[0];
    } catch (Exception e) {
      // An invalid match field should not break the restore; treat as no match.
      return null;
    }
  }

  /** Coerces a JSON-deserialized value back to the native type of a source field. */
  @TestVisible
  private static Object coerceValue(Object raw, Schema.DisplayType type) {
    if (raw == null) {
      return null;
    }
    try {
      switch on type {
        when BOOLEAN {
          return raw instanceof Boolean ? raw : Boolean.valueOf(String.valueOf(raw));
        }
        when DATE {
          return (Date) JSON.deserialize(JSON.serialize(raw), Date.class);
        }
        when DATETIME {
          return (Datetime) JSON.deserialize(JSON.serialize(raw), Datetime.class);
        }
        when CURRENCY, DOUBLE, PERCENT {
          return raw instanceof Decimal ? raw : Decimal.valueOf(String.valueOf(raw));
        }
        when INTEGER, LONG {
          return raw instanceof Long ? raw : Long.valueOf(String.valueOf(raw));
        }
        when else {
          return String.valueOf(raw);
        }
      }
    } catch (Exception e) {
      // Values that cannot be parsed back into the field type are skipped.
    }
    return null;
  }

  // ---------------------------------------------------------------------------
  // Export
  // ---------------------------------------------------------------------------

  /** True when the running user holds the export custom permission. */
  @AuraEnabled(cacheable=true)
  public static Boolean canExport() {
    return FeatureManagement.checkPermission('BIGOTOOL_Can_Export');
  }

  /**
   * Builds a CSV of the full archive (up to MAX_EXPORT_ROWS) for the list-view
   * columns, honouring the same Original Record Id / date filters as the grid.
   * Gated by the BIGOTOOL_Can_Export custom permission. "Loaded data" exports
   * are built client-side from the already-fetched rows.
   */
  @AuraEnabled
  public static String exportCsv(Id configId, String originalIdFilter, Datetime fromDate, Datetime toDate) {
    if (!canExport()) {
      throw new AuraHandledException('You do not have permission to export archived data.');
    }
    Archive_Config__c cfg = loadConfig(configId);
    String boApi = bigObjectApi(cfg);
    List<LvColumn> columns = listColumns(cfg, boApi);

    String selectClause = String.join(selectColumns(columns, true), ', ');
    Boolean hasOriginalId = String.isNotBlank(originalIdFilter);
    Boolean hasDate = fromDate != null || toDate != null;
    List<SObject> rows;

    if (hasOriginalId) {
      String soql =
        'SELECT ' +
        selectClause +
        ' FROM ' +
        boApi +
        ' WHERE ' +
        BIGOTOOL_MetadataGenerator.FIELD_ORIGINAL_ID +
        ' = :originalIdFilter';
      if (fromDate != null) {
        soql += ' AND ' + BIGOTOOL_MetadataGenerator.FIELD_ARCHIVED_DATE + ' >= :fromDate';
      }
      if (toDate != null) {
        soql += ' AND ' + BIGOTOOL_MetadataGenerator.FIELD_ARCHIVED_DATE + ' <= :toDate';
      }
      soql += ' ORDER BY ' + BIGOTOOL_MetadataGenerator.FIELD_ARCHIVED_DATE + ' DESC';
      Integer cap = MAX_EXPORT_ROWS;
      soql += ' LIMIT :cap';
      rows = Database.query(soql);
    } else {
      String soql =
        'SELECT ' +
        selectClause +
        ' FROM ' +
        boApi +
        ' ORDER BY ' +
        BIGOTOOL_MetadataGenerator.FIELD_ORIGINAL_ID +
        ', ' +
        BIGOTOOL_MetadataGenerator.FIELD_ARCHIVED_DATE +
        ' DESC';
      Integer cap = MAX_EXPORT_ROWS;
      soql += ' LIMIT :cap';
      rows = Database.query(soql);
      if (hasDate) {
        rows = applyDateFilter(rows, fromDate, toDate);
      }
    }

    return buildCsv(rows, columns);
  }

  private static String buildCsv(List<SObject> rows, List<LvColumn> columns) {
    List<String> header = new List<String>{ 'Original Record Id', 'Archived Date' };
    for (LvColumn c : columns) {
      header.add(c.label);
    }
    List<String> lines = new List<String>();
    lines.add(toCsvLine(header));

    for (SObject r : rows) {
      ArchiveRow ar = toRow(r, columns);
      List<String> cells = new List<String>{
        ar.originalId,
        ar.archivedDate == null ? '' : ar.archivedDate.format('yyyy-MM-dd\'T\'HH:mm:ss\'Z\'', 'GMT')
      };
      for (LvColumn c : columns) {
        Object v = ar.values.get(c.fieldName);
        cells.add(v == null ? '' : String.valueOf(v));
      }
      lines.add(toCsvLine(cells));
    }
    return String.join(lines, '\n');
  }

  private static String toCsvLine(List<String> cells) {
    List<String> escaped = new List<String>();
    for (String c : cells) {
      escaped.add(escapeCsv(c));
    }
    return String.join(escaped, ',');
  }

  private static String escapeCsv(String value) {
    if (value == null) {
      return '';
    }
    if (value.contains('"') || value.contains(',') || value.contains('\n') || value.contains('\r')) {
      return '"' + value.replace('"', '""') + '"';
    }
    return value;
  }

  // ---------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------

  private static Archive_Config__c loadConfig(Id configId) {
    if (configId == null) {
      throw new AuraHandledException('An Archive Configuration is required.');
    }
    List<Archive_Config__c> cfgs = [
      SELECT
        Id,
        Source_Object__c,
        Big_Object_Api_Name__c,
        List_View_Fields__c,
        (
          SELECT Field_API_Name__c, Field_Label__c, Field_Type__c, Is_List_View__c
          FROM Archive_Fields__r
          ORDER BY Field_API_Name__c ASC
        ),
        (
          SELECT Id, Name, Target_Object__c, Match_Field__c, On_Conflict__c, Reparent_Owner__c, Bypass_Automation__c
          FROM Restore_Profiles__r
          ORDER BY CreatedDate ASC
          LIMIT 1
        )
      FROM Archive_Config__c
      WHERE Id = :configId
      LIMIT 1
    ];
    if (cfgs.isEmpty()) {
      throw new AuraHandledException('Archive Configuration not found.');
    }
    return cfgs[0];
  }

  private static String bigObjectApi(Archive_Config__c cfg) {
    return String.isNotBlank(cfg.Big_Object_Api_Name__c)
      ? cfg.Big_Object_Api_Name__c
      : BIGOTOOL_MetadataGenerator.bigObjectApiName(cfg.Source_Object__c);
  }

  private static List<String> jsonColumns() {
    return new List<String>{
      BIGOTOOL_MetadataGenerator.FIELD_ORIGINAL_ID,
      BIGOTOOL_MetadataGenerator.FIELD_ARCHIVED_DATE,
      BIGOTOOL_MetadataGenerator.FIELD_DATA,
      BIGOTOOL_MetadataGenerator.FIELD_LONG_TEXT_DATA,
      BIGOTOOL_MetadataGenerator.FIELD_OVERFLOW_DATA
    };
  }

  private static ArchiveRow toRow(SObject r, List<LvColumn> columns) {
    ArchiveRow ar = new ArchiveRow();
    ar.originalId = String.valueOf(r.get(BIGOTOOL_MetadataGenerator.FIELD_ORIGINAL_ID));
    ar.archivedDate = (Datetime) r.get(BIGOTOOL_MetadataGenerator.FIELD_ARCHIVED_DATE);
    ar.rowKey = ar.originalId + '|' + (ar.archivedDate == null ? '' : String.valueOf(ar.archivedDate.getTime()));

    // Only parse the JSON columns when at least one column is not materialized
    // as a physical Big Object field (legacy / not-yet-regenerated configs).
    Boolean needsJson = false;
    if (columns != null) {
      for (LvColumn c : columns) {
        if (c.physical != true) {
          needsJson = true;
          break;
        }
      }
    }
    Map<String, Object> jsonValues = needsJson ? mergeValues(r) : new Map<String, Object>();

    if (columns != null) {
      for (LvColumn c : columns) {
        Object v;
        if (c.physical == true) {
          v = r.get(c.columnApi);
        } else {
          v = jsonValues.get(c.sourceField);
        }
        ar.values.put(c.fieldName, v == null ? null : String.valueOf(v));
      }
    }
    return ar;
  }

  /** Reassembles the source field values from the three JSON columns. */
  @TestVisible
  private static Map<String, Object> mergeValues(SObject r) {
    Map<String, Object> merged = new Map<String, Object>();
    String scalarJson = (String) r.get(BIGOTOOL_MetadataGenerator.FIELD_DATA);
    if (String.isNotBlank(scalarJson)) {
      merged.putAll((Map<String, Object>) JSON.deserializeUntyped(scalarJson));
    }
    String longJson = (String) r.get(BIGOTOOL_MetadataGenerator.FIELD_LONG_TEXT_DATA);
    String overflow = (String) r.get(BIGOTOOL_MetadataGenerator.FIELD_OVERFLOW_DATA);
    String combined = (String.isBlank(longJson) ? '' : longJson) + (String.isBlank(overflow) ? '' : overflow);
    if (String.isNotBlank(combined)) {
      try {
        merged.putAll((Map<String, Object>) JSON.deserializeUntyped(combined));
      } catch (Exception ignored) {
        // Malformed/partial long-text JSON is non-fatal for display.
      }
    }
    return merged;
  }

  /** Maps a Salesforce DisplayType name to a lightning-datatable column type. */
  @TestVisible
  private static String datatableType(String displayType) {
    if (String.isBlank(displayType)) {
      return 'text';
    }
    String dt = displayType.toUpperCase();
    if (dt == 'BOOLEAN') {
      return 'boolean';
    }
    if (dt == 'CURRENCY') {
      return 'currency';
    }
    if (dt == 'PERCENT') {
      return 'percent';
    }
    if (dt == 'DOUBLE' || dt == 'INTEGER' || dt == 'LONG') {
      return 'number';
    }
    if (dt == 'DATE') {
      return 'date-local';
    }
    if (dt == 'DATETIME') {
      return 'date';
    }
    if (dt == 'EMAIL') {
      return 'email';
    }
    if (dt == 'PHONE') {
      return 'phone';
    }
    if (dt == 'URL') {
      return 'url';
    }
    return 'text';
  }

  @TestVisible
  private static List<String> splitCsv(String csv) {
    List<String> out = new List<String>();
    if (String.isBlank(csv)) {
      return out;
    }
    for (String part : csv.split(',')) {
      String trimmed = part.trim();
      if (String.isNotBlank(trimmed)) {
        out.add(trimmed);
      }
    }
    return out;
  }

  public class RowDateComparator implements Comparator<ArchiveRow> {
    public Integer compare(ArchiveRow a, ArchiveRow b) {
      Long ta = a.archivedDate == null ? 0 : a.archivedDate.getTime();
      Long tb = b.archivedDate == null ? 0 : b.archivedDate.getTime();
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
