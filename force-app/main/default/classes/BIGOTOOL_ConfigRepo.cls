/**
 * Caches active Field_Log_Config__c records (and their tracked fields) by source
 * object API name so trigger handlers can resolve logging config with a single
 * pair of queries per transaction.
 *
 * Runs without sharing so the generated object triggers can read configuration
 * regardless of the running user's record-level visibility into the config data.
 */
public without sharing class BIGOTOOL_ConfigRepo {
  @TestVisible
  private static Map<String, ObjectConfig> cache;

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
    if (cache == null) {
      load();
    }
    return cache.get(objName.toLowerCase());
  }

  private static void load() {
    cache = new Map<String, ObjectConfig>();
    Map<Id, ObjectConfig> byId = new Map<Id, ObjectConfig>();

    for (Field_Log_Config__c c : [
      SELECT
        Id,
        Source_Object__c,
        Is_Active__c,
        Async_Mode__c,
        Log_On_Create__c,
        Log_On_Update__c,
        Log_On_Delete__c,
        Log_On_Undelete__c
      FROM Field_Log_Config__c
      WHERE Is_Active__c = TRUE
    ]) {
      ObjectConfig oc = new ObjectConfig();
      oc.config = c;
      byId.put(c.Id, oc);
      if (String.isNotBlank(c.Source_Object__c)) {
        cache.put(c.Source_Object__c.toLowerCase(), oc);
      }
    }

    if (!byId.isEmpty()) {
      for (Field_Log_Field__c f : [
        SELECT Field_Log_Config__c, Field_Api_Name__c, Field_Label__c, Mask_Value__c, Track_Old_New__c
        FROM Field_Log_Field__c
        WHERE Field_Log_Config__c IN :byId.keySet()
      ]) {
        ObjectConfig oc = byId.get(f.Field_Log_Config__c);
        if (oc != null) {
          oc.fields.add(f);
        }
      }
    }
  }

  @TestVisible
  private static void clearCache() {
    cache = null;
  }
}
