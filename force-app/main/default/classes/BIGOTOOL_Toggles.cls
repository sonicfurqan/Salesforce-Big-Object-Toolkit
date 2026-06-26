/**
 * Centralizes BIGOTOOL runtime toggles and org-default custom-setting access.
 * Combines the hierarchy custom setting kill-switches with per-object
 * Field_Log_Config__c records where needed.
 */
public with sharing class BIGOTOOL_Toggles {
  @TestVisible
  private static final Boolean MASTER_SWITCH_DEFAULT = true;
  @TestVisible
  private static final Boolean LOGGING_ENABLED_DEFAULT = true;
  @TestVisible
  private static final Boolean ARCHIVING_ENABLED_DEFAULT = false;
  @TestVisible
  private static final Boolean DEBUG_MODE_DEFAULT = false;

  public class SettingsState {
    @AuraEnabled
    public Boolean masterSwitch = MASTER_SWITCH_DEFAULT;
    @AuraEnabled
    public Boolean loggingEnabled = LOGGING_ENABLED_DEFAULT;
    @AuraEnabled
    public Boolean archivingEnabled = ARCHIVING_ENABLED_DEFAULT;
    @AuraEnabled
    public Boolean debugMode = DEBUG_MODE_DEFAULT;
    @AuraEnabled
    public Decimal maxBatchConcurrency;
  }

  /**
   * Returns the effective runtime toggle values for the current user/org scope.
   */
  public static SettingsState currentSettings() {
    return toState(BIGOTOOL_Settings__c.getInstance());
  }

  /**
   * Returns the org-default toggle values used by the dashboard configuration
   * screen.
   */
  public static SettingsState orgSettings() {
    return toState(BIGOTOOL_Settings__c.getOrgDefaults());
  }

  /**
   * Persists the org-default custom setting row and returns the saved state.
   */
  public static SettingsState saveOrgSettings(
    Boolean masterSwitch,
    Boolean loggingEnabled,
    Boolean archivingEnabled,
    Boolean debugMode,
    Decimal maxBatchConcurrency
  ) {
    BIGOTOOL_Settings__c cs = writableOrgDefaults();
    cs.Master_Switch__c = masterSwitch == true;
    cs.Logging_Enabled__c = loggingEnabled == true;
    cs.Archiving_Enabled__c = archivingEnabled == true;
    cs.Debug_Mode__c = debugMode == true;
    cs.Max_Batch_Concurrency__c = (maxBatchConcurrency != null && maxBatchConcurrency > 0) ? maxBatchConcurrency : null;
    upsert cs;
    return orgSettings();
  }

  /**
   * True when the effective runtime Master Switch is ON.
   */
  public static Boolean masterEnabled() {
    return currentSettings().masterSwitch;
  }

  /**
   * True when the effective runtime Master Switch and Archiving Enabled toggle
   * both permit archiving to run.
   */
  public static Boolean archivingEnabled() {
    SettingsState state = currentSettings();
    return state.masterSwitch && state.archivingEnabled;
  }

  /**
   * Returns the configured batch concurrency cap, or the supplied fallback when
   * no positive value is configured.
   */
  public static Integer maxBatchConcurrency(Integer fallbackValue) {
    Decimal configured = currentSettings().maxBatchConcurrency;
    return (configured != null && configured > 0) ? Integer.valueOf(configured) : fallbackValue;
  }

  /**
   * True when global switches allow logging AND an active config with at least
   * one tracked field exists for the object.
   */
  public static Boolean loggingEnabled(String objName) {
    SettingsState state = currentSettings();
    if (!state.masterSwitch || !state.loggingEnabled) {
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

  @TestVisible
  private static SettingsState toState(BIGOTOOL_Settings__c cs) {
    SettingsState state = new SettingsState();
    if (cs == null) {
      return state;
    }
    state.masterSwitch = boolOrDefault(cs.Master_Switch__c, MASTER_SWITCH_DEFAULT);
    state.loggingEnabled = boolOrDefault(cs.Logging_Enabled__c, LOGGING_ENABLED_DEFAULT);
    state.archivingEnabled = boolOrDefault(cs.Archiving_Enabled__c, ARCHIVING_ENABLED_DEFAULT);
    state.debugMode = cs.Debug_Mode__c == true;
    state.maxBatchConcurrency = cs.Max_Batch_Concurrency__c;
    return state;
  }

  private static Boolean boolOrDefault(Boolean value, Boolean defaultValue) {
    return value == null ? defaultValue : value;
  }

  private static BIGOTOOL_Settings__c writableOrgDefaults() {
    BIGOTOOL_Settings__c cs = BIGOTOOL_Settings__c.getOrgDefaults();
    if (cs == null || cs.Id == null) {
      return new BIGOTOOL_Settings__c(SetupOwnerId = UserInfo.getOrganizationId());
    }
    if (cs.SetupOwnerId == null) {
      cs.SetupOwnerId = UserInfo.getOrganizationId();
    }
    return cs;
  }
}
