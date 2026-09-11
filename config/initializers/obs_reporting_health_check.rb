# frozen_string_literal: true

# Boot-time check on the two halves of Zimmer's alerting path.
#
# Both halves are hard no-ops on a missing environment variable, on purpose —
# `config/initializers/sentry.rb` does nothing without `SENTRY_DSN_BACKEND`, and
# `config/initializers/otel_logs_exporter.rb` does nothing without
# `OTEL_LOGS_EXPORTER_ENDPOINT` — which is right for a laptop and for CI, and
# indistinguishable from a healthy deployment on a droplet. A typo'd secret in a
# deployed environment would otherwise boot clean, serve traffic, and drop every
# page with nothing anywhere saying so.
#
# So: in the environments that page (see sentry.rb's `enabled_environments`), say
# at boot which half is unconfigured. Does NOT block boot — a deployment that has
# deliberately not wired the obs stack still runs, it just runs without alerting,
# and this is the line that tells you so. The log record reaches the container log
# and, once the exporter is configured, the obs stack; there is no shell on the
# production box to read stdout with, which is why the level is WARN rather than
# INFO (see docs/operate/observability.md).
Rails.application.config.after_initialize do
  next if Rails.env.test?

  # Skip during asset precompilation or other non-server contexts.
  if defined?(Rake) && Rake.respond_to?(:application) && Rake.application.respond_to?(:top_level_tasks)
    next if Rake.application.top_level_tasks.any? { |task| task.include?("assets") }
  end

  # Only in server or worker contexts.
  next unless defined?(Rails::Server) || ENV["GOOD_JOB_EXECUTION_MODE"] == "external"

  # The environments that page. Anything else is quiet by design, not by fault —
  # say which, so the two are never confused.
  unless ErrorReporter::ALERTING_ENVIRONMENTS.include?(Rails.env.to_s)
    Rails.logger.info(
      "[ObsReportingHealthCheck] Alerting is off in #{Rails.env} — errors are logged, not reported. " \
      "Only #{ErrorReporter::ALERTING_ENVIRONMENTS.join(' and ')} page."
    )
    next
  end

  missing = []
  missing << "SENTRY_DSN_BACKEND (no GlitchTip events)" if ENV["SENTRY_DSN_BACKEND"].blank?
  missing << "OTEL_LOGS_EXPORTER_ENDPOINT (no ERROR records shipped, so nothing pages)" if ENV["OTEL_LOGS_EXPORTER_ENDPOINT"].blank?

  if missing.any?
    Rails.logger.warn(
      "[ObsReportingHealthCheck] Alerting is NOT fully configured in #{Rails.env} — alerts will be " \
      "silently dropped. Missing: #{missing.join(', ')}. See docs/operate/observability.md."
    )
  else
    Rails.logger.info("[ObsReportingHealthCheck] Alerting is configured in #{Rails.env}.")
  end
rescue => e
  Rails.logger.warn("[ObsReportingHealthCheck] Health check failed: #{e.message}")
end
