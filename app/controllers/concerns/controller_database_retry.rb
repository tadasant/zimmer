# frozen_string_literal: true

# Provides database retry logic for controller actions to handle PostgreSQL connection issues
module ControllerDatabaseRetry
  extend ActiveSupport::Concern

  # Exception types that should trigger a retry
  RETRYABLE_EXCEPTIONS = [
    defined?(PG::ConnectionBad) ? PG::ConnectionBad : nil,
    defined?(PG::UnableToSend) ? PG::UnableToSend : nil,
    ActiveRecord::ConnectionNotEstablished,
    ActiveRecord::Deadlocked
  ].compact.freeze

  # Retry database operations with exponential backoff
  # Lower max_attempts than jobs since users are waiting for HTTP response
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
        ActiveRecord::Base.connection.reconnect! if e.is_a?(ActiveRecord::ConnectionNotEstablished)
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
