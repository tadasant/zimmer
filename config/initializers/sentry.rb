# Sentry SDK pointed at the self-hosted GlitchTip instance
# (https://glitchtip.obs.tadasant.com). GlitchTip is Sentry-API compatible,
# so the official sentry-ruby/sentry-rails SDKs work as-is.
#
# This initializer is a hard no-op when SENTRY_DSN_BACKEND is unset, which keeps
# development and test quiet without any extra config. Production and staging
# set the DSN via Kamal secrets (.kamal/secrets.* + the `env > secret` list in
# config/deploy.*.yml) — AO deploys via Kamal, not Hatchbox.
#
# Modeled on web-app/config/initializers/sentry.rb. AO uses its own GlitchTip
# project (separate DSN from the web-app) so AO errors are isolated and
# independently alertable.
if ENV["SENTRY_DSN_BACKEND"].present?
  Sentry.init do |config|
    config.dsn = ENV["SENTRY_DSN_BACKEND"]
    config.environment = Rails.env

    config.breadcrumbs_logger = [ :active_support_logger, :http_logger ]

    # Tracing/performance is a later phase — keep it off so we only ship errors.
    config.traces_sample_rate = 0.0

    # Don't send IPs, cookies, request bodies, or user objects unless we
    # explicitly opt in later.
    config.send_default_pii = false

    # AO's failure surfaces are background jobs and the session-lifecycle
    # subsystem, not HTTP requests. The sentry-rails ActiveJob integration
    # captures terminal job failures automatically (AgentSessionJob re-raises at
    # its top-level rescue), and deliberate "log but don't fail" swallow-rescues
    # are surfaced explicitly via ErrorReporter / StructuredLogger#error.

    # Filter bot traffic, malformed requests, and intentional timeouts so they
    # don't drown out real failures.
    config.excluded_exceptions += [
      "Errno::EIO",
      "Rack::QueryParser::InvalidParameterError",
      "ActionController::BadRequest",
      "ActionDispatch::Http::Parameters::ParseError",
      "Rack::Timeout::RequestTimeoutError"
    ]
  end
end
