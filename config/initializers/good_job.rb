# Configure GoodJob
Rails.application.config.to_prepare do
  # Log configuration at startup
  Rails.logger.info "GoodJob configured"

  # Get connection pool info for database configurations
  begin
    db_config = ActiveRecord::Base.connection_db_config.configuration_hash

    # Log details about connection pool
    Rails.logger.info "Database connection: pool=#{db_config[:pool]}"

  rescue => e
    Rails.logger.error "Error logging database configurations: #{e.message}"
  end

  # Configure GoodJob error handling - log errors but don't crash
  GoodJob.on_thread_error = ->(exception) do
    Rails.logger.error "GoodJob thread error: #{exception.message}"
    Rails.logger.error exception.backtrace.join("\n") if exception.backtrace
    Rails.error.report(exception, handled: true, severity: :error)
  end
end
