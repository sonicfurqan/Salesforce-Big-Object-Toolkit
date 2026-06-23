@IsTest
private class BIGOTOOL_DashboardControllerTest {
  @IsTest
  static void getDashboard_returnsStructureWithConfigCounts() {
    insert new Field_Log_Config__c(
      Name = 'Acct Log',
      Source_Object__c = 'Account',
      Is_Active__c = true,
      Trigger_Generated__c = true
    );
    insert new Field_Log_Config__c(
      Name = 'Con Log',
      Source_Object__c = 'Contact',
      Is_Active__c = false,
      Trigger_Generated__c = false
    );
    insert new Archive_Config__c(
      Name = 'Old Cases',
      Source_Object__c = 'Case',
      Big_Object_Api_Name__c = 'Archive_Case__b',
      Is_Active__c = true
    );

    Test.startTest();
    BIGOTOOL_DashboardController.DashboardData data = BIGOTOOL_DashboardController.getDashboard();
    Test.stopTest();

    System.assertNotEquals(null, data, 'Dashboard data should not be null.');
    System.assertEquals(2, data.config.logTotal, 'Two log configs.');
    System.assertEquals(1, data.config.logActive, 'One active log config.');
    System.assertEquals(1, data.config.logTriggered, 'One triggered log config.');
    System.assertEquals(1, data.config.archiveTotal, 'One archive config.');
    System.assertEquals(1, data.config.archiveActive, 'One active archive config.');
    System.assertNotEquals(null, data.jobs, 'Job summary present.');
    System.assertEquals(0, data.jobs.totalRuns, 'No Big Object rows queryable in tests.');
    System.assertNotEquals(null, data.toggles, 'Toggles present.');
    System.assertNotEquals(null, data.generatedAt, 'Timestamp present.');
  }

  @IsTest
  static void summarizeJobs_aggregatesAndRanksRecent() {
    Datetime base = Datetime.now();
    List<Archive_Job_Log__b> rows = new List<Archive_Job_Log__b>{
      new Archive_Job_Log__b(
        ConfigName__c = 'Old Cases',
        JobType__c = 'Archive',
        Status__c = 'Success',
        RecordsProcessed__c = 100,
        RecordsFailed__c = 0,
        RunDateTime__c = base.addMinutes(-30)
      ),
      new Archive_Job_Log__b(
        ConfigName__c = 'Old Cases',
        JobType__c = 'Archive',
        Status__c = 'Failed',
        RecordsProcessed__c = 50,
        RecordsFailed__c = 5,
        RunDateTime__c = base.addMinutes(-10),
        ErrorSummary__c = 'Boom'
      ),
      new Archive_Job_Log__b(
        ConfigName__c = 'Export Job',
        JobType__c = 'Export',
        Status__c = 'Completed',
        RecordsProcessed__c = 1000,
        RecordsFailed__c = null,
        RunDateTime__c = base.addMinutes(-5)
      )
    };

    Test.startTest();
    BIGOTOOL_DashboardController.JobSummary summary = BIGOTOOL_DashboardController.summarizeJobs(rows);
    Test.stopTest();

    System.assertEquals(3, summary.totalRuns, 'Three runs counted.');
    System.assertEquals(1, summary.failedRuns, 'One failed run.');
    System.assertEquals(2, summary.successRuns, 'Two successful runs.');
    System.assertEquals(1150, summary.totalProcessed, 'Processed totals summed.');
    System.assertEquals(5, summary.totalFailed, 'Failed totals summed.');
    System.assertEquals(2, summary.byType.size(), 'Two job types.');

    // Recent list is newest-first.
    System.assertEquals(3, summary.recent.size(), 'All three appear in recent.');
    System.assertEquals('Export', summary.recent[0].jobType, 'Most recent run first.');
    System.assertNotEquals(null, summary.recent[0].rowKey, 'Row key built.');
  }

  @IsTest
  static void summarizeJobs_handlesEmptyAndNull() {
    System.assertEquals(
      0,
      BIGOTOOL_DashboardController.summarizeJobs(new List<Archive_Job_Log__b>()).totalRuns,
      'Empty input yields zero runs.'
    );
    System.assertEquals(
      0,
      BIGOTOOL_DashboardController.summarizeJobs(null).totalRuns,
      'Null input yields zero runs.'
    );
  }

  @IsTest
  static void getDashboard_reflectsToggleState() {
    insert new BIGOTOOL_Settings__c(
      SetupOwnerId = UserInfo.getOrganizationId(),
      Master_Switch__c = false,
      Logging_Enabled__c = false,
      Archiving_Enabled__c = true,
      Debug_Mode__c = true
    );

    Test.startTest();
    BIGOTOOL_DashboardController.DashboardData data = BIGOTOOL_DashboardController.getDashboard();
    Test.stopTest();

    System.assertEquals(false, data.toggles.masterSwitch, 'Master switch off.');
    System.assertEquals(false, data.toggles.loggingEnabled, 'Logging off.');
    System.assertEquals(true, data.toggles.archivingEnabled, 'Archiving on.');
    System.assertEquals(true, data.toggles.debugMode, 'Debug on.');
  }
}
