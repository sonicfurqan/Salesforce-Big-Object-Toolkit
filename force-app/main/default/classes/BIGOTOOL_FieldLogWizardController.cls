public with sharing class BIGOTOOL_FieldLogWizardController {
  @TestVisible
  private static final Set<String> SUPPORTED_ASYNC_MODES = new Set<String>{
    'PlatformEvent',
    'Queueable',
    'Synchronous'
  };

  public class WizardException extends Exception {
  }

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

  public class FieldSelection {
    @AuraEnabled
    public String fieldApiName;
    @AuraEnabled
    public String fieldLabel;
    @AuraEnabled
    public Boolean trackOldNew;
    @AuraEnabled
    public Boolean maskValue;
  }

  public class ConfigInput {
    @AuraEnabled
    public Id configId;
    @AuraEnabled
    public String configName;
    @AuraEnabled
    public String sourceObject;
    @AuraEnabled
    public String sourceObjectLabel;
    @AuraEnabled
    public Boolean isActive;
    @AuraEnabled
    public Boolean logOnCreate;
    @AuraEnabled
    public Boolean logOnUpdate;
    @AuraEnabled
    public Boolean logOnDelete;
    @AuraEnabled
    public Boolean logOnUndelete;
    @AuraEnabled
    public String asyncMode;
    @AuraEnabled
    public Decimal retentionDays;
    @AuraEnabled
    public List<FieldSelection> fields;
  }

  private static void assertCanConfigure() {
    if (
      !FeatureManagement.checkPermission('BIGOTOOL_Can_Configure') &&
      !FeatureManagement.checkPermission('bigotool__BIGOTOOL_Can_Configure')
    ) {
      throw new AuraHandledException('You do not have permission to configure field history logging.');
    }
  }

  @AuraEnabled(cacheable=true)
  public static List<PicklistOption> getObjectOptions() {
    assertCanConfigure();
    List<PicklistOption> options = new List<PicklistOption>();
    for (Schema.SObjectType t : Schema.getGlobalDescribe().values()) {
      Schema.DescribeSObjectResult d = t.getDescribe();
      if (!d.isCreateable() || !d.isQueryable() || d.isCustomSetting()) {
        continue;
      }
      String associateType = d.getAssociateEntityType();
      if (
        associateType == 'Share' ||
        associateType == 'History' ||
        associateType == 'Feed' ||
        associateType == 'ChangeEvent'
      ) {
        continue;
      }
      String apiName = d.getName();
      if (
        apiName.endsWith('__b') ||
        apiName.endsWith('__e') ||
        apiName.endsWith('__mdt') ||
        apiName.endsWith('__x') ||
        apiName.endsWith('__Share') ||
        apiName.endsWith('__History') ||
        apiName.endsWith('__Feed') ||
        apiName.endsWith('__Tag') ||
        apiName.endsWith('__ChangeEvent') ||
        apiName.endsWith('ChangeEvent') ||
        apiName.endsWith('Share') ||
        apiName.endsWith('History')
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
      if (
        dt == Schema.DisplayType.ADDRESS ||
        dt == Schema.DisplayType.LOCATION ||
        dt == Schema.DisplayType.BASE64 ||
        dt == Schema.DisplayType.ENCRYPTEDSTRING
      ) {
        continue;
      }
      options.add(new FieldOption(fd.getLabel(), fd.getName(), String.valueOf(dt)));
    }
    options.sort(new FieldLabelComparator());
    return options;
  }

  @AuraEnabled
  public static Id saveConfig(String inputJson) {
    ConfigInput input = (ConfigInput) JSON.deserialize(inputJson, ConfigInput.class);
    System.debug('Saving configuration: ' + input);
    assertCanConfigure();
    if (input == null) {
      throw new AuraHandledException('Configuration payload is required.');
    }
    if (String.isBlank(input.sourceObject)) {
      throw new AuraHandledException('A source object is required.');
    }
    if (input.fields == null || input.fields.isEmpty()) {
      throw new AuraHandledException('Select at least one field to track.');
    }
    if (String.isNotBlank(input.asyncMode) && !SUPPORTED_ASYNC_MODES.contains(input.asyncMode)) {
      throw new AuraHandledException('Unsupported async mode: ' + input.asyncMode);
    }

    Schema.SObjectType sourceType = Schema.getGlobalDescribe().get(input.sourceObject);
    Map<String, Schema.SObjectField> fieldMap = sourceType == null
      ? new Map<String, Schema.SObjectField>()
      : sourceType.getDescribe().fields.getMap();
    String objectLabel = sourceType == null ? null : sourceType.getDescribe().getLabel();
    if (String.isBlank(objectLabel)) {
      objectLabel = String.isNotBlank(input.sourceObjectLabel) ? input.sourceObjectLabel : input.sourceObject;
    }

    Field_Log_Config__c cfg = new Field_Log_Config__c();
    if (input.configId != null) {
      cfg.Id = input.configId;
    }
    cfg.Name = String.isBlank(input.configName) ? (input.sourceObject + '_FieldLog') : input.configName;
    cfg.Source_Object__c = input.sourceObject;
    cfg.Source_Object_Label__c = objectLabel;
    cfg.Is_Active__c = input.isActive == true;
    cfg.Log_On_Create__c = input.logOnCreate == true;
    cfg.Log_On_Update__c = input.logOnUpdate == null ? true : input.logOnUpdate;
    cfg.Log_On_Delete__c = input.logOnDelete == true;
    cfg.Log_On_Undelete__c = input.logOnUndelete == true;
    cfg.Async_Mode__c = String.isBlank(input.asyncMode) ? 'PlatformEvent' : input.asyncMode;
    cfg.Retention_Days__c = input.retentionDays == null ? 0 : input.retentionDays;
    cfg.Trigger_Generated__c = false;

    if (
      !Schema.SObjectType.Field_Log_Config__c.isCreateable() || !Schema.SObjectType.Field_Log_Config__c.isUpdateable()
    ) {
      throw new AuraHandledException('You do not have access to Field Log Config records.');
    }
    upsert cfg;

    if (input.configId != null) {
      delete [
        SELECT Id
        FROM Field_Log_Field__c
        WHERE Field_Log_Config__c = :cfg.Id
      ];
    }

    Set<String> seen = new Set<String>();
    List<Field_Log_Field__c> children = new List<Field_Log_Field__c>();
    for (FieldSelection sel : input.fields) {
      if (sel == null || String.isBlank(sel.fieldApiName)) {
        continue;
      }
      String key = sel.fieldApiName.toLowerCase();
      if (seen.contains(key)) {
        continue;
      }
      seen.add(key);
      Schema.SObjectField sf = fieldMap.get(key);
      String fieldLabel = sf == null ? null : sf.getDescribe().getLabel();
      if (String.isBlank(fieldLabel)) {
        fieldLabel = String.isNotBlank(sel.fieldLabel) ? sel.fieldLabel : sel.fieldApiName;
      }
      children.add(
        new Field_Log_Field__c(
          Field_Log_Config__c = cfg.Id,
          Field_Api_Name__c = sel.fieldApiName,
          Field_Label__c = fieldLabel,
          Track_Old_New__c = true,
          Mask_Value__c = sel.maskValue == true
        )
      );
    }
    if (children.isEmpty()) {
      throw new AuraHandledException('Select at least one valid field to track.');
    }
    if (!Schema.SObjectType.Field_Log_Field__c.isCreateable()) {
      throw new AuraHandledException('You do not have access to Field Log Field records.');
    }
    insert children;

    return cfg.Id;
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
