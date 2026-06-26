/**
 * BIGOTOOL_GenerationController
 *
 * Aura/LWC entry point for the "Generate Archive" action on Archive Config.
 * Validates the config is Pending, drives BIGOTOOL_MetadataGenerator (Metadata
 * API callouts), then flips Generation_Status__c to Generated or Error.
 *
 * DML ordering: SOQL is performed first, the callout runs via the engine, and
 * the status DML happens AFTER the callout - never before - per platform rules.
 */
public with sharing class BIGOTOOL_GenerationController {
  /** Lightweight DTO returned to the LWC. */
  public class GenerateResponse {
    @AuraEnabled
    public Boolean success;
    @AuraEnabled
    public String status;
    @AuraEnabled
    public String bigObjectApiName;
    @AuraEnabled
    public String message;
    @AuraEnabled
    public List<String> details;
    @AuraEnabled
    public List<String> warnings;
  }

  /** Returns the current config status so the modal can render the right copy. */
  @AuraEnabled(cacheable=true)
  public static Archive_Config__c getConfigSummary(Id configId) {
    assertCanConfigure();
    if (configId == null) {
      throw new AuraHandledException('A configuration record is required.');
    }
    List<Archive_Config__c> rows = [
      SELECT
        Id,
        Name,
        Source_Object__c,
        Big_Object_Api_Name__c,
        Generation_Status__c,
        Delete_After_Archive__c,
        Is_Active__c
      FROM Archive_Config__c
      WHERE Id = :configId
      LIMIT 1
    ];
    if (rows.isEmpty()) {
      throw new AuraHandledException('Configuration not found.');
    }
    return rows[0];
  }

  @AuraEnabled
  public static GenerateResponse generate(Id configId) {
    assertCanConfigure();
    if (configId == null) {
      throw new AuraHandledException('A configuration record is required.');
    }

    // SOQL before callout is allowed; DML is not.
    Archive_Config__c config = loadConfig(configId);
    if (config.Generation_Status__c == 'Generated') {
      throw new AuraHandledException('This configuration has already been generated.');
    }

    GenerateResponse response = new GenerateResponse();
    String newStatus;
    try {
      BIGOTOOL_MetadataGenerator.GenerationResult result = BIGOTOOL_MetadataGenerator.generate(config);
      response.success = result.success;
      response.bigObjectApiName = result.bigObjectApiName;
      response.details = result.messages;
      response.warnings = result.warnings;
      newStatus = 'Generated';
      response.message =
        'Generation complete. Big Object ' +
        result.bigObjectApiName +
        ' and supporting metadata are ready.';
    } catch (Exception e) {
      response.success = false;
      response.message = 'Generation failed: ' + e.getMessage();
      response.details = new List<String>{ e.getMessage() };
      response.warnings = new List<String>();
      newStatus = 'Error';
    }

    // DML AFTER the callout.
    config.Generation_Status__c = newStatus;
    update config;
    response.status = newStatus;
    return response;
  }

  private static Archive_Config__c loadConfig(Id configId) {
    List<Archive_Config__c> rows = [
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
        Generation_Status__c
      FROM Archive_Config__c
      WHERE Id = :configId
      LIMIT 1
    ];
    if (rows.isEmpty()) {
      throw new AuraHandledException('Configuration not found.');
    }
    return rows[0];
  }

  private static void assertCanConfigure() {
    if (!FeatureManagement.checkPermission('BIGOTOOL_Can_Configure')) {
      throw new AuraHandledException('You do not have permission to configure archiving.');
    }
  }
}
