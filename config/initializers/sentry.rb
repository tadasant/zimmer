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

    # An interactive `bin/rails runner` on the box is an operator, not the app.
    #
    # sentry-rails' runner hook reports every uncaught `rails runner` exception with the
    # tag `source: runner`. On the production droplet that one tag covers two things that
    # could not be less alike:
    #
    #   - The deploy workflow's job-drain gate, which shells into the web container twice:
    #     `docker exec <web> bin/rails runner '<queue-capability probe>'` and
    #     `docker exec -i <web> bin/rails runner -` for the canary script fed on stdin
    #     (tadasant-internal's `scripts/verify-job-drain-remote.sh`). A raise there means
    #     the deploy is unverified, and it must page.
    #   - An operator hand-typing a one-liner. On 2026-09-02, five guessed-column-name
    #     typos opened five GlitchTip issues, paged #alerts five times, and spawned four
    #     priority router sessions inside one hour (issue #767).
    #
    # A controlling terminal is what separates them, and it is the only thing that does.
    # Neither drain-gate invocation allocates one — no `-t`, and both capture their output
    # into a shell variable — and no GitHub Actions step has one either; a human iterating
    # at a `docker exec -it` prompt does. Note what does NOT separate them: the shape of
    # the code, because the drain gate uses *both* an inline one-liner and a stdin-fed
    # script, so a filter keyed on "typed as an argument" would silence its probe.
    #
    # Two wider draws are tempting and both are wrong: dropping every `source: runner`
    # event, or a global off-switch. Either silences the drain gate, and it does so
    # silently — nothing tells you an alert that should have paged did not.
    #
    # For the same reason this predicate is self-contained (no autoloaded constant that
    # could fail to resolve), it logs what it drops so the decision is greppable in the
    # container logs rather than invisible, and it fails open — because the SDK does not.
    # A raise inside before_send loses the event either way: swallowed by
    # Sentry::Client#capture_event's rescue on the synchronous path (which is the one
    # `rails runner` takes, since sentry-rails' runner hook forces
    # background_worker_threads = 0), and by the background worker thread everywhere else.
    # A bug in this filter would therefore be exactly the project-wide mute it exists to
    # avoid, so anything unexpected here reports the event instead.
    config.before_send = lambda do |event, _hint|
      begin
        tags = event.tags
        source = tags[:source] || tags["source"]
        attached_to_terminal = [ $stdin, $stdout, $stderr ].any?(&:tty?)

        if source.to_s == "runner" && attached_to_terminal
          # Exception class only, never the message: a console one-liner's message can
          # carry row data, and this line goes to the container log and the OTLP exporter.
          Rails.logger.info(
            "[sentry] dropped an interactive rails runner event: " \
            "#{event.exception&.values&.first&.type || "unknown"}"
          )
          next nil
        end
      rescue StandardError
        # Fail open: report the event rather than let a filter bug mute the project.
      end

      event
    end
  end
end
