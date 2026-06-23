@IsTest
private class BIGOTOOL_HistoryControllerTest {
  @IsTest
  static void getHistory_nullRecordId_throws() {
    Boolean threw = false;
    Test.startTest();
    try {
      BIGOTOOL_HistoryController.getHistory(null, 50, null);
    } catch (Exception e) {
      threw = true;
    }
    Test.stopTest();
    System.assertEquals(true, threw, 'Null record Id should throw.');
  }

  @IsTest
  static void getHistory_returnsEmptyPageForRealRecord() {
    Account a = new Account(Name = 'History Test');
    insert a;

    Test.startTest();
    BIGOTOOL_HistoryController.HistoryPage page = BIGOTOOL_HistoryController.getHistory(a.Id, 25, null);
    Test.stopTest();

    System.assertNotEquals(null, page, 'Page should not be null.');
    System.assertEquals('Account', page.objectApiName, 'Object API name should resolve from the Id.');
    // Big Object rows are not committed/queryable in test context.
    System.assertEquals(0, page.rows.size(), 'No Big Object rows are queryable in tests.');
    System.assertEquals(false, page.hasMore, 'Empty result should not report more pages.');
  }

  @IsTest
  static void getHistory_withCursorPath() {
    Account a = new Account(Name = 'Cursor Test');
    insert a;

    Test.startTest();
    BIGOTOOL_HistoryController.HistoryPage page = BIGOTOOL_HistoryController.getHistory(a.Id, 500, Datetime.now());
    Test.stopTest();

    System.assertNotEquals(null, page, 'Cursor page should not be null.');
    System.assertEquals('Account', page.objectApiName, 'Object API name should resolve.');
  }

  @IsTest
  static void displayValue_masksHashedValues() {
    System.assertEquals(null, BIGOTOOL_HistoryController.displayValue(null), 'Null stays null.');
    System.assertEquals('Open', BIGOTOOL_HistoryController.displayValue('Open'), 'Plain value passes through.');
    System.assertEquals(
      '••••••••',
      BIGOTOOL_HistoryController.displayValue('MASKED:abc123'),
      'Masked values are never revealed.'
    );
  }

  @IsTest
  static void isMasked_detectsPrefix() {
    System.assertEquals(false, BIGOTOOL_HistoryController.isMasked(null), 'Null is not masked.');
    System.assertEquals(false, BIGOTOOL_HistoryController.isMasked('Open'), 'Plain value is not masked.');
    System.assertEquals(true, BIGOTOOL_HistoryController.isMasked('MASKED:deadbeef'), 'Prefix is masked.');
  }

  @IsTest
  static void resolveUserNames_returnsNamesAndHandlesEmpty() {
    System.assertEquals(
      0,
      BIGOTOOL_HistoryController.resolveUserNames(new Set<String>()).size(),
      'Empty input yields empty map.'
    );

    String uid = String.valueOf(UserInfo.getUserId());
    Map<String, String> names = BIGOTOOL_HistoryController.resolveUserNames(new Set<String>{ uid });
    System.assertEquals(true, names.containsKey(uid), 'Current user should resolve.');
    System.assertEquals(UserInfo.getName(), names.get(uid), 'Resolved name should match current user.');
  }

  @IsTest
  static void toHistoryRows_mapsValuesUsersAndMasking() {
    String uid = String.valueOf(UserInfo.getUserId());
    Datetime t = Datetime.now();

    List<FieldChangeLog__b> records = new List<FieldChangeLog__b>{
      new FieldChangeLog__b(
        ObjectApiName__c = 'Account',
        RecordId__c = '001000000000001',
        ChangedDateTime__c = t,
        Sequence__c = 0,
        FieldApiName__c = 'Name',
        FieldLabel__c = 'Account Name',
        OldValue__c = 'Acme',
        NewValue__c = 'Acme Corp',
        ChangeType__c = 'Update',
        ChangedByUserId__c = uid,
        TransactionId__c = 'TXN-1'
      ),
      new FieldChangeLog__b(
        ObjectApiName__c = 'Account',
        RecordId__c = '001000000000001',
        ChangedDateTime__c = t,
        Sequence__c = 1,
        FieldApiName__c = 'SSN__c',
        FieldLabel__c = '',
        OldValue__c = 'MASKED:abc',
        NewValue__c = 'MASKED:def',
        ChangeType__c = 'Update',
        ChangedByUserId__c = null,
        TransactionId__c = 'TXN-1'
      )
    };

    Test.startTest();
    List<BIGOTOOL_HistoryController.HistoryRow> rows = BIGOTOOL_HistoryController.toHistoryRows(records);
    Test.stopTest();

    System.assertEquals(2, rows.size(), 'Both records should map.');

    BIGOTOOL_HistoryController.HistoryRow first = rows[0];
    System.assertEquals('Account Name', first.fieldLabel, 'Label should map.');
    System.assertEquals('Acme', first.oldValue, 'Old value passes through.');
    System.assertEquals('Acme Corp', first.newValue, 'New value passes through.');
    System.assertEquals(false, first.masked, 'Unmasked row is not flagged.');
    System.assertEquals(UserInfo.getName(), first.changedByName, 'User name resolves.');
    System.assertNotEquals(null, first.rowKey, 'Row key should be built.');

    BIGOTOOL_HistoryController.HistoryRow second = rows[1];
    System.assertEquals('SSN__c', second.fieldLabel, 'Blank label falls back to API name.');
    System.assertEquals(true, second.masked, 'Masked row is flagged.');
    System.assertEquals('••••••••', second.newValue, 'Masked value is hidden.');
    System.assertEquals('System', second.changedByName, 'Null user resolves to System.');
  }

  @IsTest
  static void toHistoryRows_handlesEmpty() {
    System.assertEquals(
      0,
      BIGOTOOL_HistoryController.toHistoryRows(new List<FieldChangeLog__b>()).size(),
      'Empty input yields no rows.'
    );
    System.assertEquals(0, BIGOTOOL_HistoryController.toHistoryRows(null).size(), 'Null input yields no rows.');
  }

  @IsTest
  static void canExport_executes() {
    // Executes the permission-check path; the exact result depends on the
    // running user's assigned permission sets, so only assert it is non-null.
    Boolean result = BIGOTOOL_HistoryController.canExport();
    System.assertNotEquals(null, result, 'canExport should return a Boolean.');
  }
}
