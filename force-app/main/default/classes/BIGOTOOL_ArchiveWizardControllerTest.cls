@IsTest
private class BIGOTOOL_ArchiveWizardControllerTest {
  @TestSetup
  static void setup() {
    Profile p = [SELECT Id FROM Profile WHERE Name = 'Standard User' LIMIT 1];
    User u = new User(
      FirstName = 'Big',
      LastName = 'Archiver',
      Email = 'bigotool.archiver@example.com',
      Username = 'bigotool.archiver.' + Crypto.getRandomInteger() + '@example.com.test',
      Alias = 'barc',
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

  private static User configuratorUser() {
    return [SELECT Id FROM User WHERE Email = 'bigotool.archiver@example.com' LIMIT 1];
  }

  private static BIGOTOOL_ArchiveWizardController.ConfigInput buildInput() {
    BIGOTOOL_ArchiveWizardController.ConfigInput cfgIn = new BIGOTOOL_ArchiveWizardController.ConfigInput();
    cfgIn.configName = 'Old Accounts';
    cfgIn.sourceObject = 'Account';
    cfgIn.isActive = true;
    cfgIn.criteriaType = 'Age';
    cfgIn.ageField = 'CreatedDate';
    cfgIn.ageThresholdDays = 365;
    cfgIn.listViewFields = new List<String>{ 'Name', 'Industry' };
    cfgIn.deleteAfterArchive = false;
    cfgIn.batchSize = 200;
    cfgIn.scheduleCron = '0 0 1 * * ?';
    return cfgIn;
  }

  @IsTest
  static void getObjectOptions_excludesSystemObjects() {
    List<BIGOTOOL_ArchiveWizardController.PicklistOption> opts;
    System.runAs(configuratorUser()) {
      opts = BIGOTOOL_ArchiveWizardController.getObjectOptions();
    }
    System.assert(!opts.isEmpty(), 'Expected some object options.');
    Boolean foundAccount = false;
    for (BIGOTOOL_ArchiveWizardController.PicklistOption o : opts) {
      System.assert(!o.value.endsWith('__b'), 'Big Objects excluded.');
      System.assert(!o.value.endsWith('__e'), 'Platform Events excluded.');
      System.assert(!o.value.endsWith('History'), 'History objects excluded.');
      if (o.value == 'Account') {
        foundAccount = true;
      }
    }
    System.assert(foundAccount, 'Account should be archivable.');
  }

  @IsTest
  static void getFieldOptions_andDateFields() {
    List<BIGOTOOL_ArchiveWizardController.FieldOption> all;
    List<BIGOTOOL_ArchiveWizardController.FieldOption> dates;
    System.runAs(configuratorUser()) {
      all = BIGOTOOL_ArchiveWizardController.getFieldOptions('Account');
      dates = BIGOTOOL_ArchiveWizardController.getDateFieldOptions('Account');
    }
    System.assert(!all.isEmpty(), 'Account fields should be returned.');
    Boolean foundCreated = false;
    for (BIGOTOOL_ArchiveWizardController.FieldOption f : dates) {
      String dt = f.dataType.toUpperCase();
      System.assert(dt == 'DATE' || dt == 'DATETIME', 'Only date/datetime fields: ' + f.dataType);
      if (f.apiName == 'CreatedDate') {
        foundCreated = true;
      }
    }
    System.assert(foundCreated, 'CreatedDate should be an age-field option.');
  }

  @IsTest
  static void getUniqueFieldOptions_includesIdOnly() {
    List<BIGOTOOL_ArchiveWizardController.FieldOption> unique;
    System.runAs(configuratorUser()) {
      unique = BIGOTOOL_ArchiveWizardController.getUniqueFieldOptions('Account');
    }
    System.assert(!unique.isEmpty(), 'At least the record Id should be returned.');
    Boolean foundId = false;
    for (BIGOTOOL_ArchiveWizardController.FieldOption f : unique) {
      if (f.apiName == 'Id') {
        foundId = true;
      }
    }
    System.assert(foundId, 'Record Id must always be a match-field option.');
  }

  @IsTest
  static void getFieldOptions_blankObjectThrows() {
    Boolean threw = false;
    System.runAs(configuratorUser()) {
      try {
        BIGOTOOL_ArchiveWizardController.getFieldOptions('');
      } catch (Exception e) {
        threw = true;
      }
    }
    System.assert(threw, 'Blank object should throw.');
  }

  @IsTest
  static void saveConfig_age_createsRecord() {
    Id configId;
    System.runAs(configuratorUser()) {
      configId = BIGOTOOL_ArchiveWizardController.saveConfig(JSON.serialize(buildInput()));
    }
    System.assertNotEquals(null, configId, 'Config Id should be returned.');

    Archive_Config__c cfg = [
      SELECT
        Source_Object__c,
        Big_Object_Api_Name__c,
        Criteria_Type__c,
        Age_Field__c,
        Age_Threshold_Days__c,
        List_View_Fields__c,
        Batch_Size__c,
        Generation_Status__c,
        Is_Active__c
      FROM Archive_Config__c
      WHERE Id = :configId
    ];
    System.assertEquals('Account', cfg.Source_Object__c);
    System.assertEquals('Archive_Account__b', cfg.Big_Object_Api_Name__c, 'BO API name derived.');
    System.assertEquals('Age', cfg.Criteria_Type__c);
    System.assertEquals('CreatedDate', cfg.Age_Field__c);
    System.assertEquals(365, cfg.Age_Threshold_Days__c);
    System.assertEquals('Name,Industry', cfg.List_View_Fields__c, 'List view fields stored as CSV.');
    System.assertEquals('Pending', cfg.Generation_Status__c);
    System.assertEquals(true, cfg.Is_Active__c);
  }

  @IsTest
  static void saveConfig_withRestoreProfile_andFilter() {
    BIGOTOOL_ArchiveWizardController.ConfigInput cfgIn = buildInput();
    cfgIn.criteriaType = 'Both';
    cfgIn.filterLogic = 'Industry = \'Energy\'';

    BIGOTOOL_ArchiveWizardController.RestoreProfileInput rp = new BIGOTOOL_ArchiveWizardController.RestoreProfileInput();
    rp.matchField = 'Name';
    rp.onConflict = 'Skip';
    rp.reparentOwner = true;
    rp.bypassAutomation = false;
    cfgIn.restoreProfile = rp;

    Id configId;
    System.runAs(configuratorUser()) {
      configId = BIGOTOOL_ArchiveWizardController.saveConfig(JSON.serialize(cfgIn));
    }

    Archive_Config__c cfg = [
      SELECT Criteria_Type__c, Filter_Logic__c
      FROM Archive_Config__c
      WHERE Id = :configId
    ];
    System.assertEquals('Both', cfg.Criteria_Type__c);
    System.assertEquals('Industry = \'Energy\'', cfg.Filter_Logic__c);

    List<Restore_Profile__c> profiles = [
      SELECT Match_Field__c, Archive_Config__c
      FROM Restore_Profile__c
      WHERE Archive_Config__c = :configId
    ];
    System.assertEquals(1, profiles.size(), 'A restore profile child should exist.');
    System.assertEquals('Name', profiles[0].Match_Field__c);
    System.assertEquals(configId, profiles[0].Archive_Config__c, 'Profile parented to the config.');
  }

  @IsTest
  static void saveConfig_ageMissingThreshold_throws() {
    BIGOTOOL_ArchiveWizardController.ConfigInput cfgIn = buildInput();
    cfgIn.ageThresholdDays = null;
    Boolean threw = false;
    System.runAs(configuratorUser()) {
      try {
        BIGOTOOL_ArchiveWizardController.saveConfig(JSON.serialize(cfgIn));
      } catch (Exception e) {
        threw = true;
      }
    }
    System.assert(threw, 'Missing age threshold should throw.');
  }

  @IsTest
  static void getConfigForEdit_returnsDetail() {
    Id configId;
    System.runAs(configuratorUser()) {
      configId = BIGOTOOL_ArchiveWizardController.saveConfig(JSON.serialize(buildInput()));
    }
    BIGOTOOL_ArchiveWizardController.ConfigDetail detail;
    System.runAs(configuratorUser()) {
      detail = BIGOTOOL_ArchiveWizardController.getConfigForEdit(configId);
    }
    System.assertEquals('Account', detail.sourceObject);
    System.assertEquals(2, detail.listViewFields.size(), 'CSV split back into list.');
    System.assertEquals('Archive_Account__b', detail.bigObjectApiName);
  }

  @IsTest
  static void saveConfig_persistsArchiveFieldChildren() {
    BIGOTOOL_ArchiveWizardController.ConfigInput cfgIn = buildInput();
    cfgIn.archiveFields = new List<String>{ 'Name', 'Industry', 'AnnualRevenue' };
    cfgIn.archiveFieldLabels = new List<String>{ 'Account Name', 'Industry', 'Annual Revenue' };

    Id configId;
    System.runAs(configuratorUser()) {
      configId = BIGOTOOL_ArchiveWizardController.saveConfig(JSON.serialize(cfgIn));
    }

    List<Archive_Field__c> fields = [
      SELECT Field_API_Name__c, Field_Label__c
      FROM Archive_Field__c
      WHERE Archive_Config__c = :configId
    ];
    System.assertEquals(3, fields.size(), 'All archive fields persisted as children.');

    // Re-saving with a smaller set replaces the children. List-view fields are
    // always materialized as children too, so shrink both for a single child.
    cfgIn.configId = configId;
    cfgIn.archiveFields = new List<String>{ 'Name' };
    cfgIn.archiveFieldLabels = new List<String>{ 'Account Name' };
    cfgIn.listViewFields = new List<String>{ 'Name' };
    System.runAs(configuratorUser()) {
      BIGOTOOL_ArchiveWizardController.saveConfig(JSON.serialize(cfgIn));
    }
    System.assertEquals(
      1,
      [SELECT COUNT() FROM Archive_Field__c WHERE Archive_Config__c = :configId],
      'Archive field children replaced on re-save.'
    );

    BIGOTOOL_ArchiveWizardController.ConfigDetail detail;
    System.runAs(configuratorUser()) {
      detail = BIGOTOOL_ArchiveWizardController.getConfigForEdit(configId);
    }
    System.assertEquals(1, detail.archiveFields.size(), 'Archive fields returned for edit.');
    System.assertEquals('Name', detail.archiveFields[0]);
  }

  @IsTest
  static void previewMatchingCount_age_returnsCount() {
    insert new Account(Name = 'Preview Co');
    Integer count;
    System.runAs(configuratorUser()) {
      BIGOTOOL_ArchiveWizardController.ConfigInput cfgIn = buildInput();
      // Records NOT in the last 1 day -> brand new account excluded, count 0.
      cfgIn.ageThresholdDays = 1;
      count = BIGOTOOL_ArchiveWizardController.previewMatchingCount(JSON.serialize(cfgIn));
    }
    System.assertEquals(0, count, 'A just-created record is not older than 1 day.');
  }

  @IsTest
  static void previewMatchingCount_badFilter_throws() {
    Boolean threw = false;
    System.runAs(configuratorUser()) {
      BIGOTOOL_ArchiveWizardController.ConfigInput cfgIn = buildInput();
      cfgIn.criteriaType = 'SOQL_Filter';
      cfgIn.filterLogic = 'NotAField = 123';
      try {
        BIGOTOOL_ArchiveWizardController.previewMatchingCount(JSON.serialize(cfgIn));
      } catch (Exception e) {
        threw = true;
      }
    }
    System.assert(threw, 'Invalid filter should throw a friendly error.');
  }

  @IsTest
  static void buildWhereClause_combinesAgeAndFilter() {
    BIGOTOOL_ArchiveWizardController.ConfigInput cfgIn = buildInput();
    cfgIn.criteriaType = 'Both';
    cfgIn.filterLogic = 'Industry = \'Energy\'';
    String where1 = BIGOTOOL_ArchiveWizardController.buildWhereClause(cfgIn);
    System.assert(where1.contains('LAST_N_DAYS:365'), 'Age clause present: ' + where1);
    System.assert(where1.contains('Industry'), 'Filter clause present: ' + where1);
    System.assert(where1.contains(' AND '), 'Clauses joined with AND.');
  }

  @IsTest
  static void getRestoreProfiles_returnsList() {
    Archive_Config__c parent = new Archive_Config__c(
      Name = 'Parent Cfg',
      Source_Object__c = 'Account',
      Criteria_Type__c = 'Age',
      Age_Field__c = 'CreatedDate',
      Age_Threshold_Days__c = 30
    );
    insert parent;
    insert new Restore_Profile__c(
      Match_Field__c = 'Name',
      On_Conflict__c = 'Skip',
      Archive_Config__c = parent.Id
    );
    List<BIGOTOOL_ArchiveWizardController.PicklistOption> opts;
    System.runAs(configuratorUser()) {
      opts = BIGOTOOL_ArchiveWizardController.getRestoreProfiles();
    }
    System.assert(!opts.isEmpty(), 'Existing restore profiles should be listed.');
  }

  @IsTest
  static void buildBigObjectApiName_handlesCustomObject() {
    System.assertEquals('Archive_MyObj__b', BIGOTOOL_ArchiveWizardController.buildBigObjectApiName('MyObj__c'));
    System.assertEquals('Archive_Account__b', BIGOTOOL_ArchiveWizardController.buildBigObjectApiName('Account'));
  }
}
