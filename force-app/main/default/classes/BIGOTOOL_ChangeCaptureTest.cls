@IsTest
private class BIGOTOOL_ChangeCaptureTest {
  private static void enableSettings(Boolean master, Boolean logging) {
    BIGOTOOL_Settings__c cs = BIGOTOOL_Settings__c.getOrgDefaults();
    if (cs.Id == null && cs.SetupOwnerId == null) {
      cs.SetupOwnerId = UserInfo.getOrganizationId();
    }
    cs.Master_Switch__c = master;
    cs.Logging_Enabled__c = logging;
    upsert cs;
  }

  private static Field_Log_Config__c setupAccountConfig(String asyncMode, Boolean isActive) {
    Field_Log_Config__c cfg = new Field_Log_Config__c(
      Name = 'Account_FieldLog',
      Source_Object__c = 'Account',
      Source_Object_Label__c = 'Account',
      Is_Active__c = isActive,
      Log_On_Create__c = true,
      Log_On_Update__c = true,
      Log_On_Delete__c = true,
      Log_On_Undelete__c = true,
      Async_Mode__c = asyncMode,
      Retention_Days__c = 0,
      Trigger_Generated__c = true
    );
    insert cfg;

    insert new List<Field_Log_Field__c>{
      new Field_Log_Field__c(
        Field_Log_Config__c = cfg.Id,
        Field_Api_Name__c = 'Name',
        Field_Label__c = 'Account Name',
        Track_Old_New__c = true,
        Mask_Value__c = false
      ),
      new Field_Log_Field__c(
        Field_Log_Config__c = cfg.Id,
        Field_Api_Name__c = 'Industry',
        Field_Label__c = 'Industry',
        Track_Old_New__c = true,
        Mask_Value__c = true
      )
    };

    BIGOTOOL_ConfigRepo.clearCache();
    return cfg;
  }

  private static Account insertedAccount() {
    Account acc = new Account(Name = 'Acme', Industry = 'Technology');
    insert acc;
    return acc;
  }

  @IsTest
  static void togglesReflectConfigAndSwitches() {
    enableSettings(true, true);
    setupAccountConfig('PlatformEvent', true);
    System.assertEquals(
      true,
      BIGOTOOL_Toggles.loggingEnabled('Account'),
      'Active config with fields should enable logging'
    );
    System.assertEquals(false, BIGOTOOL_Toggles.loggingEnabled('Contact'), 'Object without config should be disabled');
    System.assertEquals('PlatformEvent', BIGOTOOL_Toggles.asyncMode('Account'));
    System.assertEquals('PlatformEvent', BIGOTOOL_Toggles.asyncMode('Contact'), 'Default async mode is PlatformEvent');
  }

  @IsTest
  static void inactiveConfigDisablesLogging() {
    setupAccountConfig('PlatformEvent', false);
    System.assertEquals(false, BIGOTOOL_Toggles.loggingEnabled('Account'), 'Inactive config should not log');
  }

  @IsTest
  static void masterSwitchOffDisablesLogging() {
    enableSettings(false, true);
    setupAccountConfig('PlatformEvent', true);
    System.assertEquals(false, BIGOTOOL_Toggles.loggingEnabled('Account'), 'Master kill-switch should disable logging');
  }

  @IsTest
  static void diffUpdateCapturesChangedFieldOnly() {
    setupAccountConfig('PlatformEvent', true);
    Account acc = insertedAccount();
    Map<Id, SObject> oldMap = new Map<Id, SObject>{
      acc.Id => new Account(Id = acc.Id, Name = 'Acme', Industry = 'Technology')
    };
    Map<Id, SObject> newMap = new Map<Id, SObject>{
      acc.Id => new Account(Id = acc.Id, Name = 'Acme 2', Industry = 'Technology')
    };

    List<FieldChangeLog__b> rows = BIGOTOOL_Differ.diff(
      'Account',
      System.TriggerOperation.AFTER_UPDATE,
      oldMap,
      newMap
    );

    System.assertEquals(1, rows.size(), 'Only the changed field should log');
    FieldChangeLog__b row = rows[0];
    System.assertEquals('Name', row.FieldApiName__c);
    System.assertEquals('Acme', row.OldValue__c);
    System.assertEquals('Acme 2', row.NewValue__c);
    System.assertEquals('Update', row.ChangeType__c);
    System.assertEquals('Account', row.ObjectApiName__c);
    System.assertEquals(acc.Id, row.RecordId__c);
    System.assertNotEquals(null, row.ChangedDateTime__c);
    System.assertEquals(UserInfo.getUserId(), row.ChangedByUserId__c);
  }

  @IsTest
  static void diffInsertMasksFlaggedField() {
    setupAccountConfig('PlatformEvent', true);
    Account acc = insertedAccount();
    Map<Id, SObject> newMap = new Map<Id, SObject>{
      acc.Id => new Account(Id = acc.Id, Name = 'Acme', Industry = 'Technology')
    };

    List<FieldChangeLog__b> rows = BIGOTOOL_Differ.diff('Account', System.TriggerOperation.AFTER_INSERT, null, newMap);

    System.assertEquals(2, rows.size(), 'Both populated fields log on create');
    Boolean foundMasked = false;
    for (FieldChangeLog__b row : rows) {
      System.assertEquals('Create', row.ChangeType__c);
      if (row.FieldApiName__c == 'Industry') {
        foundMasked = true;
        System.assert(row.NewValue__c.startsWith('MASKED:'), 'Masked field should store a hash, not raw value');
        System.assertNotEquals('Technology', row.NewValue__c);
      }
    }
    System.assert(foundMasked, 'Industry row should be present');
  }

  @IsTest
  static void diffDeleteCapturesOldValues() {
    setupAccountConfig('PlatformEvent', true);
    Account acc = insertedAccount();
    Map<Id, SObject> oldMap = new Map<Id, SObject>{
      acc.Id => new Account(Id = acc.Id, Name = 'Acme', Industry = 'Technology')
    };

    List<FieldChangeLog__b> rows = BIGOTOOL_Differ.diff('Account', System.TriggerOperation.AFTER_DELETE, oldMap, null);

    System.assertEquals(2, rows.size());
    for (FieldChangeLog__b row : rows) {
      System.assertEquals('Delete', row.ChangeType__c);
      System.assertNotEquals(null, row.OldValue__c);
      System.assertEquals(null, row.NewValue__c);
    }
  }

  @IsTest
  static void diffUndeleteCapturesNewValues() {
    setupAccountConfig('PlatformEvent', true);
    Account acc = insertedAccount();
    Map<Id, SObject> newMap = new Map<Id, SObject>{
      acc.Id => new Account(Id = acc.Id, Name = 'Acme', Industry = 'Technology')
    };

    List<FieldChangeLog__b> rows = BIGOTOOL_Differ.diff(
      'Account',
      System.TriggerOperation.AFTER_UNDELETE,
      null,
      newMap
    );

    System.assertEquals(2, rows.size());
    for (FieldChangeLog__b row : rows) {
      System.assertEquals('Undelete', row.ChangeType__c);
    }
  }

  @IsTest
  static void diffReturnsEmptyForUnknownObject() {
    BIGOTOOL_ConfigRepo.clearCache();
    List<FieldChangeLog__b> rows = BIGOTOOL_Differ.diff(
      'Nonexistent__x',
      System.TriggerOperation.AFTER_UPDATE,
      new Map<Id, SObject>(),
      new Map<Id, SObject>()
    );
    System.assertEquals(0, rows.size());
  }

  @IsTest
  static void changeCapturePlatformEventPath() {
    enableSettings(true, true);
    setupAccountConfig('PlatformEvent', true);
    Account acc = insertedAccount();
    Map<Id, SObject> oldMap = new Map<Id, SObject>{
      acc.Id => new Account(Id = acc.Id, Name = 'Acme', Industry = 'Technology')
    };
    Map<Id, SObject> newMap = new Map<Id, SObject>{
      acc.Id => new Account(Id = acc.Id, Name = 'Acme 2', Industry = 'Technology')
    };

    Test.startTest();
    BIGOTOOL_ChangeCapture.run('Account', System.TriggerOperation.AFTER_UPDATE, oldMap, newMap);
    Test.stopTest();

    System.assertNotEquals(
      null,
      BIGOTOOL_LogWriter.lastWritten,
      'Subscriber should have written rows after event delivery'
    );
    System.assert(BIGOTOOL_LogWriter.lastWritten.size() >= 1, 'At least one row should be written');
  }

  @IsTest
  static void changeCaptureQueueablePath() {
    enableSettings(true, true);
    setupAccountConfig('Queueable', true);
    Account acc = insertedAccount();
    Map<Id, SObject> oldMap = new Map<Id, SObject>{
      acc.Id => new Account(Id = acc.Id, Name = 'Acme', Industry = 'Technology')
    };
    Map<Id, SObject> newMap = new Map<Id, SObject>{
      acc.Id => new Account(Id = acc.Id, Name = 'Acme 2', Industry = 'Technology')
    };

    Test.startTest();
    BIGOTOOL_ChangeCapture.run('Account', System.TriggerOperation.AFTER_UPDATE, oldMap, newMap);
    Test.stopTest();

    System.assertNotEquals(null, BIGOTOOL_LogWriter.lastWritten, 'Queueable should have written rows');
  }

  @IsTest
  static void changeCaptureSynchronousPath() {
    enableSettings(true, true);
    setupAccountConfig('Synchronous', true);
    Account acc = insertedAccount();
    Map<Id, SObject> oldMap = new Map<Id, SObject>{
      acc.Id => new Account(Id = acc.Id, Name = 'Acme', Industry = 'Technology')
    };
    Map<Id, SObject> newMap = new Map<Id, SObject>{
      acc.Id => new Account(Id = acc.Id, Name = 'Acme 2', Industry = 'Technology')
    };

    BIGOTOOL_ChangeCapture.run('Account', System.TriggerOperation.AFTER_UPDATE, oldMap, newMap);

    System.assertNotEquals(null, BIGOTOOL_LogWriter.lastWritten, 'Synchronous path should write immediately');
  }

  @IsTest
  static void changeCaptureSkipsWhenDisabled() {
    setupAccountConfig('PlatformEvent', false);
    BIGOTOOL_LogWriter.lastWritten = null;
    BIGOTOOL_ChangeCapture.run(
      'Account',
      System.TriggerOperation.AFTER_UPDATE,
      new Map<Id, SObject>(),
      new Map<Id, SObject>()
    );
    System.assertEquals(null, BIGOTOOL_LogWriter.lastWritten, 'Disabled config should not write');
  }

  @IsTest
  static void eventPublisherRoundTrip() {
    FieldChange__e e = new FieldChange__e(
      ObjectApiName__c = 'Account',
      RecordId__c = '001000000000001',
      FieldApiName__c = 'Name',
      FieldLabel__c = 'Account Name',
      OldValue__c = 'A',
      NewValue__c = 'B',
      ChangeType__c = 'Update',
      ChangedByUserId__c = UserInfo.getUserId(),
      TransactionId__c = 'TXN1'
    );

    List<FieldChangeLog__b> rows = BIGOTOOL_EventPublisher.toBigObjectRows(new List<FieldChange__e>{ e });

    System.assertEquals(1, rows.size());
    System.assertEquals('Account', rows[0].ObjectApiName__c);
    System.assertEquals('B', rows[0].NewValue__c);
    System.assertNotEquals(null, rows[0].ChangedDateTime__c, 'Null datetime should default to now');
    System.assertEquals(0, rows[0].Sequence__c, 'Null sequence defaults to 0');
  }

  @IsTest
  static void queueableExecutesWriter() {
    FieldChangeLog__b row = new FieldChangeLog__b(
      ObjectApiName__c = 'Account',
      RecordId__c = '001000000000001',
      FieldApiName__c = 'Name',
      ChangeType__c = 'Update',
      ChangedDateTime__c = Datetime.now(),
      Sequence__c = 0
    );
    BIGOTOOL_LogFlushQueueable job = new BIGOTOOL_LogFlushQueueable(new List<FieldChangeLog__b>{ row });

    Test.startTest();
    System.enqueueJob(job);
    Test.stopTest();

    System.assertNotEquals(null, BIGOTOOL_LogWriter.lastWritten);
  }

  @IsTest
  static void helperEdgeCases() {
    System.assertEquals(true, BIGOTOOL_Differ.valuesEqual(null, null));
    System.assertEquals(false, BIGOTOOL_Differ.valuesEqual('a', null));
    System.assertEquals(false, BIGOTOOL_Differ.valuesEqual('a', 'b'));
    System.assertEquals(null, BIGOTOOL_Differ.render(null, false));
    System.assertEquals('plain', BIGOTOOL_Differ.render('plain', false));
    System.assert(BIGOTOOL_Differ.render('secret', true).startsWith('MASKED:'));
    BIGOTOOL_EventPublisher.publish(null);
    BIGOTOOL_LogWriter.write(null);
    System.assertEquals(
      true,
      BIGOTOOL_EventPublisher.toBigObjectRows(null).isEmpty(),
      'Null events should produce an empty list'
    );
  }
}
