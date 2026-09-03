# frozen_string_literal: true

# Provides database retry logic for controller actions to handle PostgreSQL connection issues
module ControllerDatabaseRetry
  extend ActiveSupport::Concern

  # Exception types that should trigger a retry.
  #
  # `ActiveRecord::ConnectionFailed` is a connection that died mid-statement — the
  # common shape of a Postgres restart or failover, and a sibling of
  # `ConnectionNotEstablished` rather than a descendant, so it has to be named.
  # Name it and not its parent `QueryAborted`, which also covers
  # `StatementTimeout`, `QueryCanceled` and `AdapterTimeout`: this helper's give-up
  # path *renders* rather than re-raises, so a timeout on the list would become a
  # friendly 503 the caller never learns the real reason for. See #779.
  #
  # Kept identical to `DatabaseRetry::RETRYABLE_EXCEPTIONS`; a test asserts the two
  # lists stay equal.
  RETRYABLE_EXCEPTIONS = [
    defined?(PG::ConnectionBad) ? PG::ConnectionBad : nil,
    defined?(PG::UnableToSend) ? PG::UnableToSend : nil,
    ActiveRecord::ConnectionNotEstablished,
    ActiveRecord::ConnectionFailed,
    ActiveRecord::Deadlocked
  ].compact.freeze

  # Retry database operations with exponential backoff
  # Lower max_attempts than jobs since users are waiting for HTTP response
  #
  # Recovery is Active Record's job, not ours: the adapter verifies a connection it
  # is not confident about and reconnects it on the thread that owns it, so
  # re-running the block is all this helper has to do. A reconnect by hand keyed on
  # `ActiveRecord::ConnectionNotEstablished` also fires on
  # `ActiveRecord::ConnectionTimeoutError`, which inherits from it but means the
  # pool is full rather than that this connection is broken — leasing a sticky
  # connection out of an already empty pool. See #708.
  #
  # @param max_attempts [Integer] Maximum number of retry attempts (default: 3)
  # @param base_delay [Float] Base delay in seconds for exponential backoff (default: 0.3)
  # @yield The block containing database operations to retry
  # @return [Object, false] Returns the block's result on success, or false if max retries exceeded
  def with_db_retry(max_attempts: 3, base_delay: 0.3)
    attempts = 0
    begin
      attempts += 1
      yield  # Return the block's result
    rescue *RETRYABLE_EXCEPTIONS => e
      if attempts < max_attempts
        delay = base_delay * (2 ** (attempts - 1)) # Exponential backoff: 0.3s, 0.6s, 1.2s (with spaces)
        Rails.logger.warn "[#{controller_name}##{action_name}] Database error, retrying in #{delay}s (attempt #{attempts}/#{max_attempts})"
        sleep delay
        retry
      else
        Rails.logger.error "[#{controller_name}##{action_name}] Database error after #{max_attempts} attempts - #{e.message}"
        # Return user-friendly error instead of 500
        if request.format.json?
          render json: { error: "The operation couldn't be completed due to high server activity. Please try again." }, status: :service_unavailable
        else
          flash[:alert] = "The operation couldn't be completed due to high server activity. Please try again."
          redirect_back(fallback_location: root_path)
        end
        false  # Return false to indicate failure
      end
    end
  end
end
