# frozen_string_literal: true

# Configuration for ProcessManager and related process management services.
# This initializer sets up default configuration values that can be overridden
# via environment variables.
#
# Features (Issue #326):
# - Configurable termination timeouts
# - Force-kill escalation settings
# - Logging and monitoring configuration
#
# Environment Variables:
# - PROCESS_TERM_TIMEOUT: Timeout in seconds for graceful termination (default: 30)
# - PROCESS_KILL_TIMEOUT: Timeout in seconds after SIGKILL before giving up (default: 10)
# - PROCESS_POLL_INTERVAL: Interval in seconds between process status checks (default: 0.1)
# - PROCESS_LOG_OPERATIONS: Enable detailed logging of process operations (default: true in dev)
#
Rails.application.config.process_manager = ActiveSupport::OrderedOptions.new

# Timeout settings for process termination
Rails.application.config.process_manager.term_timeout = ENV.fetch("PROCESS_TERM_TIMEOUT", 30).to_i
Rails.application.config.process_manager.kill_timeout = ENV.fetch("PROCESS_KILL_TIMEOUT", 10).to_i
Rails.application.config.process_manager.poll_interval = ENV.fetch("PROCESS_POLL_INTERVAL", 0.1).to_f

# Logging configuration
Rails.application.config.process_manager.log_operations = ActiveModel::Type::Boolean.new.cast(
  ENV.fetch("PROCESS_LOG_OPERATIONS", Rails.env.development? || Rails.env.test?)
)

# Registry cleanup configuration
Rails.application.config.process_manager.registry_cleanup_age = ENV.fetch("PROCESS_REGISTRY_CLEANUP_AGE", 3600).to_i

# Metrics configuration (for future monitoring integration)
Rails.application.config.process_manager.enable_metrics = ActiveModel::Type::Boolean.new.cast(
  ENV.fetch("PROCESS_ENABLE_METRICS", false)
)
