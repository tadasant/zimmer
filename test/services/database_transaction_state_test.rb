# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"

class DatabaseTransactionStateTest < ActiveSupport::TestCase
  # Poison the current transaction the way production does: issue a statement the
  # server rejects. Returns the error, with the transaction left aborted.
  def poison_transaction
    ActiveRecord::Base.connection.execute("SELECT no_such_column_anywhere")
    flunk "expected the statement to be rejected"
  rescue ActiveRecord::StatementInvalid => e
    e
  end

  test "a statement the server rejected inside a transaction leaves it aborted" do
    # The #924 condition exactly: from here on Postgres answers every statement
    # on this connection with InFailedSqlTransaction, and the transaction cannot
    # commit — so no caller can degrade to a default and expect to get anywhere.
    ActiveRecord::Base.transaction(requires_new: true) do
      error = poison_transaction

      assert DatabaseTransactionState.aborted_by?(error)

      raise ActiveRecord::Rollback
    end
  end

  test "the same failure absorbed by a savepoint leaves nothing aborted" do
    # The case that makes `transaction_open?`, and "the error carries a PG
    # result", both wrong answers. Session#assign_slug and GateDecisions::Record
    # deliberately absorb a server-rejected write in a `requires_new:` block; once
    # the savepoint unwinds the connection is healthy and the enclosing
    # transaction is still open, so degrading to a default is correct.
    ActiveRecord::Base.transaction(requires_new: true) do
      error = begin
        ActiveRecord::Base.transaction(requires_new: true) { poison_transaction.tap { |e| raise e } }
      rescue ActiveRecord::StatementInvalid => e
        e
      end

      assert ActiveRecord::Base.connection.transaction_open?,
        "the enclosing transaction is still open — which is why transaction_open? cannot be the predicate"
      refute DatabaseTransactionState.aborted_by?(error)

      raise ActiveRecord::Rollback
    end
  end

  test "an error that never reached the server leaves nothing aborted" do
    # Every stubbed database failure in this suite is this shape, and Rails holds
    # a transaction open around every test — so an inference from the error object
    # would have to get this right to keep the degrade path testable at all.
    hand_raised = begin
      raise ActiveRecord::StatementInvalid, "simulated"
    rescue ActiveRecord::StatementInvalid => e
      e
    end

    ActiveRecord::Base.transaction(requires_new: true) do
      assert ActiveRecord::Base.connection.transaction_open?

      refute DatabaseTransactionState.aborted_by?(hand_raised)

      raise ActiveRecord::Rollback
    end
  end

  test "a poisoned connection is still recognised through a wrapper exception" do
    # The predicate reads the connection, not the error's `cause` chain, so an
    # error re-raised inside a wrapper — which puts the PG error two links down —
    # is judged on the same evidence as the original.
    ActiveRecord::Base.transaction(requires_new: true) do
      wrapped = begin
        begin
          poison_transaction.tap { |e| raise e }
        rescue ActiveRecord::StatementInvalid
          raise RuntimeError, "wrapped"
        end
      rescue RuntimeError => e
        e
      end

      assert_kind_of ActiveRecord::StatementInvalid, wrapped.cause
      assert DatabaseTransactionState.aborted_by?(wrapped)

      raise ActiveRecord::Rollback
    end
  end

  test "the predicate answers for the pool the error came from" do
    # Zimmer runs a second database for Action Cable. A statement that failed on
    # another pool says nothing about this one's transaction state, and the
    # primary's state says nothing about it.
    other_pool = mock("connection_pool")
    other_pool.stubs(:active_connection?).returns(false)
    error = ActiveRecord::StatementInvalid.new("boom")
    error.stubs(:connection_pool).returns(other_pool)

    ActiveRecord::Base.transaction(requires_new: true) do
      poison_transaction

      refute DatabaseTransactionState.aborted_by?(error),
        "the primary pool is poisoned, but the error did not come from it"

      raise ActiveRecord::Rollback
    end
  end

  test "the predicate never raises, whatever it is handed" do
    # Every caller is a rescue block whose job is to survive a sick database. A
    # predicate that can raise there would become a new way for one to fail.
    assert_nothing_raised do
      refute DatabaseTransactionState.aborted_by?(RuntimeError.new("nothing to do with the database"))
      refute DatabaseTransactionState.aborted_by?(ActiveRecord::NoDatabaseError.new("no database"))
    end

    ActiveRecord::Base.stubs(:connection_pool).raises(ActiveRecord::ConnectionNotEstablished, "pool is gone")

    assert_nothing_raised do
      refute DatabaseTransactionState.aborted_by?(ActiveRecord::StatementInvalid.new("boom"))
    end
  end
end
