/**
 * Resolves an active Field_Log_Config__c record (and its tracked fields) for a
 * given source object API name.
 *
 * Runs without sharing so the generated object triggers can read configuration
 * regardless of the running user's record-level visibility into the config data.
 */
public without sharing class BIGOTOOL_ConfigRepo {
  public class ObjectConfig {
    public Field_Log_Config__c config;
    public List<Field_Log_Field__c> fields = new List<Field_Log_Field__c>();

    public Boolean isActive {
      get {
        return config != null && config.Is_Active__c == true;
      }
    }
  }

  public static ObjectConfig forObject(String objName) {
    if (String.isBlank(objName)) {
      return null;
    }

    List<Field_Log_Config__c> matches = [
      SELECT
        Id,
        Source_Object__c,
        Is_Active__c,
        Async_Mode__c,
        Log_On_Create__c,
        Log_On_Update__c,
        Log_On_Delete__c,
        Log_On_Undelete__c,
        (
          SELECT Field_Api_Name__c, Field_Label__c, Mask_Value__c, Track_Old_New__c
          FROM Field_Log_Fields__r
        )
      FROM Field_Log_Config__c
      WHERE Source_Object__c = :objName AND Is_Active__c = TRUE
      LIMIT 1
    ];

    if (matches.isEmpty()) {
      return null;
    }

    ObjectConfig oc = new ObjectConfig();
    oc.config = matches[0];
    oc.fields = matches[0].Field_Log_Fields__r;
    return oc;
  }
}
