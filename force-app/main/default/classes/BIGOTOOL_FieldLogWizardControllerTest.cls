@IsTest
private class BIGOTOOL_FieldLogWizardControllerTest {
  @TestSetup
  static void setup() {
    Profile p = [SELECT Id FROM Profile WHERE Name = 'Standard User' LIMIT 1];
    User u = new User(
      FirstName = 'Big',
      LastName = 'Configurator',
      Email = 'bigotool.configurator@example.com',
      Username = 'bigotool.configurator.' + Crypto.getRandomInteger() + '@example.com.test',
      Alias = 'bcfg',
      TimeZoneSidKey = 'America/Los_Angeles',
      LocaleSidKey = 'en_US',
      EmailEncodingKey = 'UTF-8',
      LanguageLocaleKey = 'en_US',
      ProfileId = p.Id
    );
    insert u;
    PermissionSet ps = [
      SELECT Id
      FROM PermissionSet
      WHERE Name = 'BIGOTOOL_Configurator'
      LIMIT 1
    ];
    insert new PermissionSetAssignment(AssigneeId = u.Id, PermissionSetId = ps.Id);
  }

  private static User configuratorUser() {
    return [
      SELECT Id
      FROM User
      WHERE Email = 'bigotool.configurator@example.com'
      LIMIT 1
    ];
  }

  private static Id saveCfg(BIGOTOOL_FieldLogWizardController.ConfigInput cfgIn) {
    return BIGOTOOL_FieldLogWizardController.saveConfig(JSON.serialize(cfgIn));
  }

  private static BIGOTOOL_FieldLogWizardController.ConfigInput buildInput() {
    BIGOTOOL_FieldLogWizardController.ConfigInput cfgIn = new BIGOTOOL_FieldLogWizardController.ConfigInput();
    cfgIn.configName = 'Account_FieldLog';
    cfgIn.sourceObject = 'Account';
    cfgIn.isActive = true;
    cfgIn.logOnCreate = true;
    cfgIn.logOnUpdate = true;
    cfgIn.logOnDelete = false;
    cfgIn.logOnUndelete = false;
    cfgIn.asyncMode = 'PlatformEvent';
    cfgIn.retentionDays = 90;

    BIGOTOOL_FieldLogWizardController.FieldSelection s1 = new BIGOTOOL_FieldLogWizardController.FieldSelection();
    s1.fieldApiName = 'Name';
    s1.trackOldNew = true;
    s1.maskValue = false;

    BIGOTOOL_FieldLogWizardController.FieldSelection s2 = new BIGOTOOL_FieldLogWizardController.FieldSelection();
    s2.fieldApiName = 'Industry';
    s2.trackOldNew = true;
    s2.maskValue = true;

    cfgIn.fields = new List<BIGOTOOL_FieldLogWizardController.FieldSelection>{ s1, s2 };
    return cfgIn;
  }

  @IsTest
  static void getObjectOptionsReturnsObjects() {
    List<BIGOTOOL_FieldLogWizardController.PicklistOption> opts;
    System.runAs(configuratorUser()) {
      Test.startTest();
      opts = BIGOTOOL_FieldLogWizardController.getObjectOptions();
      Test.stopTest();
    }

    System.assert(!opts.isEmpty(), 'Expected some object options');
    Boolean foundAccount = false;
    for (BIGOTOOL_FieldLogWizardController.PicklistOption o : opts) {
      if (o.value == 'Account') {
        foundAccount = true;
      }
      System.assert(!o.value.endsWith('__b'), 'Big Objects must be excluded');
      System.assert(!o.value.endsWith('__e'), 'Platform Events must be excluded');
      System.assert(!o.value.endsWith('Share'), 'Share objects must be excluded: ' + o.value);
      System.assert(!o.value.endsWith('History'), 'History objects must be excluded: ' + o.value);
      System.assert(!o.value.endsWith('ChangeEvent'), 'Change Event objects must be excluded: ' + o.value);
    }
    System.assert(foundAccount, 'Account should be selectable');
  }

  @IsTest
  static void getFieldOptionsReturnsFields() {
    List<BIGOTOOL_FieldLogWizardController.FieldOption> fields;
    System.runAs(configuratorUser()) {
      Test.startTest();
      fields = BIGOTOOL_FieldLogWizardController.getFieldOptions('Account');
      Test.stopTest();
    }

    System.assert(!fields.isEmpty(), 'Expected fields for Account');
    Boolean foundName = false;
    for (BIGOTOOL_FieldLogWizardController.FieldOption f : fields) {
      if (f.apiName == 'Name') {
        foundName = true;
      }
    }
    System.assert(foundName, 'Name field should be returned');
  }

  @IsTest
  static void getFieldOptionsBlankThrows() {
    Boolean threw = false;
    System.runAs(configuratorUser()) {
      try {
        BIGOTOOL_FieldLogWizardController.getFieldOptions('');
      } catch (Exception e) {
        threw = true;
      }
    }
    System.assert(threw, 'Blank object should throw');
  }

  @IsTest
  static void saveConfigInsertsConfigAndChildren() {
    BIGOTOOL_FieldLogWizardController.ConfigInput cfgIn = buildInput();
    Id configId;
    System.runAs(configuratorUser()) {
      Test.startTest();
      configId = saveCfg(cfgIn);
      Test.stopTest();
    }

    System.assertNotEquals(null, configId, 'Config Id should be returned');
    Field_Log_Config__c cfg = [
      SELECT
        Source_Object__c,
        Source_Object_Label__c,
        Is_Active__c,
        Async_Mode__c,
        Retention_Days__c,
        Log_On_Create__c,
        Log_On_Update__c,
        Trigger_Generated__c
      FROM Field_Log_Config__c
      WHERE Id = :configId
    ];
    System.assertEquals('Account', cfg.Source_Object__c);
    System.assertEquals('Account', cfg.Source_Object_Label__c, 'Object label should be stored');
    System.assertEquals(true, cfg.Is_Active__c);
    System.assertEquals('PlatformEvent', cfg.Async_Mode__c);
    System.assertEquals(90, cfg.Retention_Days__c);
    System.assertEquals(true, cfg.Log_On_Create__c);
    System.assertEquals(true, cfg.Log_On_Update__c);
    System.assertEquals(false, cfg.Trigger_Generated__c);

    List<Field_Log_Field__c> children = [
      SELECT Field_Api_Name__c, Field_Label__c, Track_Old_New__c, Mask_Value__c
      FROM Field_Log_Field__c
      WHERE Field_Log_Config__c = :configId
      ORDER BY Field_Api_Name__c
    ];
    System.assertEquals(2, children.size(), 'Two child rows expected');
    for (Field_Log_Field__c child : children) {
      System.assertEquals(true, child.Track_Old_New__c, 'All tracked fields must capture old/new values');
      System.assertNotEquals(null, child.Field_Label__c, 'Field label should be stored');
      System.assert(String.isNotBlank(child.Field_Label__c), 'Field label should not be blank');
    }
  }

  @IsTest
  static void saveConfigUpdateReplacesChildren() {
    BIGOTOOL_FieldLogWizardController.ConfigInput first = buildInput();
    Id configId;
    System.runAs(configuratorUser()) {
      configId = saveCfg(first);

      BIGOTOOL_FieldLogWizardController.ConfigInput upd = buildInput();
      upd.configId = configId;
      BIGOTOOL_FieldLogWizardController.FieldSelection only = new BIGOTOOL_FieldLogWizardController.FieldSelection();
      only.fieldApiName = 'Name';
      only.trackOldNew = true;
      only.maskValue = false;
      upd.fields = new List<BIGOTOOL_FieldLogWizardController.FieldSelection>{ only };

      Test.startTest();
      saveCfg(upd);
      Test.stopTest();
    }

    List<Field_Log_Field__c> children = [
      SELECT Id
      FROM Field_Log_Field__c
      WHERE Field_Log_Config__c = :configId
    ];
    System.assertEquals(1, children.size(), 'Children should be replaced, not appended');
    System.assertEquals(1, [SELECT COUNT() FROM Field_Log_Config__c WHERE Id = :configId]);
  }

  @IsTest
  static void saveConfigDeduplicatesFields() {
    BIGOTOOL_FieldLogWizardController.ConfigInput cfgIn = buildInput();
    BIGOTOOL_FieldLogWizardController.FieldSelection dup = new BIGOTOOL_FieldLogWizardController.FieldSelection();
    dup.fieldApiName = 'name';
    dup.trackOldNew = true;
    dup.maskValue = false;
    cfgIn.fields.add(dup);

    Id configId;
    System.runAs(configuratorUser()) {
      configId = saveCfg(cfgIn);
    }
    System.assertEquals(
      2,
      [
        SELECT COUNT()
        FROM Field_Log_Field__c
        WHERE Field_Log_Config__c = :configId
      ]
    );
  }

  @IsTest
  static void saveConfigNoFieldsThrows() {
    BIGOTOOL_FieldLogWizardController.ConfigInput cfgIn = buildInput();
    cfgIn.fields = new List<BIGOTOOL_FieldLogWizardController.FieldSelection>();
    Boolean threw = false;
    System.runAs(configuratorUser()) {
      try {
        saveCfg(cfgIn);
      } catch (Exception e) {
        threw = true;
      }
    }
    System.assert(threw, 'Empty field list should throw');
  }

  @IsTest
  static void saveConfigBadAsyncModeThrows() {
    BIGOTOOL_FieldLogWizardController.ConfigInput cfgIn = buildInput();
    cfgIn.asyncMode = 'Telepathy';
    Boolean threw = false;
    System.runAs(configuratorUser()) {
      try {
        saveCfg(cfgIn);
      } catch (Exception e) {
        threw = true;
      }
    }
    System.assert(threw, 'Invalid async mode should throw');
  }

  @IsTest
  static void saveConfigNullThrows() {
    Boolean threw = false;
    System.runAs(configuratorUser()) {
      try {
        BIGOTOOL_FieldLogWizardController.saveConfig(null);
      } catch (Exception e) {
        threw = true;
      }
    }
    System.assert(threw, 'Null input should throw');
  }

  @IsTest
  static void noPermissionThrows() {
    Profile p = [SELECT Id FROM Profile WHERE Name = 'Standard User' LIMIT 1];
    User plain = new User(
      FirstName = 'No',
      LastName = 'Perm',
      Email = 'bigotool.noperm@example.com',
      Username = 'bigotool.noperm.' + Crypto.getRandomInteger() + '@example.com.test',
      Alias = 'nopm',
      TimeZoneSidKey = 'America/Los_Angeles',
      LocaleSidKey = 'en_US',
      EmailEncodingKey = 'UTF-8',
      LanguageLocaleKey = 'en_US',
      ProfileId = p.Id
    );
    insert plain;

    Boolean threw = false;
    System.runAs(plain) {
      try {
        BIGOTOOL_FieldLogWizardController.getObjectOptions();
      } catch (Exception e) {
        threw = true;
      }
    }
    System.assert(threw, 'User without Can_Configure should be rejected');
  }

  @IsTest
  static void generateTriggerCodeBuildsCodeAndSetsFlag() {
    BIGOTOOL_FieldLogWizardController.ConfigInput cfgIn = buildInput();
    Id configId;
    BIGOTOOL_FieldLogWizardController.TriggerCodeResult res;
    System.runAs(configuratorUser()) {
      configId = saveCfg(cfgIn);
      Test.startTest();
      res = BIGOTOOL_FieldLogWizardController.generateTriggerCode(configId);
      Test.stopTest();
    }

    System.assertNotEquals(null, res, 'Result should be returned');
    System.assertEquals('Account', res.objectApiName);
    System.assertEquals('AccountFieldLogTrigger', res.triggerName);
    System.assert(
      res.triggerBody.contains('trigger AccountFieldLogTrigger on Account'),
      'Trigger body should declare the trigger'
    );
    System.assert(
      res.triggerBody.contains('BIGOTOOL_ChangeCapture.run'),
      'Trigger body should delegate to the handler'
    );
    System.assert(
      res.events.contains('after insert') && res.events.contains('after update'),
      'Events should reflect selected operations'
    );
    System.assert(String.isNotBlank(res.instructions), 'Instructions should be provided');

    Field_Log_Config__c cfg = [
      SELECT Trigger_Generated__c
      FROM Field_Log_Config__c
      WHERE Id = :configId
    ];
    System.assertEquals(true, cfg.Trigger_Generated__c, 'Trigger Generated flag should be set');
  }

  @IsTest
  static void generateTriggerNameStripsCustomSuffix() {
    System.assertEquals('My_ObjectFieldLogTrigger', BIGOTOOL_FieldLogWizardController.buildTriggerName('My_Object__c'));
  }

  @IsTest
  static void generateTriggerCodeRequiresId() {
    Boolean threw = false;
    System.runAs(configuratorUser()) {
      try {
        BIGOTOOL_FieldLogWizardController.generateTriggerCode(null);
      } catch (Exception e) {
        threw = true;
      }
    }
    System.assert(threw, 'Null config id should throw');
  }

  @IsTest
  static void getTriggerCodeStatusReflectsGenerationWithoutSideEffect() {
    BIGOTOOL_FieldLogWizardController.ConfigInput cfgIn = buildInput();
    Id configId;
    BIGOTOOL_FieldLogWizardController.TriggerCodeResult before;
    BIGOTOOL_FieldLogWizardController.TriggerCodeResult after;
    System.runAs(configuratorUser()) {
      configId = saveCfg(cfgIn);

      Test.startTest();
      before = BIGOTOOL_FieldLogWizardController.getTriggerCodeStatus(configId);
      BIGOTOOL_FieldLogWizardController.generateTriggerCode(configId);
      after = BIGOTOOL_FieldLogWizardController.getTriggerCodeStatus(configId);
      Test.stopTest();
    }

    System.assertEquals(false, before.alreadyGenerated, 'Status should be not-generated before generation');
    System.assert(
      before.triggerBody.contains('trigger AccountFieldLogTrigger on Account'),
      'Preview should still include the trigger body'
    );
    System.assertEquals(true, after.alreadyGenerated, 'Status should reflect generation afterward');

    Field_Log_Config__c cfg = [
      SELECT Trigger_Generated__c
      FROM Field_Log_Config__c
      WHERE Id = :configId
    ];
    System.assertEquals(true, cfg.Trigger_Generated__c, 'Status query alone must not have changed the flag');
  }

  @IsTest
  static void getTriggerCodeStatusRequiresId() {
    Boolean threw = false;
    System.runAs(configuratorUser()) {
      try {
        BIGOTOOL_FieldLogWizardController.getTriggerCodeStatus(null);
      } catch (Exception e) {
        threw = true;
      }
    }
    System.assert(threw, 'Null config id should throw');
  }
}
