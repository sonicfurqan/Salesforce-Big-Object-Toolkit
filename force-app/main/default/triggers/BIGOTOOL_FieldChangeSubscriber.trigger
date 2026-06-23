/**
 * Subscriber for FieldChange__e. Persists captured changes to FieldChangeLog__b
 * after commit, decoupled from the originating DML transaction.
 */
trigger BIGOTOOL_FieldChangeSubscriber on FieldChange__e(after insert) {
  BIGOTOOL_LogWriter.write(BIGOTOOL_EventPublisher.toBigObjectRows(Trigger.new));
}
