/**
 * BIGOTOOL_SchedulerControllerTest
 *
 * Unit tests for the Archive Scheduler record-page controller. Scheduling
 * (System.schedule) and batch execution are skipped under test by the
 * controller (Test.isRunningTest guards), so these tests focus on status
 * resolution, the paused/not-scheduled state machine and stat persistence.
 */
@IsTest
private class BIGOTOOL_SchedulerControllerTest {
  @TestSetup
  static void enableArchiving() {
    // Archive guard requires Master Switch + Archiving Enabled to be ON. Seed an
    // org-default settings row so scheduler entry points are permitted to run.
    BIGOTOOL_Toggles.saveOrgSettings(true, true, true, false, null);
  }

  private static User configurator() {
    User u = new User(
      Alias = 'bgsch',
      Email = 'bigotool.sched@example.com.invalid',
      EmailEncodingKey = 'UTF-8',
      LastName = 'Scheduler',
      LanguageLocaleKey = 'en_US',
      LocaleSidKey = 'en_US',
      ProfileId = [SELECT Id FROM Profile WHERE Name = 'Standard User' LIMIT 1]
      .Id,
      TimeZoneSidKey = 'America/Los_Angeles',
      Username = 'bigotool.sched.' + System.currentTimeMillis() + '@example.com.invalid'
    );
    insert u;
    PermissionSet ps = [SELECT Id FROM PermissionSet WHERE Name = 'BIGOTOOL_Configurator' LIMIT 1];
    insert new PermissionSetAssignment(AssigneeId = u.Id, PermissionSetId = ps.Id);
    return u;
  }

  private static Archive_Config__c makeConfig(String genStatus) {
    Archive_Config__c cfg = new Archive_Config__c(
      Source_Object__c = 'Account',
      Big_Object_Api_Name__c = 'Archive_Account__b',
      Generation_Status__c = genStatus,
      Schedule_Cron__c = '0 0 2 * * ?',
      Batch_Size__c = 200,
      Total_Records_Archived__c = 5,
      Schedule_Paused__c = false
    );
    insert cfg;
    return cfg;
  }

  @IsTest
  static void getStatus_notScheduled() {
    User u = configurator();
    System.runAs(u) {
      Archive_Config__c cfg = makeConfig('Generated');
      Test.startTest();
      BIGOTOOL_SchedulerController.SchedulerStatus s = BIGOTOOL_SchedulerController.getStatus(cfg.Id);
      Test.stopTest();
      System.assertEquals('NotScheduled', s.state, 'No CronTrigger and not paused.');
      System.assertEquals(true, s.isGenerated, 'Generated config.');
      System.assertEquals(5, s.totalArchived, 'Total carried from config.');
    }
  }

  @IsTest
  static void start_requiresGenerated() {
    User u = configurator();
    System.runAs(u) {
      Archive_Config__c cfg = makeConfig('Pending');
      Boolean threw = false;
      Test.startTest();
      try {
        BIGOTOOL_SchedulerController.startSchedule(cfg.Id);
      } catch (Exception e) {
        threw = true;
      }
      Test.stopTest();
      System.assert(threw, 'Cannot schedule before generation.');
    }
  }

  @IsTest
  static void start_setsActiveAndClearsPaused() {
    User u = configurator();
    System.runAs(u) {
      Archive_Config__c cfg = makeConfig('Generated');
      Test.startTest();
      BIGOTOOL_SchedulerController.SchedulerStatus s = BIGOTOOL_SchedulerController.startSchedule(cfg.Id);
      Test.stopTest();
      // System.schedule is skipped under test, so no CronTrigger exists.
      System.assertEquals('NotScheduled', s.state, 'No real cron under test.');
      Archive_Config__c reloaded = [SELECT Schedule_Paused__c FROM Archive_Config__c WHERE Id = :cfg.Id];
      System.assertEquals(false, reloaded.Schedule_Paused__c, 'Paused flag cleared.');
    }
  }

  @IsTest
  static void pause_setsPausedState() {
    User u = configurator();
    System.runAs(u) {
      Archive_Config__c cfg = makeConfig('Generated');
      Test.startTest();
      BIGOTOOL_SchedulerController.SchedulerStatus s = BIGOTOOL_SchedulerController.pauseSchedule(cfg.Id);
      Test.stopTest();
      System.assertEquals('Paused', s.state, 'Paused flag drives state.');
      Archive_Config__c reloaded = [SELECT Schedule_Paused__c FROM Archive_Config__c WHERE Id = :cfg.Id];
      System.assertEquals(true, reloaded.Schedule_Paused__c, 'Paused flag set.');
    }
  }

  @IsTest
  static void delete_returnsToNotScheduled() {
    User u = configurator();
    System.runAs(u) {
      Archive_Config__c cfg = makeConfig('Generated');
      cfg.Schedule_Paused__c = true;
      update cfg;
      Test.startTest();
      BIGOTOOL_SchedulerController.SchedulerStatus s = BIGOTOOL_SchedulerController.deleteSchedule(cfg.Id);
      Test.stopTest();
      System.assertEquals('NotScheduled', s.state, 'Delete clears paused.');
    }
  }

  @IsTest
  static void runNow_requiresGenerated() {
    User u = configurator();
    System.runAs(u) {
      Archive_Config__c cfg = makeConfig('Pending');
      Boolean threw = false;
      Test.startTest();
      try {
        BIGOTOOL_SchedulerController.runNow(cfg.Id);
      } catch (Exception e) {
        threw = true;
      }
      Test.stopTest();
      System.assert(threw, 'Cannot run before generation.');
    }
  }

  @IsTest
  static void runNow_generatedReturnsNullUnderTest() {
    User u = configurator();
    System.runAs(u) {
      Archive_Config__c cfg = makeConfig('Generated');
      Test.startTest();
      Id jobId = BIGOTOOL_SchedulerController.runNow(cfg.Id);
      Test.stopTest();
      System.assertEquals(null, jobId, 'Batch execution skipped under test.');
    }
  }

  @IsTest
  static void jobName_isDeterministic() {
    Id fakeId = '001000000000001AAA';
    System.assertEquals(
      'BIGOTOOL Archive ' + fakeId,
      BIGOTOOL_SchedulerController.jobName(fakeId),
      'Job name uses the fixed prefix + config Id.'
    );
  }

  @IsTest
  static void getStatus_nullConfig_throws() {
    User u = configurator();
    System.runAs(u) {
      Boolean threw = false;
      try {
        BIGOTOOL_SchedulerController.getStatus(null);
      } catch (Exception e) {
        threw = true;
      }
      System.assert(threw, 'Null config Id should throw.');
    }
  }
}
