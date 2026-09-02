# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"

# Unit coverage for ControllerDatabaseRetry#with_db_retry — the controller-side
# twin of DatabaseRetry, which carries the same #708 invariant: a pool-exhaustion
# error is retried, and nothing is reconnected.
class ControllerDatabaseRetryTest < ActiveSupport::TestCase
  Format = Struct.new(:json?)
  Request = Struct.new(:format)

  # Stands in for a controller: the concern only needs controller_name /
  # action_name to log, and the request/render/flash trio on the give-up path.
  # Overriding Kernel#sleep records the backoff instead of taking it.
  class Host
    include ControllerDatabaseRetry

    attr_reader :delays, :rendered, :flashes, :redirects, :request

    def initialize(json: true)
      @delays = []
      @rendered = []
      @flashes = {}
      @redirects = []
      @request = Request.new(Format.new(json))
    end

    def sleep(seconds)
      @delays << seconds
    end

    def controller_name = "sessions"
    def action_name = "index"
    def flash = @flashes
    def root_path = "/"
    def render(**options) = @rendered << options
    def redirect_back(**options) = @redirects << options
  end

  setup { @host = Host.new }

  test "a pool-exhaustion error reaches the rescue as a ConnectionNotEstablished" do
    assert_kind_of ActiveRecord::ConnectionNotEstablished,
                   ActiveRecord::ConnectionTimeoutError.new("pool is full")
    assert_includes ControllerDatabaseRetry::RETRYABLE_EXCEPTIONS,
                    ActiveRecord::ConnectionNotEstablished
  end

  test "pool exhaustion does not lease a sticky connection or reconnect" do
    ActiveRecord::Base.expects(:connection).never
    ActiveRecord::ConnectionAdapters::PostgreSQLAdapter.any_instance.expects(:reconnect!).never

    attempts = 0
    result = @host.with_db_retry do
      attempts += 1
      raise ActiveRecord::ConnectionTimeoutError,
            "could not obtain a connection from the pool within 5.000 seconds; all pooled connections were in use"
    end

    assert_equal false, result, "the give-up path should still render the friendly 503"
    assert_equal 3, attempts, "the full retry budget should be spent on the block, not inside the rescue"
    assert_equal [ 0.3, 0.6 ], @host.delays, "exponential backoff should still be applied between attempts"
    assert_equal [ :service_unavailable ], @host.rendered.map { |r| r[:status] }
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
    assert_equal [ 0.3, 0.6 ], @host.delays
    assert_empty @host.rendered
  end

  test "a genuinely broken connection is still retried" do
    # Belt and braces: PG::ConnectionBad is not a ConnectionNotEstablished, so this
    # shape never took the reconnect branch even before #708. The expectation is
    # here so the whole retryable list is covered by the same rule.
    ActiveRecord::Base.expects(:connection).never

    attempts = 0
    result = @host.with_db_retry do
      attempts += 1
      raise PG::ConnectionBad, "PQconsumeInput() server closed the connection unexpectedly" if attempts == 1

      :recovered
    end

    assert_equal :recovered, result
    assert_equal 2, attempts
    assert_equal [ 0.3 ], @host.delays
  end

  test "the HTML give-up path redirects back instead of rendering JSON" do
    host = Host.new(json: false)

    assert_equal false, host.with_db_retry { raise ActiveRecord::ConnectionTimeoutError, "pool is full" }
    assert_empty host.rendered
    assert_equal [ { fallback_location: "/" } ], host.redirects
    assert_match(/high server activity/, host.flashes[:alert])
  end

  test "a deadlock is retried without touching the connection" do
    ActiveRecord::Base.expects(:connection).never

    attempts = 0
    result = @host.with_db_retry do
      attempts += 1
      raise ActiveRecord::Deadlocked, "deadlock detected" if attempts == 1

      :ok
    end

    assert_equal :ok, result
    assert_equal 2, attempts
    assert_equal [ 0.3 ], @host.delays
  end

  test "max_attempts and base_delay overrides drive the budget and the backoff" do
    assert_equal false,
                 @host.with_db_retry(max_attempts: 4, base_delay: 0.1) {
                   raise ActiveRecord::ConnectionTimeoutError, "all pooled connections were in use"
                 }

    assert_equal [ 0.1, 0.2, 0.4 ], @host.delays
    assert_equal [ :service_unavailable ], @host.rendered.map { |r| r[:status] }
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
