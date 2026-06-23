/**
 * Server controller for the Archive Wizard LWC (bigotoolArchiveWizard).
 *
 * Drives a guided, point-and-click setup that produces an Archive_Config__c
 * record (and optionally a linked Restore_Profile__c). It exposes object/field
 * metadata pickers, a live "matching records" preview built from the configured
 * age/SOQL criteria, and a transactional save.
 *
 * Actual metadata generation (Big Object, batch, tab, list view) is performed by
 * the separate generation engine; this wizard captures the configuration and
 * leaves Generation_Status__c = 'Pending'.
 */
public with sharing class BIGOTOOL_ArchiveWizardController {
  @TestVisible
  private static final Set<String> CRITERIA_TYPES = new Set<String>{ 'Age', 'SOQL_Filter', 'Both' };
  @TestVisible
  private static final Set<String> CONFLICT_MODES = new Set<String>{ 'Skip', 'Overwrite', 'Clone' };

  public class PicklistOption {
    @AuraEnabled
    public String label;
    @AuraEnabled
    public String value;
    public PicklistOption(String label, String value) {
      this.label = label;
      this.value = value;
    }
  }

  public class FieldOption {
    @AuraEnabled
    public String label;
    @AuraEnabled
    public String apiName;
    @AuraEnabled
    public String dataType;
    public FieldOption(String label, String apiName, String dataType) {
      this.label = label;
      this.apiName = apiName;
      this.dataType = dataType;
    }
  }

  public class RestoreProfileInput {
    @AuraEnabled
    public Id profileId;
    @AuraEnabled
    public String name;
    @AuraEnabled
    public String matchField;
    @AuraEnabled
    public String onConflict;
    @AuraEnabled
    public Boolean reparentOwner;
    @AuraEnabled
    public Boolean bypassAutomation;
  }

  public class ConfigInput {
    @AuraEnabled
    public Id configId;
    @AuraEnabled
    public String configName;
    @AuraEnabled
    public String sourceObject;
    @AuraEnabled
    public Boolean isActive;
    @AuraEnabled
    public String criteriaType;
    @AuraEnabled
    public String ageField;
    @AuraEnabled
    public Decimal ageThresholdDays;
    @AuraEnabled
    public String filterLogic;
    @AuraEnabled
    public List<String> listViewFields;
    @AuraEnabled
    public Boolean deleteAfterArchive;
    @AuraEnabled
    public Decimal batchSize;
    @AuraEnabled
    public String scheduleCron;
    @AuraEnabled
    public RestoreProfileInput restoreProfile;
  }

  public class ConfigDetail {
    @AuraEnabled
    public Id configId;
    @AuraEnabled
    public String configName;
    @AuraEnabled
    public String sourceObject;
    @AuraEnabled
    public Boolean isActive;
    @AuraEnabled
    public String criteriaType;
    @AuraEnabled
    public String ageField;
    @AuraEnabled
    public Decimal ageThresholdDays;
    @AuraEnabled
    public String filterLogic;
    @AuraEnabled
    public List<String> listViewFields;
    @AuraEnabled
    public Boolean deleteAfterArchive;
    @AuraEnabled
    public Decimal batchSize;
    @AuraEnabled
    public String scheduleCron;
    @AuraEnabled
    public String bigObjectApiName;
    @AuraEnabled
    public RestoreProfileInput restoreProfile;
  }

  private static void assertCanConfigure() {
    if (!FeatureManagement.checkPermission('BIGOTOOL_Can_Configure')) {
      throw new AuraHandledException('You do not have permission to configure archiving.');
    }
  }

  @AuraEnabled(cacheable=true)
  public static List<PicklistOption> getObjectOptions() {
    assertCanConfigure();
    List<PicklistOption> options = new List<PicklistOption>();
    for (Schema.SObjectType t : Schema.getGlobalDescribe().values()) {
      Schema.DescribeSObjectResult d = t.getDescribe();
      if (!d.isQueryable() || !d.isDeletable() || d.isCustomSetting()) {
        continue;
      }
      String associateType = d.getAssociateEntityType();
      if (associateType == 'Share' || associateType == 'History' || associateType == 'Feed' || associateType == 'ChangeEvent') {
        continue;
      }
      String apiName = d.getName();
      if (
        apiName.endsWith('__b') ||
        apiName.endsWith('__e') ||
        apiName.endsWith('__mdt') ||
        apiName.endsWith('__x') ||
        apiName.endsWith('Share') ||
        apiName.endsWith('History') ||
        apiName.endsWith('Feed') ||
        apiName.endsWith('ChangeEvent') ||
        apiName.endsWith('__Tag')
      ) {
        continue;
      }
      options.add(new PicklistOption(d.getLabel() + ' (' + apiName + ')', apiName));
    }
    options.sort(new OptionLabelComparator());
    return options;
  }

  @AuraEnabled(cacheable=true)
  public static List<FieldOption> getFieldOptions(String objectApiName) {
    assertCanConfigure();
    if (String.isBlank(objectApiName)) {
      throw new AuraHandledException('Object API name is required.');
    }
    Schema.SObjectType t = Schema.getGlobalDescribe().get(objectApiName);
    if (t == null) {
      throw new AuraHandledException('Unknown object: ' + objectApiName);
    }
    List<FieldOption> options = new List<FieldOption>();
    for (Schema.SObjectField f : t.getDescribe().fields.getMap().values()) {
      Schema.DescribeFieldResult fd = f.getDescribe();
      if (!fd.isAccessible()) {
        continue;
      }
      Schema.DisplayType dt = fd.getType();
      if (dt == Schema.DisplayType.ADDRESS || dt == Schema.DisplayType.LOCATION || dt == Schema.DisplayType.BASE64) {
        continue;
      }
      options.add(new FieldOption(fd.getLabel(), fd.getName(), String.valueOf(dt)));
    }
    options.sort(new FieldLabelComparator());
    return options;
  }

  /** Date/DateTime fields eligible for age-based criteria. */
  @AuraEnabled(cacheable=true)
  public static List<FieldOption> getDateFieldOptions(String objectApiName) {
    assertCanConfigure();
    if (String.isBlank(objectApiName)) {
      throw new AuraHandledException('Object API name is required.');
    }
    Schema.SObjectType t = Schema.getGlobalDescribe().get(objectApiName);
    if (t == null) {
      throw new AuraHandledException('Unknown object: ' + objectApiName);
    }
    List<FieldOption> options = new List<FieldOption>();
    for (Schema.SObjectField f : t.getDescribe().fields.getMap().values()) {
      Schema.DescribeFieldResult fd = f.getDescribe();
      if (!fd.isAccessible()) {
        continue;
      }
      Schema.DisplayType dt = fd.getType();
      if (dt == Schema.DisplayType.DATE || dt == Schema.DisplayType.DATETIME) {
        options.add(new FieldOption(fd.getLabel(), fd.getName(), String.valueOf(dt)));
      }
    }
    options.sort(new FieldLabelComparator());
    return options;
  }

  /**
   * Fields eligible to use as a restore "match" (dedupe) key. Always includes
   * the record Id, plus any externally-unique or unique fields on the object.
   */
  @AuraEnabled(cacheable=true)
  public static List<FieldOption> getUniqueFieldOptions(String objectApiName) {
    assertCanConfigure();
    if (String.isBlank(objectApiName)) {
      throw new AuraHandledException('Object API name is required.');
    }
    Schema.SObjectType t = Schema.getGlobalDescribe().get(objectApiName);
    if (t == null) {
      throw new AuraHandledException('Unknown object: ' + objectApiName);
    }
    List<FieldOption> options = new List<FieldOption>();
    options.add(new FieldOption('Record Id', 'Id', 'ID'));
    for (Schema.SObjectField f : t.getDescribe().fields.getMap().values()) {
      Schema.DescribeFieldResult fd = f.getDescribe();
      if (!fd.isAccessible() || fd.getName() == 'Id') {
        continue;
      }
      if (fd.isUnique() || fd.isExternalId() || fd.isIdLookup()) {
        options.add(new FieldOption(fd.getLabel(), fd.getName(), String.valueOf(fd.getType())));
      }
    }
    options.sort(new FieldLabelComparator());
    return options;
  }

  @AuraEnabled(cacheable=true)
  public static List<PicklistOption> getRestoreProfiles() {
    assertCanConfigure();
    List<PicklistOption> options = new List<PicklistOption>();
    for (Restore_Profile__c rp : [SELECT Id, Name FROM Restore_Profile__c ORDER BY Name LIMIT 1000]) {
      options.add(new PicklistOption(rp.Name, rp.Id));
    }
    return options;
  }

  /**
   * Returns an estimated count of records matching the wizard criteria. Built
   * with a dynamic COUNT() query; any SOQL/validation error is surfaced as a
   * friendly message so the UI can warn without blocking the wizard.
   */
  @AuraEnabled
  public static Integer previewMatchingCount(String inputJson) {
    assertCanConfigure();
    ConfigInput input = (ConfigInput) JSON.deserialize(inputJson, ConfigInput.class);
    if (input == null || String.isBlank(input.sourceObject)) {
      throw new AuraHandledException('A source object is required.');
    }
    String whereClause = buildWhereClause(input);
    String soql = 'SELECT COUNT() FROM ' + String.escapeSingleQuotes(input.sourceObject);
    if (String.isNotBlank(whereClause)) {
      soql += ' WHERE ' + whereClause;
    }
    try {
      return Database.countQuery(soql);
    } catch (Exception e) {
      throw new AuraHandledException('Could not evaluate criteria: ' + e.getMessage());
    }
  }

  /**
   * Assembles the WHERE clause from age and/or SOQL filter criteria. Exposed for
   * unit testing the criteria compilation independent of any DML.
   */
  @TestVisible
  private static String buildWhereClause(ConfigInput input) {
    List<String> clauses = new List<String>();
    String type = String.isBlank(input.criteriaType) ? 'Age' : input.criteriaType;

    Boolean useAge = type == 'Age' || type == 'Both';
    Boolean useFilter = type == 'SOQL_Filter' || type == 'Both';

    if (useAge && String.isNotBlank(input.ageField) && input.ageThresholdDays != null && input.ageThresholdDays > 0) {
      Integer days = Integer.valueOf(input.ageThresholdDays);
      // "older than N days" -> excluded from the last N days window.
      clauses.add(input.ageField + ' < LAST_N_DAYS:' + days);
    }

    if (useFilter && String.isNotBlank(input.filterLogic)) {
      clauses.add('(' + input.filterLogic.trim() + ')');
    }

    return String.join(clauses, ' AND ');
  }

  @AuraEnabled(cacheable=true)
  public static ConfigDetail getConfigForEdit(Id configId) {
    assertCanConfigure();
    if (configId == null) {
      throw new AuraHandledException('A configuration record is required.');
    }
    List<Archive_Config__c> matches = [
      SELECT
        Id,
        Name,
        Source_Object__c,
        Is_Active__c,
        Criteria_Type__c,
        Age_Field__c,
        Age_Threshold_Days__c,
        Filter_Logic__c,
        List_View_Fields__c,
        Delete_After_Archive__c,
        Batch_Size__c,
        Schedule_Cron__c,
        Big_Object_Api_Name__c,
        (
          SELECT
            Id,
            Name,
            Match_Field__c,
            On_Conflict__c,
            Reparent_Owner__c,
            Bypass_Automation__c
          FROM Restore_Profiles__r
          ORDER BY CreatedDate ASC
          LIMIT 1
        )
      FROM Archive_Config__c
      WHERE Id = :configId
      LIMIT 1
    ];
    if (matches.isEmpty()) {
      throw new AuraHandledException('Configuration record not found.');
    }
    Archive_Config__c cfg = matches[0];

    ConfigDetail detail = new ConfigDetail();
    detail.configId = cfg.Id;
    detail.configName = cfg.Name;
    detail.sourceObject = cfg.Source_Object__c;
    detail.isActive = cfg.Is_Active__c;
    detail.criteriaType = cfg.Criteria_Type__c;
    detail.ageField = cfg.Age_Field__c;
    detail.ageThresholdDays = cfg.Age_Threshold_Days__c;
    detail.filterLogic = cfg.Filter_Logic__c;
    detail.listViewFields = String.isBlank(cfg.List_View_Fields__c)
      ? new List<String>()
      : splitCsv(cfg.List_View_Fields__c);
    detail.deleteAfterArchive = cfg.Delete_After_Archive__c;
    detail.batchSize = cfg.Batch_Size__c;
    detail.scheduleCron = cfg.Schedule_Cron__c;
    detail.bigObjectApiName = cfg.Big_Object_Api_Name__c;

    if (!cfg.Restore_Profiles__r.isEmpty()) {
      Restore_Profile__c profile = cfg.Restore_Profiles__r[0];
      RestoreProfileInput rp = new RestoreProfileInput();
      rp.profileId = profile.Id;
      rp.name = profile.Name;
      rp.matchField = profile.Match_Field__c;
      rp.onConflict = profile.On_Conflict__c;
      rp.reparentOwner = profile.Reparent_Owner__c;
      rp.bypassAutomation = profile.Bypass_Automation__c;
      detail.restoreProfile = rp;
    }
    return detail;
  }

  @AuraEnabled
  public static Id saveConfig(String inputJson) {
    assertCanConfigure();
    ConfigInput input = (ConfigInput) JSON.deserialize(inputJson, ConfigInput.class);
    if (input == null) {
      throw new AuraHandledException('Configuration payload is required.');
    }
    if (String.isBlank(input.sourceObject)) {
      throw new AuraHandledException('A source object is required.');
    }
    if (String.isNotBlank(input.criteriaType) && !CRITERIA_TYPES.contains(input.criteriaType)) {
      throw new AuraHandledException('Unsupported criteria type: ' + input.criteriaType);
    }
    String criteriaType = String.isBlank(input.criteriaType) ? 'Age' : input.criteriaType;
    Boolean useAge = criteriaType == 'Age' || criteriaType == 'Both';
    Boolean useFilter = criteriaType == 'SOQL_Filter' || criteriaType == 'Both';
    if (useAge && (String.isBlank(input.ageField) || input.ageThresholdDays == null || input.ageThresholdDays <= 0)) {
      throw new AuraHandledException('Age criteria requires an age field and a positive threshold in days.');
    }
    if (useFilter && String.isBlank(input.filterLogic)) {
      throw new AuraHandledException('SOQL filter criteria requires a filter expression.');
    }

    if (!Schema.SObjectType.Archive_Config__c.isCreateable() || !Schema.SObjectType.Archive_Config__c.isUpdateable()) {
      throw new AuraHandledException('You do not have access to Archive Config records.');
    }

    Archive_Config__c cfg = new Archive_Config__c();
    if (input.configId != null) {
      cfg.Id = input.configId;
    }
    cfg.Name = String.isBlank(input.configName) ? (input.sourceObject + '_Archive') : input.configName;
    cfg.Source_Object__c = input.sourceObject;
    cfg.Big_Object_Api_Name__c = buildBigObjectApiName(input.sourceObject);
    cfg.Is_Active__c = input.isActive == true;
    cfg.Criteria_Type__c = criteriaType;
    cfg.Age_Field__c = useAge ? input.ageField : null;
    cfg.Age_Threshold_Days__c = useAge ? input.ageThresholdDays : null;
    cfg.Filter_Logic__c = useFilter ? input.filterLogic : null;
    cfg.List_View_Fields__c = (input.listViewFields == null || input.listViewFields.isEmpty())
      ? null
      : String.join(input.listViewFields, ',');
    cfg.Delete_After_Archive__c = input.deleteAfterArchive == true;
    cfg.Batch_Size__c = input.batchSize == null ? 200 : input.batchSize;
    cfg.Schedule_Cron__c = input.scheduleCron;
    cfg.Generation_Status__c = 'Pending';

    upsert cfg;

    // Restore profile is a master-detail child of the Archive Config.
    upsertRestoreProfile(input.restoreProfile, cfg.Id);
    return cfg.Id;
  }

  private static Id upsertRestoreProfile(RestoreProfileInput rp, Id parentConfigId) {
    if (rp == null) {
      return null;
    }
    if (rp.profileId != null && String.isBlank(rp.matchField)) {
      // Reusing an existing profile without edits.
      return rp.profileId;
    }
    if (String.isBlank(rp.matchField)) {
      return rp.profileId;
    }
    if (rp.onConflict != null && !CONFLICT_MODES.contains(rp.onConflict)) {
      throw new AuraHandledException('Unsupported conflict mode: ' + rp.onConflict);
    }
    if (
      !Schema.SObjectType.Restore_Profile__c.isCreateable() ||
      !Schema.SObjectType.Restore_Profile__c.isUpdateable()
    ) {
      throw new AuraHandledException('You do not have access to Restore Profile records.');
    }
    Restore_Profile__c profile = new Restore_Profile__c();
    if (rp.profileId != null) {
      profile.Id = rp.profileId;
    }
    profile.Archive_Config__c = parentConfigId;
    profile.Match_Field__c = rp.matchField;
    profile.On_Conflict__c = String.isBlank(rp.onConflict) ? 'Skip' : rp.onConflict;
    profile.Reparent_Owner__c = rp.reparentOwner == true;
    profile.Bypass_Automation__c = rp.bypassAutomation == true;
    upsert profile;
    return profile.Id;
  }

  @TestVisible
  private static String buildBigObjectApiName(String sourceObject) {
    String base = sourceObject;
    if (base.endsWithIgnoreCase('__c')) {
      base = base.substring(0, base.length() - 3);
    }
    base = base.replaceAll('[^a-zA-Z0-9]', '');
    if (String.isBlank(base)) {
      base = 'Object';
    }
    return 'Archive_' + base + '__b';
  }

  private static List<String> splitCsv(String csv) {
    List<String> out = new List<String>();
    for (String part : csv.split(',')) {
      String trimmed = part.trim();
      if (String.isNotBlank(trimmed)) {
        out.add(trimmed);
      }
    }
    return out;
  }

  public class OptionLabelComparator implements Comparator<PicklistOption> {
    public Integer compare(PicklistOption a, PicklistOption b) {
      return a.label.toLowerCase().compareTo(b.label.toLowerCase());
    }
  }

  public class FieldLabelComparator implements Comparator<FieldOption> {
    public Integer compare(FieldOption a, FieldOption b) {
      return a.label.toLowerCase().compareTo(b.label.toLowerCase());
    }
  }
}
