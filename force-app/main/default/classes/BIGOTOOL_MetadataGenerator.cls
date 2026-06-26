/**
 * BIGOTOOL_MetadataGenerator
 *
 * Generation engine for the Big Object Tooling package. Given a Pending
 * Archive_Config__c, it dynamically creates the backing Big Object (fields +
 * composite index), a CustomTab and an "All" ListView through the Salesforce
 * Metadata API (Certinia apex-mdapi MetadataService), then schedules the
 * reusable archive batch.
 *
 * Important platform notes:
 *  - All Metadata API calls are SOAP callouts; callers must perform DML only
 *    AFTER invoking this engine within the same transaction.
 *  - The newly created Big Object is NOT visible to Apex describe in the same
 *    transaction, so the batch is scheduled (a later transaction) rather than
 *    executed inline.
 *  - Self callouts authenticate with UserInfo.getSessionId(); a Remote Site
 *    Setting for the org domain is required. If the Lightning session is not
 *    API-enabled, configure a Named Credential and point ENDPOINT at it.
 */
public with sharing class BIGOTOOL_MetadataGenerator {
  private static final String METADATA_API_VERSION = '60.0';

  // Fixed Big Object schema. Source field values are serialized into a small set
  // of JSON columns rather than mirroring every source field one-to-one.
  public static final String FIELD_ORIGINAL_ID = 'OriginalId__c';
  public static final String FIELD_ARCHIVED_DATE = 'ArchivedDate__c';
  // JSON of all non-(long text area) field values.
  public static final String FIELD_DATA = 'FieldData__c';
  // JSON of all long text area / rich text field values.
  public static final String FIELD_LONG_TEXT_DATA = 'LongTextData__c';
  // Overflow continuation for long text data that exceeds a single column.
  public static final String FIELD_OVERFLOW_DATA = 'OverflowData__c';
  public static final Integer LONG_TEXT_LENGTH = 131072;

  /** Result returned to the controller / UI. */
  public class GenerationResult {
    @AuraEnabled
    public Boolean success;
    @AuraEnabled
    public String bigObjectApiName;
    @AuraEnabled
    public String tabName;
    @AuraEnabled
    public List<String> messages;
    @AuraEnabled
    public List<String> warnings;

    public GenerationResult() {
      this.success = true;
      this.messages = new List<String>();
      this.warnings = new List<String>();
    }
  }

  /**
   * Orchestrates metadata creation for the supplied config. Performs only
   * callouts (no DML) so the caller can safely update the record afterwards.
   */
  public static GenerationResult generate(Archive_Config__c config) {
    if (config == null) {
      throw new GenerationException('A configuration record is required.');
    }
    GenerationResult result = new GenerationResult();
    String bigObjectApi = String.isNotBlank(config.Big_Object_Api_Name__c)
      ? config.Big_Object_Api_Name__c
      : bigObjectApiName(config.Source_Object__c);
    result.bigObjectApiName = bigObjectApi;

    // List-view fields are stored as flagged Archive_Field__c child records and
    // materialized as their own physical Big Object columns.
    List<String> listViewFields = listViewSourceFields(config);

    MetadataService.MetadataPort service = createService();

    // 1. Big Object (fields + composite index) in a single create.
    MetadataService.CustomObject bigObject = buildBigObject(config, bigObjectApi, listViewFields);
    handleSaveResults(
      service.createMetadata(new List<MetadataService.Metadata>{ bigObject }),
      result,
      'Big Object ' + bigObjectApi
    );

    // 2. Lightning App Page (FlexiPage) that embeds the generic
    // bigotoolArchiveListView component bound to this Big Object, exposed via a
    // Custom Tab so admins can browse the archived rows.
    //
    // NOTE: Salesforce does not support object-backed Custom Tabs for Big
    // Objects, but a FlexiPage (Lightning Page) tab is fully supported.
    String pageName = cleanDevName(bigObjectApi);
    try {
      MetadataService.FlexiPage flexiPage = buildArchiveFlexiPage(config, bigObjectApi, pageName);
      handleSaveResults(
        service.createMetadata(new List<MetadataService.Metadata>{ flexiPage }),
        result,
        'Lightning Page ' + pageName
      );

      MetadataService.CustomTab tab = buildFlexiPageTab(pageName, config.Source_Object__c);
      handleSaveResults(service.createMetadata(new List<MetadataService.Metadata>{ tab }), result, 'Tab ' + pageName);
      result.tabName = pageName;
    } catch (Exception e) {
      result.warnings.add('Archive viewer tab could not be created: ' + e.getMessage());
    }

    // 3. Permission Set granting read access to the new Big Object (object + FLS)
    // and visibility of its tab. Access to archived data is now governed solely
    // by this generated permission set rather than a custom-setting whitelist.
    try {
      MetadataService.PermissionSet permSet = buildArchivePermissionSet(
        config,
        bigObjectApi,
        listViewFields,
        pageName,
        String.isNotBlank(result.tabName)
      );
      handleSaveResults(
        service.createMetadata(new List<MetadataService.Metadata>{ permSet }),
        result,
        'Permission Set ' + permSet.fullName
      );
    } catch (Exception e) {
      result.warnings.add('Permission set could not be created: ' + e.getMessage());
    }

    // 4. Schedule the reusable archive batch (runs in a later transaction).
    try {
      scheduleBatch(config);
    } catch (Exception e) {
      result.warnings.add('Batch job could not be scheduled: ' + e.getMessage());
    }

    return result;
  }

  public class SessionId {
    public string sessionId;
  }
  /** Builds an API-enabled Metadata service bound to the running user session. */
  public static MetadataService.MetadataPort createService() {
    SessionId sessionJson = new SessionId();
    if (!Test.isRunningTest()) {
      sessionJson = (SessionId) JSON.deserialize(Page.BIGOTOOL_SessionId.getContent().toString(), SessionId.class);
    }
    MetadataService.MetadataPort service = new MetadataService.MetadataPort();
    service.SessionHeader = new MetadataService.SessionHeader_element();

    service.SessionHeader.sessionId = sessionJson.sessionId;
    service.endpoint_x = URL.getOrgDomainUrl().toExternalForm() + '/services/Soap/m/' + METADATA_API_VERSION;
    service.timeout_x = 120000;
    // Big Objects require AllOrNoneHeader=true for CRUD-based metadata calls.
    service.AllOrNoneHeader = new MetadataService.AllOrNoneHeader_element();
    service.AllOrNoneHeader.allOrNone = true;
    return service;
  }

  // ---------------------------------------------------------------------------
  // Metadata builders
  // ---------------------------------------------------------------------------

  private static MetadataService.CustomObject buildBigObject(
    Archive_Config__c config,
    String bigObjectApi,
    List<String> listViewFields
  ) {
    String sourceLabel = objectLabel(config.Source_Object__c);

    MetadataService.CustomObject obj = new MetadataService.CustomObject();
    obj.fullName = bigObjectApi;
    obj.label = 'Archived ' + sourceLabel;
    obj.pluralLabel = 'Archived ' + sourceLabel;
    obj.deploymentStatus = 'Deployed';
    obj.description = 'Archive store generated by Big Object Tooling for ' + config.Source_Object__c + '.';

    // NOTE: custom Big Objects do not have a Name field, so nameField must NOT
    // be specified (the Metadata API rejects it with a FIELD_INTEGRITY_EXCEPTION).

    List<MetadataService.CustomField> fields = new List<MetadataService.CustomField>();

    // Index/key fields - both required so they can participate in the index.
    // NOTE: when a CustomField is created as a child of a CustomObject in the
    // same request, its fullName must be the bare field name (no object prefix);
    // a dot in a child fullName is rejected by the Metadata API.
    MetadataService.CustomField originalId = new MetadataService.CustomField();
    originalId.fullName = FIELD_ORIGINAL_ID;
    originalId.label = 'Original Record Id';
    originalId.type_x = 'Text';
    originalId.length = 18;
    originalId.required = true;
    fields.add(originalId);

    MetadataService.CustomField archivedDate = new MetadataService.CustomField();
    archivedDate.fullName = FIELD_ARCHIVED_DATE;
    archivedDate.label = 'Archived Date';
    archivedDate.type_x = 'DateTime';
    archivedDate.required = true;
    fields.add(archivedDate);

    // Three JSON columns hold the full archived field values (for the dynamic
    // record viewer) instead of mirroring every source field as its own column.
    fields.add(buildLongTextField(FIELD_DATA, 'Field Data'));
    fields.add(buildLongTextField(FIELD_LONG_TEXT_DATA, 'Long Text Data'));
    fields.add(buildLongTextField(FIELD_OVERFLOW_DATA, 'Overflow Data'));

    // List-view fields are materialized as their own physical Text columns so the
    // generic list view can query and display them directly (rather than parsing
    // JSON). They are restricted upstream to non long text area / non lookup
    // fields, so a Text(255) column safely holds the displayed value.
    Set<String> reserved = new Set<String>{
      FIELD_ORIGINAL_ID.toLowerCase(),
      FIELD_ARCHIVED_DATE.toLowerCase(),
      FIELD_DATA.toLowerCase(),
      FIELD_LONG_TEXT_DATA.toLowerCase(),
      FIELD_OVERFLOW_DATA.toLowerCase()
    };
    Set<String> emitted = new Set<String>();
    if (listViewFields != null) {
      for (String src : listViewFields) {
        if (String.isBlank(src)) {
          continue;
        }
        String colApi = archiveFieldApiName(src);
        String key = colApi.toLowerCase();
        if (reserved.contains(key) || emitted.contains(key)) {
          continue;
        }
        emitted.add(key);
        MetadataService.CustomField col = new MetadataService.CustomField();
        col.fullName = colApi;
        col.label = src.length() > 40 ? src.substring(0, 40) : src;
        col.type_x = 'Text';
        col.length = 255;
        fields.add(col);
      }
    }

    obj.fields = fields;

    // Composite index across the key fields.
    MetadataService.IndexField idxOriginal = new MetadataService.IndexField();
    idxOriginal.name = FIELD_ORIGINAL_ID;
    idxOriginal.sortDirection = 'ASC';
    MetadataService.IndexField idxDate = new MetadataService.IndexField();
    idxDate.name = FIELD_ARCHIVED_DATE;
    idxDate.sortDirection = 'DESC';

    MetadataService.Index index = new MetadataService.Index();
    index.label = 'Archive Index';

    index.fields = new List<MetadataService.IndexField>{ idxOriginal, idxDate };
    obj.indexes = new List<MetadataService.Index>{ index };

    return obj;
  }

  /**
   * Returns the source field API names flagged as list-view columns for the
   * config (Archive_Field__c.Is_List_View__c = true).
   */
  @TestVisible
  private static List<String> listViewSourceFields(Archive_Config__c config) {
    List<String> result = new List<String>();
    if (config != null && config.Id != null) {
      for (Archive_Field__c af : [
        SELECT Field_API_Name__c
        FROM Archive_Field__c
        WHERE Archive_Config__c = :config.Id AND Is_List_View__c = TRUE
        ORDER BY Field_API_Name__c ASC
      ]) {
        if (String.isNotBlank(af.Field_API_Name__c)) {
          result.add(af.Field_API_Name__c);
        }
      }
    }
    return result;
  }

  private static MetadataService.CustomField buildLongTextField(String apiName, String label) {
    MetadataService.CustomField f = new MetadataService.CustomField();
    f.fullName = apiName;
    f.label = label;
    f.type_x = 'LongTextArea';
    f.length = LONG_TEXT_LENGTH;
    f.visibleLines = 10;
    return f;
  }

  /**
   * Builds a Lightning App Page that hosts the generic archive list view
   * component, bound to this Big Object via the bigObjectApiName property.
   */
  private static MetadataService.FlexiPage buildArchiveFlexiPage(
    Archive_Config__c config,
    String bigObjectApi,
    String pageName
  ) {
    MetadataService.ComponentInstanceProperty prop = new MetadataService.ComponentInstanceProperty();
    prop.name = 'bigObjectApiName';
    prop.value = bigObjectApi;

    MetadataService.ComponentInstance ci = new MetadataService.ComponentInstance();
    ci.componentName = 'c:bigotoolArchiveListView';
    ci.identifier = cleanDevName(bigObjectApi) + '_listView';
    ci.componentInstanceProperties = new List<MetadataService.ComponentInstanceProperty>{ prop };

    MetadataService.ItemInstance item = new MetadataService.ItemInstance();
    item.componentInstance = ci;

    MetadataService.FlexiPageRegion region = new MetadataService.FlexiPageRegion();
    region.name = 'main';
    region.type_x = 'Region';
    region.itemInstances = new List<MetadataService.ItemInstance>{ item };

    MetadataService.FlexiPageTemplateInstance template = new MetadataService.FlexiPageTemplateInstance();
    template.name = 'flexipage:defaultAppHomeTemplate';

    MetadataService.FlexiPage fp = new MetadataService.FlexiPage();
    fp.fullName = pageName;
    fp.masterLabel = 'Archived ' + objectLabel(config.Source_Object__c);
    fp.type_x = 'AppPage';
    fp.flexiPageRegions = new List<MetadataService.FlexiPageRegion>{ region };
    fp.template = template;
    return fp;
  }

  /** Builds a Custom Tab that surfaces the generated archive Lightning Page. */
  private static MetadataService.CustomTab buildFlexiPageTab(String pageName, String sourceObject) {
    MetadataService.CustomTab tab = new MetadataService.CustomTab();
    tab.fullName = pageName;
    tab.flexiPage = pageName;
    tab.label = 'Archive ' + objectLabel(sourceObject);
    tab.motif = 'Custom53: Bank';
    return tab;
  }

  /**
   * Builds a per-Big-Object Permission Set that grants:
   *   - read on the generated Big Object (object permission),
   *   - field-level read on every generated column (JSON payload columns plus
   *     any materialized list-view columns),
   *   - visibility of the generated archive tab.
   *
   * The two required index fields (OriginalId__c / ArchivedDate__c) are always
   * visible with object read and are intentionally omitted from fieldPermissions
   * because the Metadata API rejects FLS entries for required fields.
   */
  private static MetadataService.PermissionSet buildArchivePermissionSet(
    Archive_Config__c config,
    String bigObjectApi,
    List<String> listViewFields,
    String tabName,
    Boolean includeTab
  ) {
    String sourceLabel = objectLabel(config.Source_Object__c);

    MetadataService.PermissionSet ps = new MetadataService.PermissionSet();
    ps.fullName = permissionSetApiName(bigObjectApi);
    ps.label = clipLabel('Archive Access - ' + sourceLabel);
    ps.hasActivationRequired = false;
    ps.description =
      'Auto-generated read access to the ' +
      bigObjectApi +
      ' archive Big Object and its tab for ' +
      config.Source_Object__c +
      '.';

    MetadataService.PermissionSetObjectPermissions op = new MetadataService.PermissionSetObjectPermissions();
    op.object_x = bigObjectApi;
    op.allowRead = true;
    op.allowCreate = false;
    op.allowEdit = false;
    op.allowDelete = false;
    op.modifyAllRecords = false;
    op.viewAllRecords = true;
    ps.objectPermissions = new List<MetadataService.PermissionSetObjectPermissions>{ op };

    List<MetadataService.PermissionSetFieldPermissions> fps = new List<MetadataService.PermissionSetFieldPermissions>();
    Set<String> emitted = new Set<String>();
    // JSON payload columns that always exist on a generated Big Object.
    for (String col : new List<String>{ FIELD_DATA, FIELD_LONG_TEXT_DATA, FIELD_OVERFLOW_DATA }) {
      fps.add(buildFieldPermission(bigObjectApi, col));
      emitted.add(col.toLowerCase());
    }
    // Physical list-view columns.
    if (listViewFields != null) {
      for (String src : listViewFields) {
        if (String.isBlank(src)) {
          continue;
        }
        String colApi = archiveFieldApiName(src);
        if (emitted.contains(colApi.toLowerCase())) {
          continue;
        }
        emitted.add(colApi.toLowerCase());
        fps.add(buildFieldPermission(bigObjectApi, colApi));
      }
    }
    ps.fieldPermissions = fps;

    if (includeTab && String.isNotBlank(tabName)) {
      MetadataService.PermissionSetTabSetting tab = new MetadataService.PermissionSetTabSetting();
      tab.tab = tabName;
      tab.visibility = 'Visible';
      ps.tabSettings = new List<MetadataService.PermissionSetTabSetting>{ tab };
    }

    return ps;
  }

  private static MetadataService.PermissionSetFieldPermissions buildFieldPermission(
    String bigObjectApi,
    String fieldApi
  ) {
    MetadataService.PermissionSetFieldPermissions fp = new MetadataService.PermissionSetFieldPermissions();
    fp.field = bigObjectApi + '.' + fieldApi;
    fp.readable = true;
    fp.editable = false;
    return fp;
  }

  /** Deterministic Permission Set API name for a generated Big Object. */
  public static String permissionSetApiName(String bigObjectApi) {
    String base = cleanDevName(bigObjectApi);
    if (String.isBlank(base)) {
      base = 'Object';
    }
    return 'BIGOTOOL_' + base;
  }

  /** Permission set labels are capped at 80 characters by the platform. */
  private static String clipLabel(String label) {
    if (String.isBlank(label)) {
      return label;
    }
    return label.length() > 80 ? label.substring(0, 80) : label;
  }

  /**
   * Derives a valid Developer Name (FlexiPage / Custom Tab) from a Big Object
   * API name: strips the "__b" suffix and collapses/trims illegal underscore
   * runs so the name does not contain consecutive or trailing underscores.
   */
  @TestVisible
  private static String cleanDevName(String bigObjectApi) {
    String name = bigObjectApi == null ? '' : bigObjectApi.trim();
    if (name.endsWithIgnoreCase('__b')) {
      name = name.substring(0, name.length() - 3);
    }
    name = name.replaceAll('_+', '_').replaceAll('^_+', '').replaceAll('_+$', '');
    if (String.isBlank(name) || !name.substring(0, 1).isAlpha()) {
      name = 'Archive' + (String.isBlank(name) ? '' : '_' + name);
    }
    return name;
  }

  // ---------------------------------------------------------------------------
  // Batch scheduling
  // ---------------------------------------------------------------------------

  private static void scheduleBatch(Archive_Config__c config) {
    if (Test.isRunningTest()) {
      return;
    }
    String cron = String.isNotBlank(config.Schedule_Cron__c) ? config.Schedule_Cron__c : defaultCron();
    String jobName = 'BIGOTOOL Archive ' + config.Id;
    System.schedule(jobName, cron, new BIGOTOOL_ArchiveSchedulable(config.Id));
  }

  /** Default schedule: a few minutes from now, one-off, to let metadata commit. */
  private static String defaultCron() {
    Datetime fireAt = System.now().addMinutes(5);
    return '' +
      fireAt.second() +
      ' ' +
      fireAt.minute() +
      ' ' +
      fireAt.hour() +
      ' ' +
      fireAt.day() +
      ' ' +
      fireAt.month() +
      ' ? ' +
      fireAt.year();
  }

  // ---------------------------------------------------------------------------
  // Result handling
  // ---------------------------------------------------------------------------

  private static void handleSaveResults(
    List<MetadataService.SaveResult> results,
    GenerationResult result,
    String label
  ) {
    if (results == null || results.isEmpty()) {
      throw new GenerationException(label + ': no response from Metadata API.');
    }
    for (MetadataService.SaveResult sr : results) {
      if (sr.success) {
        result.messages.add('Created ' + label + '.');
        continue;
      }
      String detail = '';
      if (sr.errors != null) {
        for (MetadataService.Error err : sr.errors) {
          detail += (String.isBlank(detail) ? '' : '; ') + err.statusCode + ': ' + err.message;
        }
      }
      throw new GenerationException(label + ' failed - ' + detail);
    }
  }

  // ---------------------------------------------------------------------------
  // Shared helpers (also used by the batch)
  // ---------------------------------------------------------------------------

  /** Derives the Big Object API name from a source object: Archive_<base>__b. */
  public static String bigObjectApiName(String sourceObject) {
    String base = sourceObject == null ? '' : sourceObject;
    if (base.endsWithIgnoreCase('__c')) {
      base = base.substring(0, base.length() - 3);
    }
    base = base.replaceAll('[^a-zA-Z0-9]', '');
    if (String.isBlank(base)) {
      base = 'Object';
    }
    return 'Archive_' + base + '__b';
  }

  /** Deterministic Big Object field API name for a given source field. */
  public static String archiveFieldApiName(String sourceField) {
    String base = sourceField == null ? '' : sourceField.trim();
    if (base.endsWithIgnoreCase('__c')) {
      base = base.substring(0, base.length() - 3);
    }
    base = base.replaceAll('[^a-zA-Z0-9]', '');
    if (String.isBlank(base)) {
      base = 'Field';
    }
    return base + '__c';
  }

  private static String baseName(String bigObjectApi) {
    // Retained for potential future index-naming needs.
    String base = bigObjectApi;
    if (base.endsWithIgnoreCase('__b')) {
      base = base.substring(0, base.length() - 3);
    }
    return base.replaceAll('[^a-zA-Z0-9]', '');
  }

  public static List<String> splitCsv(String csv) {
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

  private static String objectLabel(String apiName) {
    Schema.SObjectType t = Schema.getGlobalDescribe().get(apiName);
    return t == null ? apiName : t.getDescribe().getLabel();
  }

  public class GenerationException extends Exception {
  }
}
