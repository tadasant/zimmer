# frozen_string_literal: true

# Alert Service Health Check
#
# Logs a prominent warning at boot time when AlertService is not configured.
# This catches misconfiguration (missing Slack token or channel ID) immediately
# on deploy rather than discovering it after a missed alert.
#
# Does NOT block boot — just a visible log warning.

Rails.application.config.after_initialize do
  # Outside production/staging the environment allowlist drops alerts whatever the
  # configuration says (AlertService::ENABLED_ENVIRONMENTS), so here a missing token
  # is not a misconfiguration worth warning about — and a present one would not be
  # the reassurance this warning implies. Only the environments that can actually
  # alert are worth health-checking.
  next unless AlertService.alerting_enabled?

  # Skip during asset precompilation or other non-server contexts
  if defined?(Rake) && Rake.respond_to?(:application) && Rake.application.respond_to?(:top_level_tasks)
    next if Rake.application.top_level_tasks.any? { |task| task.include?("assets") }
  end

  # Only check in server or worker contexts
  next unless defined?(Rails::Server) || ENV["GOOD_JOB_EXECUTION_MODE"] == "external"

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
