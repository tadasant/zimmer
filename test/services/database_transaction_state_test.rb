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

  test "an error the server rejected a statement with, inside a transaction, is an aborted one" do
    # The #924 condition exactly: from here on Postgres answers every statement
    # on this connection with InFailedSqlTransaction, so no caller can degrade to
    # a default and expect to get anywhere.
    ActiveRecord::Base.transaction(requires_new: true) do
      error = poison_transaction

      assert DatabaseTransactionState.aborted_by?(error)

      raise ActiveRecord::Rollback
    end
  end

  test "the same error outside a transaction is not an aborted one" do
    # A statement that failed on its own poisons nothing — this is the case the
    # degrade-to-a-default rescues were written for, and it must keep working.
    # Rails holds a transaction open around every test in the suite, so the only
    # honest way to ask about a connection with none on it is to say so.
    error = nil
    ActiveRecord::Base.transaction(requires_new: true) do
      error = poison_transaction
      raise ActiveRecord::Rollback
    end

    ActiveRecord::Base.connection.stubs(:transaction_open?).returns(false)

    refute DatabaseTransactionState.aborted_by?(error)
  end

  test "an error that never reached the server is not an aborted one" do
    # Two shapes that matter. A raised-by-hand StatementInvalid — every stubbed
    # database failure in this suite — has no PG cause at all; a dead connection
    # has a PG cause carrying no result, because no server answered it. Neither
    # leaves a transaction to poison, which is why the predicate reads the error
    # rather than settling for `transaction_open?`.
    hand_raised = begin
      raise ActiveRecord::StatementInvalid, "simulated"
    rescue ActiveRecord::StatementInvalid => e
      e
    end

    connection_died = begin
      begin
        raise PG::UnableToSend, "server closed the connection unexpectedly"
      rescue PG::Error
        raise ActiveRecord::StatementInvalid, "connection lost"
      end
    rescue ActiveRecord::StatementInvalid => e
      e
    end

    ActiveRecord::Base.transaction(requires_new: true) do
      assert ActiveRecord::Base.connection.transaction_open?

      refute DatabaseTransactionState.aborted_by?(hand_raised)
      refute DatabaseTransactionState.aborted_by?(connection_died)

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

    DatabaseTransactionState.stubs(:server_rejected_statement?).returns(true)
    ActiveRecord::Base.stubs(:connection).raises(ActiveRecord::ConnectionNotEstablished, "pool is gone")

    assert_nothing_raised do
      refute DatabaseTransactionState.aborted_by?(ActiveRecord::StatementInvalid.new("boom"))
    end
  end
end
