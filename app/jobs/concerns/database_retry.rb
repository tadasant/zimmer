# Concern for retrying database operations that fail due to database connection issues
# Supports PostgreSQL connection and lock errors
module DatabaseRetry
  extend ActiveSupport::Concern

  # Exception types that should trigger a retry.
  #
  # `ActiveRecord::ConnectionFailed` is the shape a connection that dies *while a
  # statement is in flight* takes — a Postgres restart, a managed-cluster failover,
  # an admin disconnect. It is a sibling of `ConnectionNotEstablished`, not a
  # descendant (`ConnectionFailed < QueryAborted < StatementInvalid`), so it has to
  # be named explicitly. Name that class and not its parent: `QueryAborted` also
  # covers `StatementTimeout`, `QueryCanceled` and `AdapterTimeout`, which say the
  # database is alive and the query was too slow. Those must keep propagating —
  # `ApplicationJob` already has `retry_on ActiveRecord::StatementTimeout`, and
  # swallowing them here would spend three more timeouts in-process before it ever
  # saw one. See #779.
  #
  # Kept identical to `ControllerDatabaseRetry::RETRYABLE_EXCEPTIONS`; a test
  # asserts the two lists stay equal.
  RETRYABLE_EXCEPTIONS = [
    defined?(PG::ConnectionBad) ? PG::ConnectionBad : nil,
    defined?(PG::UnableToSend) ? PG::UnableToSend : nil,
    ActiveRecord::ConnectionNotEstablished,
    ActiveRecord::ConnectionFailed,
    ActiveRecord::Deadlocked
  ].compact.freeze

  # Retry database operations with exponential backoff when encountering lock/connection errors
  #
  # Recovery is Active Record's job, not ours: the adapter verifies a connection it
  # is not confident about and reconnects it on the thread that owns it
  # (`with_raw_connection` → `verify!` → `reconnect!`), so re-running the block is
  # all this helper has to do.
  #
  # Reconnecting by hand would be actively harmful. `ActiveRecord::ConnectionTimeoutError`
  # (the pool is full) inherits from `ActiveRecord::ConnectionNotEstablished` (this
  # connection is broken), so a reconnect keyed on the parent class fires on
  # exhaustion: `ActiveRecord::Base.connection` leases a *sticky* connection out of
  # an already empty pool, and on a GoodJob thread it tears down the Postgres
  # session holding that job's advisory lock. See #708.
  #
  # @param max_attempts [Integer] Maximum number of retry attempts (default: 3)
  # @param base_delay [Float] Base delay in seconds for exponential backoff (default: 0.5)
  # @yield The database operation to retry
  # @raise The original exception if all retry attempts are exhausted
  def with_db_retry(max_attempts: 3, base_delay: 0.5)
    attempts = 0
    begin
      attempts += 1
      yield
    rescue *RETRYABLE_EXCEPTIONS => e
      if attempts < max_attempts
        delay = base_delay * (2 ** (attempts - 1)) # Exponential backoff: 0.5s, 1s, 2s
        Rails.logger.warn "Database error, retrying in #{delay}s (attempt #{attempts}/#{max_attempts}) - #{e.message}"
        sleep delay
        retry
      else
        Rails.logger.error "Database error after #{max_attempts} attempts, giving up - #{e.message}"
        raise
      end
    end
  end

  # Helper to create a log with retry logic
  # This is a convenience method for the common pattern of creating logs
  #
  # @param session [Session] The session to create the log for
  # @param content [String] The log content
  # @param level [String] The log level (default: "info")
  def create_log_with_retry(session, content, level: "info")
    with_db_retry do
      session.logs.create!(content: content, level: level)
    end
  end
end
