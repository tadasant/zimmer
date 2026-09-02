# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"

# Unit coverage for DatabaseRetry#with_db_retry.
#
# The behaviour under test is #708: a pool-exhaustion error must be retried
# without reconnecting anything. `ActiveRecord::ConnectionTimeoutError` inherits
# from `ActiveRecord::ConnectionNotEstablished`, so the old
# `ActiveRecord::Base.connection.reconnect! if e.is_a?(ConnectionNotEstablished)`
# fired on "the pool is full" — leasing a *sticky* connection out of an already
# empty pool, blocking for another checkout_timeout, and raising from inside the
# rescue so the remaining retries never ran.
class DatabaseRetryTest < ActiveSupport::TestCase
  # Minimal host exercising the concern in isolation, mirroring how
  # AgentSessionJob / LogBuffer include it. Overriding Kernel#sleep records the
  # backoff schedule instead of taking it, so the retry budget can be asserted
  # without the example paying 1.5s.
  class Host
    include DatabaseRetry

    attr_reader :delays

    def initialize
      @delays = []
    end

    def sleep(seconds)
      @delays << seconds
    end
  end

  setup { @host = Host.new }

  test "ConnectionTimeoutError is what ConnectionNotEstablished used to catch" do
    # The premise of the fix, asserted against the Active Record actually pinned
    # in Gemfile.lock rather than taken on trust.
    assert_kind_of ActiveRecord::ConnectionNotEstablished,
                   ActiveRecord::ConnectionTimeoutError.new("pool is full")
    assert_includes DatabaseRetry::RETRYABLE_EXCEPTIONS, ActiveRecord::ConnectionNotEstablished
  end

  test "pool exhaustion does not lease a sticky connection or reconnect" do
    # ActiveRecord::Base.connection is lease_connection — the sticky checkout the
    # helper must not make while the pool is exhausted.
    ActiveRecord::Base.expects(:connection).never
    ActiveRecord::ConnectionAdapters::PostgreSQLAdapter.any_instance.expects(:reconnect!).never

    attempts = 0
    assert_raises(ActiveRecord::ConnectionTimeoutError) do
      @host.with_db_retry do
        attempts += 1
        raise ActiveRecord::ConnectionTimeoutError,
              "could not obtain a connection from the pool within 5.000 seconds; all pooled connections were in use"
      end
    end

    assert_equal 3, attempts, "the full retry budget should be spent on the block, not inside the rescue"
    assert_equal [ 0.5, 1.0 ], @host.delays, "exponential backoff should still be applied between attempts"
  end

  test "pool exhaustion that clears is recovered by retrying alone" do
    attempts = 0
    result = @host.with_db_retry do
      attempts += 1
      raise ActiveRecord::ConnectionTimeoutError, "all pooled connections were in use" if attempts < 3

      :ok
    end

    assert_equal :ok, result
    assert_equal 3, attempts
    assert_equal [ 0.5, 1.0 ], @host.delays
  end

  test "a genuinely broken connection is still retried" do
    ActiveRecord::Base.expects(:connection).never

    attempts = 0
    result = @host.with_db_retry do
      attempts += 1
      raise PG::ConnectionBad, "PQconsumeInput() server closed the connection unexpectedly" if attempts == 1

      :recovered
    end

    assert_equal :recovered, result
    assert_equal 2, attempts
    assert_equal [ 0.5 ], @host.delays
  end

  test "Active Record heals a genuinely dead connection with no manual reconnect" do
    # The risk this fix takes on: dropping the manual reconnect! must not quietly
    # regress recovery from a genuinely lost connection. Prove it against a real
    # Postgres session, in a pool of this test's own, with
    # ActiveRecord::Base.connection forbidden — so any recovery observed here can
    # only have come from the adapter itself (with_raw_connection -> verify! ->
    # reconnect!), which is the guarantee that lets with_db_retry just retry.
    #
    # The adapter is built standalone rather than through a pool: the suite's
    # transactional fixtures pin every pool that gets established during a test,
    # and a pinned connection is deliberately unrecoverable.
    adapter = ActiveRecord::ConnectionAdapters::PostgreSQLAdapter.new(
      ActiveRecord::Base.connection_db_config.configuration_hash
    )

    begin
      pid = adapter.select_value("SELECT pg_backend_pid()")

      # Terminate that backend from another session, the way a Postgres restart or
      # an admin disconnect does: the client-side handle survives, the server-side
      # session does not.
      ActiveRecord::Base.connection_pool.with_connection do |c|
        c.select_value("SELECT pg_terminate_backend(#{pid.to_i})")
      end

      ActiveRecord::Base.expects(:connection).never

      # The statement that discovers the dead session still fails...
      assert_raises(ActiveRecord::ConnectionFailed) { adapter.select_value("SELECT 1") }

      # ...and the adapter has reconnected itself by the next one.
      assert_equal 1, adapter.select_value("SELECT 1").to_i
    ensure
      adapter.disconnect!
    end
  end

  test "a non-retryable error is not retried" do
    attempts = 0
    assert_raises(ArgumentError) do
      @host.with_db_retry do
        attempts += 1
        raise ArgumentError, "not a connection problem"
      end
    end

    assert_equal 1, attempts
    assert_empty @host.delays
  end
end
