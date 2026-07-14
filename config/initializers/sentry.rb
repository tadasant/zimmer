# Sentry SDK pointed at the self-hosted GlitchTip instance
# (https://glitchtip.obs.tadasant.com). GlitchTip is Sentry-API compatible,
# so the official sentry-ruby/sentry-rails SDKs work as-is.
#
# Two gates, and both are load-bearing:
#
# 1. SENTRY_DSN_BACKEND must be present. On a machine that never sets it (a laptop,
#    a plain CI runner), this initializer is a hard no-op and nothing else here
#    matters. In production/staging, set SENTRY_DSN_BACKEND as an environment
#    variable (Zimmer deploys via the DigitalOcean + Tailscale GitHub Actions
#    workflow and docker compose; the deploy passes it through Terraform when the
#    secret is present). Point it at your own GlitchTip project so Zimmer's errors
#    are isolated and independently alertable.
#
# 2. Rails.env must be production or staging (enabled_environments below). The DSN
#    check alone does NOT keep test and development quiet, because Zimmer runs its
#    agent sessions *inside the production container*: every agent-session shell
#    inherits production's SENTRY_DSN_BACKEND, so a `RAILS_ENV=test bin/rails`
#    command in an agent's repo clone would otherwise initialize the SDK against
#    the production DSN and page the production Slack alert channel with a test-env
#    exception. That is not hypothetical — it happened (issue #176). The
#    environment allowlist is what actually holds, because it holds even when the
#    production DSN genuinely is present in the environment.
if ENV["SENTRY_DSN_BACKEND"].present?
  Sentry.init do |config|
    config.dsn = ENV["SENTRY_DSN_BACKEND"]
    config.environment = Rails.env

    # Only these environments may send. Any other Rails.env (test, development,
    # or an ad-hoc one) drops events at the client, DSN present or not.
    config.enabled_environments = %w[production staging]

    config.breadcrumbs_logger = [ :active_support_logger, :http_logger ]

    # Tracing/performance is a later phase — keep it off so we only ship errors.
    config.traces_sample_rate = 0.0

    # Don't send IPs, cookies, request bodies, or user objects unless we
    # explicitly opt in later.
    config.send_default_pii = false

    # Zimmer's failure surfaces are background jobs and the session-lifecycle
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
