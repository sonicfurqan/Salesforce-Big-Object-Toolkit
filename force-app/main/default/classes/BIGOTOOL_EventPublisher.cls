/**
 * Bridges captured FieldChangeLog__b rows and the FieldChange__e platform event
 * used to decouple Big Object writes from the originating transaction.
 */
public with sharing class BIGOTOOL_EventPublisher {
  public static void publish(List<FieldChangeLog__b> logs) {
    if (logs == null || logs.isEmpty()) {
      return;
    }
    List<FieldChange__e> events = new List<FieldChange__e>();
    for (FieldChangeLog__b log : logs) {
      events.add(
        new FieldChange__e(
          ObjectApiName__c = log.ObjectApiName__c,
          RecordId__c = log.RecordId__c,
          FieldApiName__c = log.FieldApiName__c,
          FieldLabel__c = log.FieldLabel__c,
          OldValue__c = log.OldValue__c,
          NewValue__c = log.NewValue__c,
          ChangeType__c = log.ChangeType__c,
          ChangedDateTime__c = log.ChangedDateTime__c,
          ChangedByUserId__c = log.ChangedByUserId__c,
          TransactionId__c = log.TransactionId__c,
          Sequence__c = log.Sequence__c
        )
      );
    }
    EventBus.publish(events);
  }

  /**
   * Converts received platform events back into Big Object rows for the
   * subscriber to persist.
   */
  public static List<FieldChangeLog__b> toBigObjectRows(List<FieldChange__e> events) {
    List<FieldChangeLog__b> rows = new List<FieldChangeLog__b>();
    if (events == null) {
      return rows;
    }
    for (FieldChange__e e : events) {
      rows.add(
        new FieldChangeLog__b(
          ObjectApiName__c = e.ObjectApiName__c,
          RecordId__c = e.RecordId__c,
          FieldApiName__c = e.FieldApiName__c,
          FieldLabel__c = e.FieldLabel__c,
          OldValue__c = e.OldValue__c,
          NewValue__c = e.NewValue__c,
          ChangeType__c = e.ChangeType__c,
          ChangedDateTime__c = e.ChangedDateTime__c == null ? Datetime.now() : e.ChangedDateTime__c,
          ChangedByUserId__c = e.ChangedByUserId__c,
          TransactionId__c = e.TransactionId__c,
          Sequence__c = e.Sequence__c == null ? 0 : e.Sequence__c
        )
      );
    }
    return rows;
  }
}
