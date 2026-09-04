# frozen_string_literal: true

# Whether the connection an error came from is sitting in a transaction
# PostgreSQL has aborted.
#
# Zimmer is full of rescues that degrade a failed database read to a default and
# carry on: DB-less boots, the session-spawn hot path, the state-machine side
# effects that must not be able to wedge a session mid-transition. That trade is
# right when the failure is local to one statement.
#
# It is meaningless once the failure aborted the transaction it ran in. Postgres
# then rejects EVERY later statement on that connection with
# `PG::InFailedSqlTransaction` until rollback, and the transaction cannot commit
# — an outermost one turns its `COMMIT` into a rollback, a savepoint fails on
# `RELEASE`. So "return a default and carry on" reaches nowhere: nothing
# downstream can succeed, and each further swallow converts one honest error into
# another misleading one. That is issue #924, where a single failed
# `SELECT … FROM app_settings` was swallowed silently and the four statements
# after it each reported `InFailedSqlTransaction`, paging `#alerts` with nothing
# but consequences.
#
# So the rule these rescues follow is: degrade when this says false, re-raise
# when it says true.
module DatabaseTransactionState
  module_function

  # Ask libpq, rather than infer from the error.
  #
  # `PQTRANS_INERROR` is Postgres' own answer to the only question that matters
  # here — "is this connection in a failed transaction block" — and it is exact
  # where every proxy for it is not:
  #
  #   * `transaction_open?` is true for a healthy transaction, and true for the
  #     one Rails wraps around every test in the suite.
  #   * "the error carries a PG result" is true of a `RecordNotUnique` a
  #     `requires_new:` savepoint has already absorbed (`Session#assign_slug`,
  #     `GateDecisions::Record`), where the connection is fine.
  #   * ...and false when a wrapper exception puts the PG error two `cause` links
  #     down, where the connection is not.
  #
  # The pool comes off the error so the answer describes the connection that
  # actually failed: Zimmer runs a second database for Action Cable, and the
  # primary's transaction state says nothing about a statement that failed on the
  # cable pool.
  #
  # Never raises: every caller is a rescue block whose whole purpose is to
  # survive a sick database.
  def aborted_by?(error)
    pool = error.try(:connection_pool) || ActiveRecord::Base.connection_pool
    return false unless pool.active_connection?

    pool.lease_connection.raw_connection.transaction_status == PG::PQTRANS_INERROR
  rescue StandardError
    false
  end
end
