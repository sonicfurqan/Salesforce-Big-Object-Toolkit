@IsTest
private class BIGOTOOL_ArchiveGuardTest {
  @IsTest
  static void blocksByDefaultWhenArchivingNotEnabled() {
    // With no custom setting row, Archiving_Enabled__c defaults to false, so the
    // guard blocks until archiving is explicitly switched on.
    Test.startTest();
    BIGOTOOL_ArchiveGuard.Decision d = BIGOTOOL_ArchiveGuard.evaluate();
    Test.stopTest();
    System.assertEquals(false, d.allowed, 'Archiving is off by default until enabled.');
    System.assertEquals(false, BIGOTOOL_ArchiveGuard.canRun(), 'canRun mirrors evaluate.');
  }

  @IsTest
  static void blocksWhenMasterSwitchOff() {
    insert new BIGOTOOL_Settings__c(
      SetupOwnerId = UserInfo.getOrganizationId(),
      Master_Switch__c = false,
      Archiving_Enabled__c = true
    );
    Test.startTest();
    BIGOTOOL_ArchiveGuard.Decision d = BIGOTOOL_ArchiveGuard.evaluate();
    Test.stopTest();
    System.assertEquals(false, d.allowed, 'Master switch off blocks.');
    System.assert(d.reason.contains('Master Switch'), 'Reason mentions master switch.');
  }

  @IsTest
  static void blocksWhenArchivingDisabled() {
    insert new BIGOTOOL_Settings__c(
      SetupOwnerId = UserInfo.getOrganizationId(),
      Master_Switch__c = true,
      Archiving_Enabled__c = false
    );
    Test.startTest();
    BIGOTOOL_ArchiveGuard.Decision d = BIGOTOOL_ArchiveGuard.evaluate();
    Test.stopTest();
    System.assertEquals(false, d.allowed, 'Archiving disabled blocks.');
    System.assert(d.reason.contains('Archiving'), 'Reason mentions archiving.');
  }

  @IsTest
  static void allowsWhenUnderConcurrencyLimit() {
    insert new BIGOTOOL_Settings__c(
      SetupOwnerId = UserInfo.getOrganizationId(),
      Master_Switch__c = true,
      Archiving_Enabled__c = true,
      Max_Batch_Concurrency__c = 3
    );
    Test.startTest();
    // No batch jobs are in flight in the test context, so the run is allowed.
    BIGOTOOL_ArchiveGuard.Decision d = BIGOTOOL_ArchiveGuard.evaluate();
    Test.stopTest();
    System.assertEquals(true, d.allowed, 'Under the configured limit, archiving is allowed.');
  }

  @IsTest
  static void blocksWhenAtConcurrencyLimit() {
    insert new BIGOTOOL_Settings__c(
      SetupOwnerId = UserInfo.getOrganizationId(),
      Master_Switch__c = true,
      Archiving_Enabled__c = true,
      Max_Batch_Concurrency__c = 2
    );
    BIGOTOOL_ArchiveGuard.testActiveJobCount = 2;
    Test.startTest();
    BIGOTOOL_ArchiveGuard.Decision d = BIGOTOOL_ArchiveGuard.evaluate();
    Test.stopTest();
    System.assertEquals(false, d.allowed, 'At the concurrency limit, archiving is blocked.');
    System.assert(d.reason.contains('Max Batch Concurrency'), 'Reason mentions the concurrency limit.');
  }
}
