# Concern for retrying database operations that fail due to database connection issues
# Supports PostgreSQL connection and lock errors
module DatabaseRetry
  extend ActiveSupport::Concern

  # Exception types that should trigger a retry
  RETRYABLE_EXCEPTIONS = [
    defined?(PG::ConnectionBad) ? PG::ConnectionBad : nil,
    defined?(PG::UnableToSend) ? PG::UnableToSend : nil,
    ActiveRecord::ConnectionNotEstablished,
    ActiveRecord::Deadlocked
  ].compact.freeze

  # Retry database operations with exponential backoff when encountering lock/connection errors
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
        ActiveRecord::Base.connection.reconnect! if e.is_a?(ActiveRecord::ConnectionNotEstablished)
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
