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

    # ---- and what this initializer takes back OUT of the inherited list -------
    #
    # `excluded_exceptions` does not start empty. sentry-ruby seeds it with its own
    # IGNORE_DEFAULT + PUMA_IGNORE_DEFAULT, and sentry-rails' `after(:initialize)`
    # hook concatenates a further fourteen classes (Sentry::Rails::IGNORE_DEFAULT,
    # plus ActionController::TooManyRequests on Rails >= 8.1.1) *before* this block
    # ever runs. Every line above only ever appends, so nothing here ever audited
    # what it inherited — and issue #23 is the bill for that: production served a
    # storm of CSRF 422s (#19) in which **every write in the UI failed**, and
    # GlitchTip received nothing at all, because
    # ActionController::InvalidAuthenticityToken is item 4 of that inherited list.
    # A human found the outage by clicking a button.
    #
    # Subtraction, not a rewrite of the list: `-=` removes the name if it is there
    # and is a harmless no-op if a future sentry-rails stops shipping it, so this
    # line cannot break on an SDK that changes its own defaults. What it cannot
    # catch is the SDK excluding the class under some *other* name or via a
    # superclass, so test/initializers/sentry_test.rb asserts the behaviour rather
    # than the array — that the real, fully-resolved configuration will actually
    # build an event for this exception.
    #
    # The trade, stated plainly: a *rate* of CSRF rejections now reaches GlitchTip,
    # not each one. CsrfRejectionMonitor (called from
    # ApplicationController#invalid_authenticity_token) counts rejections in
    # five-minute buckets and captures a single exception once a bucket clears its
    # threshold, so the loudest possible storm costs one event per five minutes.
    # That explicit capture is the reason this removal matters at all:
    # Sentry::Client#event_from_exception checks excluded_exceptions on an explicit
    # `Sentry.capture_exception` exactly as it does on a middleware capture, so
    # while the name is in the resolved list the monitor's report is silently
    # dropped too. There is also one path with no rescue_from in front of it —
    # Supervisor::ApplicationController descends from
    # Administrate::ApplicationController, so a tokenless non-GET to /supervisor/*
    # raises through the middleware — and this removal is what puts that event, with
    # its URL and user agent, in GlitchTip instead of only in an unattributable
    # stack trace.
    #
    # **The rest of the inherited list was audited at the same time, and is
    # deliberately left alone.** For each class, why:
    #
    #   Already handled and re-logged at INFO, so un-excluding them would change
    #   nothing (nothing reaches the capture middleware) while adding bot noise to
    #   any path that later stopped being rescued:
    #     ActionController::RoutingError    — ErrorsController#not_found (the
    #                                         catch-all route); the class #23 named
    #                                         as "and friends", and the reason it is
    #                                         not the same case as CSRF is that a
    #                                         404 rate is normal for a public host.
    #     ActionController::UnknownFormat   — ApplicationController#unknown_format
    #                                         (#453). Its subclass
    #                                         MissingExactTemplate is deliberately
    #                                         re-raised and stays a loud ERROR.
    #     ActiveRecord::RecordNotFound      — ApplicationController#record_not_found
    #                                         renders 404; a stale link, not a fault.
    #
    #   Client-supplied garbage at the protocol edge. Zimmer is a public host and
    #   these are what a scanner produces; a rate of them says something about the
    #   internet, not about the app:
    #     ActionController::MethodNotAllowed, ActionController::NotImplemented,
    #     ActionController::UnknownHttpMethod, ActionController::InvalidCrossOriginRequest,
    #     ActionDispatch::Http::MimeNegotiation::InvalidType,
    #     Rack::QueryParser::ParameterTypeError, Sinatra::NotFound,
    #     Puma::MiniSSL::SSLError, Puma::HttpParserError, Puma::HttpParserError501
    #
    #   Re-added by the block above on purpose, so they are excluded twice over and
    #   removing them from the inherited list would be meaningless:
    #     ActionController::BadRequest, ActionDispatch::Http::Parameters::ParseError,
    #     Rack::QueryParser::InvalidParameterError
    #
    #   Genuinely arguable, and left excluded for now with the reason recorded
    #   rather than silently inherited:
    #     ActionController::ParameterMissing  — a *Zimmer* form omitting a required
    #       param would be a real bug, but the same exception is what a probe
    #       posting junk to a real route raises, and the two are indistinguishable
    #       from inside the exception. Zimmer's forms are covered by controller tests;
    #       this would trade a tested failure mode for untested noise.
    #     AbstractController::ActionNotFound / ActionController::UnknownAction — a
    #       route pointing at a missing action IS a server defect, but it is one
    #       `bin/rails routes` and the controller tests catch at CI time, and it cannot
    #       reach production without every request to that route failing loudly.
    #     ActionController::TooManyRequests — Rails 8.1's rate-limiter raising is
    #       the limiter *working*. Zimmer declares no `rate_limit` today, so this is
    #       inert either way.
    #     Mongoid::Errors::DocumentNotFound — no Mongoid in this app; the string
    #       never resolves to a class and the entry is inert.
    config.excluded_exceptions -= [ "ActionController::InvalidAuthenticityToken" ]

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
