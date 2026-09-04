# frozen_string_literal: true

# Whether a rescued error has left this connection sitting in a transaction
# PostgreSQL has already aborted.
#
# Zimmer is full of rescues that degrade a failed database read to a default and
# carry on: DB-less boots, the session-spawn hot path, the state-machine side
# effects that must not be able to wedge a session mid-transition. That trade is
# right when the failure is local to one statement.
#
# It is meaningless once the failed statement was inside a transaction. Postgres
# then rejects EVERY later statement on that connection with
# `PG::InFailedSqlTransaction` until rollback, so "return a default and carry on"
# cannot work — nothing downstream can succeed, and each further swallow converts
# one honest error into another misleading one. That is issue #924: a single
# failed `SELECT … FROM app_settings` was swallowed silently, and the four
# statements that ran after it each reported `InFailedSqlTransaction`, paging
# `#alerts` with nothing but consequences.
#
# So the rule these rescues follow is: degrade when this says false, re-raise
# when it says true.
module DatabaseTransactionState
  module_function

  # True when `error` came back from the Postgres server while a transaction was
  # open — the exact condition that poisons the connection.
  #
  # Deliberately narrower than `transaction_open?` alone. An open transaction is
  # not the condition; an *aborted* one is, and only an error the server actually
  # rejected a statement with aborts it. A connection that died (`PG::ConnectionBad`,
  # `ActiveRecord::NoDatabaseError`), a failure raised client-side before anything
  # was sent, and a simulated failure in a test all leave nothing to be poisoned —
  # and Rails' own test transaction means `transaction_open?` is true throughout
  # the suite, so treating it as sufficient would make the degrade path
  # untestable as well as wrong.
  #
  # Never raises: every caller is a rescue block whose whole purpose is to
  # survive a sick database.
  def aborted_by?(error)
    return false unless server_rejected_statement?(error)

    ActiveRecord::Base.connection.transaction_open?
  rescue StandardError
    false
  end

  # A `PG::Error` carrying a result is one the server answered with — it has a
  # SQLSTATE, and issuing it inside a transaction aborted that transaction. A
  # `PG::Error` with no result never reached a server that could answer.
  def server_rejected_statement?(error)
    return false unless defined?(PG::Error)

    cause = error.is_a?(PG::Error) ? error : error.cause
    cause.is_a?(PG::Error) && !cause.result.nil?
  end
end
