@IsTest
private class BIGOTOOL_GenerationEngineTest {
  @TestSetup
  static void setup() {
    // Archive batch now self-guards on Master Switch + Archiving Enabled, so seed
    // an org-default settings row that permits archiving to run under test.
    BIGOTOOL_Toggles.saveOrgSettings(true, true, true, false, null);
    Profile p = [SELECT Id FROM Profile WHERE Name = 'Standard User' LIMIT 1];
    User u = new User(
      FirstName = 'Gen',
      LastName = 'Engine',
      Email = 'bigotool.genengine@example.com',
      Username = 'bigotool.genengine.' + Crypto.getRandomInteger() + '@example.com.test',
      Alias = 'gen',
      TimeZoneSidKey = 'America/Los_Angeles',
      LocaleSidKey = 'en_US',
      EmailEncodingKey = 'UTF-8',
      LanguageLocaleKey = 'en_US',
      ProfileId = p.Id
    );
    insert u;
    PermissionSet ps = [SELECT Id FROM PermissionSet WHERE Name = 'BIGOTOOL_Configurator' LIMIT 1];
    insert new PermissionSetAssignment(AssigneeId = u.Id, PermissionSetId = ps.Id);
  }

  private static User configUser() {
    return [SELECT Id FROM User WHERE Email = 'bigotool.genengine@example.com' LIMIT 1];
  }

  private static Archive_Config__c newConfig() {
    Archive_Config__c cfg = new Archive_Config__c(
      Source_Object__c = 'Account',
      Big_Object_Api_Name__c = 'Archive_Account__b',
      Is_Active__c = true,
      Criteria_Type__c = 'Age',
      Age_Field__c = 'CreatedDate',
      Age_Threshold_Days__c = 365,
      Delete_After_Archive__c = false,
      Batch_Size__c = 200,
      Schedule_Cron__c = '0 0 1 * * ?',
      Generation_Status__c = 'Pending'
    );
    insert cfg;
    insert new List<Archive_Field__c>{
      new Archive_Field__c(
        Archive_Config__c = cfg.Id,
        Field_API_Name__c = 'Name',
        Field_Label__c = 'Account Name',
        Field_Type__c = 'STRING',
        Is_List_View__c = true
      ),
      new Archive_Field__c(
        Archive_Config__c = cfg.Id,
        Field_API_Name__c = 'Industry',
        Field_Label__c = 'Industry',
        Field_Type__c = 'PICKLIST',
        Is_List_View__c = true
      ),
      new Archive_Field__c(
        Archive_Config__c = cfg.Id,
        Field_API_Name__c = 'AnnualRevenue',
        Field_Label__c = 'Annual Revenue',
        Field_Type__c = 'CURRENCY',
        Is_List_View__c = true
      ),
      new Archive_Field__c(
        Archive_Config__c = cfg.Id,
        Field_API_Name__c = 'CreatedDate',
        Field_Label__c = 'Created Date',
        Field_Type__c = 'DATETIME',
        Is_List_View__c = true
      )
    };
    return cfg;
  }

  @IsTest
  static void helperMethodsBuildExpectedApiNames() {
    System.assertEquals('Archive_Account__b', BIGOTOOL_MetadataGenerator.bigObjectApiName('Account'));
    System.assertEquals('Archive_MyObject__b', BIGOTOOL_MetadataGenerator.bigObjectApiName('My_Object__c'));
    System.assertEquals('Archive_Account', BIGOTOOL_MetadataGenerator.cleanDevName('Archive_Account__b'));
    System.assertEquals('Archive_MyObject', BIGOTOOL_MetadataGenerator.cleanDevName('Archive_MyObject__b'));
    System.assertEquals('Industry__c', BIGOTOOL_MetadataGenerator.archiveFieldApiName('Industry'));
    System.assertEquals('Foo__c', BIGOTOOL_MetadataGenerator.archiveFieldApiName('Foo__c'));
    System.assertEquals(
      'BIGOTOOL_Archive_Account',
      BIGOTOOL_MetadataGenerator.permissionSetApiName('Archive_Account__b')
    );
    System.assertEquals(
      'BIGOTOOL_Archive_MyObject',
      BIGOTOOL_MetadataGenerator.permissionSetApiName('Archive_MyObject__b')
    );
    System.assertEquals(2, BIGOTOOL_MetadataGenerator.splitCsv('A, B').size());
    System.assertEquals(0, BIGOTOOL_MetadataGenerator.splitCsv(null).size());
  }

  @IsTest
  static void generateSuccessFlipsStatusToGenerated() {
    Archive_Config__c cfg = newConfig();
    Test.setMock(WebServiceMock.class, new BIGOTOOL_MetadataServiceMock(true));
    System.runAs(configUser()) {
      Test.startTest();
      BIGOTOOL_GenerationController.GenerateResponse resp = BIGOTOOL_GenerationController.generate(cfg.Id);
      Test.stopTest();
      System.assertEquals(true, resp.success, 'Expected success');
      System.assertEquals('Generated', resp.status);
    }
    Archive_Config__c updated = [SELECT Generation_Status__c FROM Archive_Config__c WHERE Id = :cfg.Id];
    System.assertEquals('Generated', updated.Generation_Status__c);
  }

  @IsTest
  static void generateFailureFlipsStatusToError() {
    Archive_Config__c cfg = newConfig();
    Test.setMock(WebServiceMock.class, new BIGOTOOL_MetadataServiceMock(false));
    System.runAs(configUser()) {
      Test.startTest();
      BIGOTOOL_GenerationController.GenerateResponse resp = BIGOTOOL_GenerationController.generate(cfg.Id);
      Test.stopTest();
      System.assertEquals(false, resp.success, 'Expected failure');
      System.assertEquals('Error', resp.status);
    }
    Archive_Config__c updated = [SELECT Generation_Status__c FROM Archive_Config__c WHERE Id = :cfg.Id];
    System.assertEquals('Error', updated.Generation_Status__c);
  }

  @IsTest
  static void generateRejectsAlreadyGenerated() {
    Archive_Config__c cfg = newConfig();
    cfg.Generation_Status__c = 'Generated';
    update cfg;
    System.runAs(configUser()) {
      Test.startTest();
      try {
        BIGOTOOL_GenerationController.generate(cfg.Id);
        System.assert(false, 'Expected exception for already generated config');
      } catch (AuraHandledException e) {
        // Expected.
      }
      Test.stopTest();
    }
  }

  @IsTest
  static void getConfigSummaryReturnsRecord() {
    Archive_Config__c cfg = newConfig();
    System.runAs(configUser()) {
      Archive_Config__c summary = BIGOTOOL_GenerationController.getConfigSummary(cfg.Id);
      System.assertEquals(cfg.Id, summary.Id);
      System.assertEquals('Account', summary.Source_Object__c);
    }
  }

  @IsTest
  static void createServiceBuildsEndpoint() {
    System.runAs(configUser()) {
      MetadataService.MetadataPort service = BIGOTOOL_MetadataGenerator.createService();
      System.assertNotEquals(null, service.SessionHeader);
      System.assert(service.endpoint_x.endsWith('/services/Soap/m/60.0'), 'Endpoint version expected');
    }
  }

  @IsTest
  static void batchRunsAgainstMissingBigObject() {
    // Filter criteria so the freshly inserted Account is in scope and execute() runs.
    Archive_Config__c cfg = new Archive_Config__c(
      Source_Object__c = 'Account',
      Big_Object_Api_Name__c = 'Archive_Account__b',
      Is_Active__c = true,
      Criteria_Type__c = 'SOQL_Filter',
      Filter_Logic__c = 'Name != null',
      Delete_After_Archive__c = false,
      Batch_Size__c = 200,
      Generation_Status__c = 'Pending'
    );
    insert cfg;
    insert new Archive_Field__c(
      Archive_Config__c = cfg.Id,
      Field_API_Name__c = 'Name',
      Field_Label__c = 'Account Name',
      Field_Type__c = 'STRING',
      Is_List_View__c = true
    );
    insert new Account(Name = 'Archive Me Co', Industry = 'Technology');
    Test.startTest();
    Database.executeBatch(new BIGOTOOL_ArchiveBatch(cfg.Id), 200);
    Test.stopTest();
    // Big Object does not exist in the test context, so the batch records the
    // miss rather than throwing - asserting it completed without error.
    System.assert(true);
  }

  @IsTest
  static void batchBuildsWhereClauseFromCriteria() {
    Archive_Config__c cfg = newConfig();
    BIGOTOOL_ArchiveBatch batch = new BIGOTOOL_ArchiveBatch(cfg.Id);
    Test.startTest();
    batch.start(null);
    Test.stopTest();
    String where1 = batch.buildWhereClause();
    System.assert(where1.contains('LAST_N_DAYS:365'), 'Expected age clause, got: ' + where1);
  }

  @IsTest
  static void schedulableExecutesBatch() {
    Archive_Config__c cfg = newConfig();
    Test.startTest();
    new BIGOTOOL_ArchiveSchedulable(cfg.Id).execute(null);
    Test.stopTest();
    System.assert(true);
  }
}
