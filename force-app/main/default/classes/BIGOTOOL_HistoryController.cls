/**
 * Read API for the Field History Timeline LWC (bigotoolHistoryTimeline).
 *
 * Serves field-change history from the universal FieldChangeLog__b Big Object for
 * a single record. Pagination is cursor-based on the ChangedDateTime__c index
 * column (Big Objects do not support OFFSET); the LWC passes back the cursor from
 * the previous page and de-duplicates overlap on the timestamp boundary.
 *
 * Runs WITHOUT sharing because Big Objects do not enforce record-level sharing;
 * read access is governed instead by the BIGOTOOL_History_Viewer / Administrator
 * permission sets (object + field level on FieldChangeLog__b). Masked values are
 * never un-masked here — they are stored hashed by BIGOTOOL_Differ.
 */
public without sharing class BIGOTOOL_HistoryController {
  @TestVisible
  private static final Integer DEFAULT_PAGE_SIZE = 50;
  @TestVisible
  private static final Integer MAX_PAGE_SIZE = 200;
  private static final String MASK_PREFIX = 'MASKED:';

  public class HistoryRow {
    @AuraEnabled
    public String fieldApiName;
    @AuraEnabled
    public String fieldLabel;
    @AuraEnabled
    public String oldValue;
    @AuraEnabled
    public String newValue;
    @AuraEnabled
    public Boolean masked;
    @AuraEnabled
    public String changeType;
    @AuraEnabled
    public Datetime changedDateTime;
    @AuraEnabled
    public Decimal sequence;
    @AuraEnabled
    public String changedByUserId;
    @AuraEnabled
    public String changedByName;
    @AuraEnabled
    public String transactionId;
    @AuraEnabled
    public String rowKey;
  }

  public class HistoryPage {
    @AuraEnabled
    public String objectApiName;
    @AuraEnabled
    public List<HistoryRow> rows = new List<HistoryRow>();
    @AuraEnabled
    public Boolean hasMore = false;
    @AuraEnabled
    public Datetime nextCursor;
    @AuraEnabled
    public Boolean canExport = false;
  }

  /**
   * Returns one page of field-change history for the supplied record, newest
   * first. When cursor is supplied, returns rows at or before that timestamp;
   * the LWC de-duplicates the boundary overlap using HistoryRow.rowKey.
   */
  @AuraEnabled(cacheable=true)
  public static HistoryPage getHistory(Id recordId, Integer pageSize, Datetime cursor) {
    if (recordId == null) {
      throw new AuraHandledException('A record Id is required.');
    }

    Integer pageLimit = (pageSize == null || pageSize <= 0) ? DEFAULT_PAGE_SIZE : pageSize;
    if (pageLimit > MAX_PAGE_SIZE) {
      pageLimit = MAX_PAGE_SIZE;
    }
    Integer queryLimit = pageLimit + 1;

    String objectApiName = recordId.getSObjectType().getDescribe().getName();
    String recId = String.valueOf(recordId);

    HistoryPage page = new HistoryPage();
    page.objectApiName = objectApiName;
    page.canExport = canExport();

    List<FieldChangeLog__b> records;
    if (cursor == null) {
      records = [
        SELECT
          FieldApiName__c,
          FieldLabel__c,
          OldValue__c,
          NewValue__c,
          ChangeType__c,
          ChangedDateTime__c,
          Sequence__c,
          ChangedByUserId__c,
          TransactionId__c
        FROM FieldChangeLog__b
        WHERE ObjectApiName__c = :objectApiName AND RecordId__c = :recId
        LIMIT :queryLimit
      ];
    } else {
      records = [
        SELECT
          FieldApiName__c,
          FieldLabel__c,
          OldValue__c,
          NewValue__c,
          ChangeType__c,
          ChangedDateTime__c,
          Sequence__c,
          ChangedByUserId__c,
          TransactionId__c
        FROM FieldChangeLog__b
        WHERE ObjectApiName__c = :objectApiName AND RecordId__c = :recId AND ChangedDateTime__c <= :cursor
        LIMIT :queryLimit
      ];
    }

    page.hasMore = records.size() == queryLimit;
    if (page.hasMore) {
      // Drop the probe row; it belongs to the next page.
      records.remove(records.size() - 1);
    }
    if (records.isEmpty()) {
      return page;
    }

    page.rows = toHistoryRows(records);
    // Results come back in index order (ChangedDateTime DESC, Sequence ASC), but
    // we no longer rely on ORDER BY for display sorting, so derive the paging
    // cursor explicitly as the oldest timestamp in this page.
    Datetime minTs = records[0].ChangedDateTime__c;
    for (FieldChangeLog__b r : records) {
      if (r.ChangedDateTime__c != null && (minTs == null || r.ChangedDateTime__c < minTs)) {
        minTs = r.ChangedDateTime__c;
      }
    }
    page.nextCursor = minTs;
    return page;
  }

  /**
   * Maps raw Big Object rows to display rows, resolving user names and applying
   * masking. Separated from the SOQL so it is unit-testable with in-memory rows
   * (Big Object DML is not committed/queryable in test context).
   */
  @TestVisible
  private static List<HistoryRow> toHistoryRows(List<FieldChangeLog__b> records) {
    List<HistoryRow> rows = new List<HistoryRow>();
    if (records == null || records.isEmpty()) {
      return rows;
    }

    Set<String> userIds = new Set<String>();
    for (FieldChangeLog__b r : records) {
      if (String.isNotBlank(r.ChangedByUserId__c)) {
        userIds.add(r.ChangedByUserId__c);
      }
    }
    Map<String, String> userNames = resolveUserNames(userIds);

    for (FieldChangeLog__b r : records) {
      HistoryRow row = new HistoryRow();
      row.fieldApiName = r.FieldApiName__c;
      row.fieldLabel = String.isBlank(r.FieldLabel__c) ? r.FieldApiName__c : r.FieldLabel__c;
      row.oldValue = displayValue(r.OldValue__c);
      row.newValue = displayValue(r.NewValue__c);
      row.masked = isMasked(r.OldValue__c) || isMasked(r.NewValue__c);
      row.changeType = r.ChangeType__c;
      row.changedDateTime = r.ChangedDateTime__c;
      row.sequence = r.Sequence__c;
      row.changedByUserId = r.ChangedByUserId__c;
      row.changedByName = userNames.containsKey(r.ChangedByUserId__c) ? userNames.get(r.ChangedByUserId__c) : 'System';
      row.transactionId = r.TransactionId__c;
      row.rowKey =
        String.valueOf(r.ChangedDateTime__c == null ? 0 : r.ChangedDateTime__c.getTime()) +
        '|' +
        String.valueOf(r.Sequence__c) +
        '|' +
        r.FieldApiName__c;
      rows.add(row);
    }
    return rows;
  }

  @TestVisible
  private static Map<String, String> resolveUserNames(Set<String> userIds) {
    Map<String, String> names = new Map<String, String>();
    if (userIds.isEmpty()) {
      return names;
    }
    for (User u : [SELECT Id, Name FROM User WHERE Id IN :userIds]) {
      names.put(String.valueOf(u.Id), u.Name);
    }
    return names;
  }

  @TestVisible
  private static Boolean isMasked(String value) {
    return value != null && value.startsWith(MASK_PREFIX);
  }

  @TestVisible
  private static String displayValue(String value) {
    if (value == null) {
      return null;
    }
    if (value.startsWith(MASK_PREFIX)) {
      return '••••••••';
    }
    return value;
  }

  @TestVisible
  private static Boolean canExport() {
    return FeatureManagement.checkPermission('BIGOTOOL_Can_Export') ||
      FeatureManagement.checkPermission('bigotool__BIGOTOOL_Can_Export');
  }
}
