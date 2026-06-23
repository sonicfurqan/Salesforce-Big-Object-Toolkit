/**
 * Diffs trigger old/new maps against the tracked-field configuration and
 * produces FieldChangeLog__b rows for the changed values. Pure/transform logic
 * only — performs no DML or event publishing — so it is fully unit testable.
 */
public with sharing class BIGOTOOL_Differ {
  private static final Integer LONG_TEXT_MAX = 32768;
  private static final Integer LABEL_MAX = 80;

  public static List<FieldChangeLog__b> diff(
    String objName,
    System.TriggerOperation op,
    Map<Id, SObject> oldMap,
    Map<Id, SObject> newMap
  ) {
    List<FieldChangeLog__b> result = new List<FieldChangeLog__b>();
    BIGOTOOL_ConfigRepo.ObjectConfig oc = BIGOTOOL_ConfigRepo.forObject(objName);
    if (oc == null || oc.config == null || oc.fields.isEmpty()) {
      return result;
    }
    Field_Log_Config__c cfg = oc.config;

    String changeType;
    Map<Id, SObject> primary;
    Boolean isCreate = false;
    Boolean isDelete = false;
    Boolean isUpdate = false;

    switch on op {
      when AFTER_INSERT {
        if (cfg.Log_On_Create__c != true) {
          return result;
        }
        changeType = 'Create';
        primary = newMap;
        isCreate = true;
      }
      when AFTER_UPDATE {
        if (cfg.Log_On_Update__c != true) {
          return result;
        }
        changeType = 'Update';
        primary = newMap;
        isUpdate = true;
      }
      when AFTER_DELETE {
        if (cfg.Log_On_Delete__c != true) {
          return result;
        }
        changeType = 'Delete';
        primary = oldMap;
        isDelete = true;
      }
      when AFTER_UNDELETE {
        if (cfg.Log_On_Undelete__c != true) {
          return result;
        }
        changeType = 'Undelete';
        primary = newMap;
        isCreate = true;
      }
      when else {
        return result;
      }
    }

    if (primary == null || primary.isEmpty()) {
      return result;
    }

    Datetime occurredAt = Datetime.now();
    Id userId = UserInfo.getUserId();
    String txnId = Request.getCurrent().getRequestId();
    Integer seq = 0;

    for (Id recId : primary.keySet()) {
      SObject newRec = (newMap != null) ? newMap.get(recId) : null;
      SObject oldRec = (oldMap != null) ? oldMap.get(recId) : null;

      for (Field_Log_Field__c f : oc.fields) {
        String api = f.Field_Api_Name__c;
        if (String.isBlank(api)) {
          continue;
        }
        Object newVal = (newRec != null) ? safeGet(newRec, api) : null;
        Object oldVal = (oldRec != null) ? safeGet(oldRec, api) : null;

        if (isUpdate && valuesEqual(oldVal, newVal)) {
          continue;
        }
        if (isCreate && newVal == null) {
          continue;
        }
        if (isDelete && oldVal == null) {
          continue;
        }

        FieldChangeLog__b row = new FieldChangeLog__b();
        row.ObjectApiName__c = objName;
        row.RecordId__c = recId;
        row.FieldApiName__c = api;
        row.FieldLabel__c = truncate(f.Field_Label__c, LABEL_MAX);
        row.OldValue__c = render(oldVal, f.Mask_Value__c);
        row.NewValue__c = render(newVal, f.Mask_Value__c);
        row.ChangeType__c = changeType;
        row.ChangedDateTime__c = occurredAt;
        row.ChangedByUserId__c = userId;
        row.TransactionId__c = truncate(txnId, 36);
        row.Sequence__c = seq++;
        result.add(row);
      }
    }
    return result;
  }

  private static Object safeGet(SObject rec, String field) {
    try {
      return rec.get(field);
    } catch (Exception e) {
      return null;
    }
  }

  @TestVisible
  private static Boolean valuesEqual(Object a, Object b) {
    if (a == null && b == null) {
      return true;
    }
    if (a == null || b == null) {
      return false;
    }
    return String.valueOf(a) == String.valueOf(b);
  }

  @TestVisible
  private static String render(Object val, Boolean mask) {
    if (val == null) {
      return null;
    }
    String s = String.valueOf(val);
    if (mask == true) {
      Blob digest = Crypto.generateDigest('SHA-256', Blob.valueOf(s));
      return 'MASKED:' + EncodingUtil.convertToHex(digest);
    }
    return truncate(s, LONG_TEXT_MAX);
  }

  private static String truncate(String s, Integer max) {
    if (s == null) {
      return null;
    }
    return s.length() > max ? s.substring(0, max) : s;
  }
}
