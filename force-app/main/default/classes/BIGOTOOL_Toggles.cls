/**
 * Resolves runtime on/off state and async delivery mode for field-history
 * logging, combining the hierarchy custom setting kill-switches with the
 * per-object Field_Log_Config__c record.
 */
public with sharing class BIGOTOOL_Toggles {
  /**
   * True when global switches allow logging AND an active config with at least
   * one tracked field exists for the object.
   */
  public static Boolean loggingEnabled(String objName) {
    BIGOTOOL_Settings__c cs = BIGOTOOL_Settings__c.getInstance();
    Boolean masterOn = cs == null || cs.Master_Switch__c != false;
    Boolean logOn = cs == null || cs.Logging_Enabled__c != false;
    if (!masterOn || !logOn) {
      return false;
    }
    BIGOTOOL_ConfigRepo.ObjectConfig oc = BIGOTOOL_ConfigRepo.forObject(objName);
    return oc != null && oc.isActive && !oc.fields.isEmpty();
  }

  /**
   * Async write mode for the object; defaults to PlatformEvent when unset.
   */
  public static String asyncMode(String objName) {
    BIGOTOOL_ConfigRepo.ObjectConfig oc = BIGOTOOL_ConfigRepo.forObject(objName);
    if (oc == null || oc.config == null || String.isBlank(oc.config.Async_Mode__c)) {
      return 'PlatformEvent';
    }
    return oc.config.Async_Mode__c;
  }
}
