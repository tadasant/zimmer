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

  unless AlertService.configured?
    details = AlertService.missing_configuration_details

    Rails.logger.warn(
      "[AlertServiceHealthCheck] AlertService is NOT configured — alerts will be silently dropped. " \
      "Issues: #{details.join(', ')}. " \
      "Add missing values to Rails credentials (config/credentials/#{Rails.env}.yml.enc) or environment variables."
    )
  end

  # Even when fully configured, alerting only dispatches under RAILS_ENV=production
  # (AlertService::ALERTING_ENVIRONMENTS). A non-production instance inherits
  # production's Slack token + channel ID, so configured? is true there too — note
  # the deliberate silence so a quiet #eng-alerts in staging isn't mistaken for a
  # misconfiguration.
  if AlertService.configured? && !AlertService.alerting_environment?
    Rails.logger.info(
      "[AlertServiceHealthCheck] AlertService is configured but alerting is environment-gated off " \
      "in #{Rails.env} (dispatches under production only) — operational alerts are intentionally not sent."
    )
  end
rescue => e
  Rails.logger.warn("[AlertServiceHealthCheck] Health check failed: #{e.message}")
end
