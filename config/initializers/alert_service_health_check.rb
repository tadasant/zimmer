# frozen_string_literal: true

# Alert Service Health Check
#
# Logs a prominent warning at boot time when AlertService is not configured.
# This catches misconfiguration (missing Slack token or channel ID) immediately
# on deploy rather than discovering it after a missed alert.
#
# Does NOT block boot — just a visible log warning.

Rails.application.config.after_initialize do
  next if Rails.env.test?

  # Skip during asset precompilation or other non-server contexts
  if defined?(Rake) && Rake.respond_to?(:application) && Rake.application.respond_to?(:top_level_tasks)
    next if Rake.application.top_level_tasks.any? { |task| task.include?("assets") }
  end

  # Only check in server or worker contexts
  next unless defined?(Rails::Server) || ENV["GOOD_JOB_EXECUTION_MODE"] == "external"

  # An instance that isn't allowed to page the alert channel has no alert
  # configuration to be wrong about — the environment gate, not a missing
  # credential, is why it stays quiet. Say which, so the two are never confused.
  unless AlertService.enabled?
    Rails.logger.info(
      "[AlertServiceHealthCheck] Alerting is disabled in #{Rails.env} — alerts are logged, not posted. " \
      "Set #{AlertService::ALERTS_ENABLED_ENV_VAR}=true to page from this instance."
    )
    next
  end

  unless AlertService.configured?
    details = AlertService.missing_configuration_details

    Rails.logger.warn(
      "[AlertServiceHealthCheck] AlertService is NOT configured — alerts will be silently dropped. " \
      "Issues: #{details.join(', ')}. " \
      "Add missing values to Rails credentials (config/credentials/#{Rails.env}.yml.enc) or environment variables."
    )
  end
rescue => e
  Rails.logger.warn("[AlertServiceHealthCheck] Health check failed: #{e.message}")
end
