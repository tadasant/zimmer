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
    # `AlertingEnvironments::ALL` is the same list obs_reporting_health_check.rb reads
    # at boot. test/initializers/sentry_test.rb pins the SDK's resolved value, and
    # test/initializers/production_boot_test.rb pins it from a real production boot.
    #
    # It is defined in config/alerting_environments.rb, which config/application.rb
    # require_relatives, and NOT in app/ — initializers run before Rails sets up the
    # main Zeitwerk autoloader, so an autoloaded constant here raises NameError and
    # takes the whole boot with it. See that file's header.
    config.enabled_environments = AlertingEnvironments::ALL

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
    # IGNORE_DEFAULT + PUMA_IGNORE_DEFAULT (seven names), and sentry-rails'
    # `after(:initialize)` hook concatenates fifteen more (Sentry::Rails::IGNORE_DEFAULT's
    # fourteen, plus ActionController::TooManyRequests on Rails >= 8.1.1) *before* this
    # block runs. The block above only appends, and nothing audited what it inherited —
    # which is how issue #23 happened: production served a storm of CSRF 422s (#19,
    # `assume_ssl` on a plain-HTTP tailnet deploy) in which **every write in the UI
    # failed**, and GlitchTip received nothing at all, because
    # ActionController::InvalidAuthenticityToken is in that inherited list. A human
    # found the outage by clicking a button.
    #
    # Exclusion matches with `===`, so an entry also silences every SUBCLASS of the
    # class it names. The audit below was run over every loaded exception class, not
    # only over the names in the list, and that is how it found the second removal.
    #
    # Subtraction, not a rewrite of the list: `-=` removes a name if the SDK ships it
    # and is a harmless no-op if a future sentry-rails stops, so this line cannot break
    # on an SDK that changes its own defaults. What it cannot catch is the SDK
    # excluding a class under some other name or via a new ancestor, so
    # test/initializers/sentry_test.rb pins the whole resolved list and asserts the
    # behaviour — that the fully-resolved configuration builds an event for each class
    # removed here — rather than trusting this array.
    #
    # Removed:
    #
    #   ActionController::InvalidAuthenticityToken — one is noise, a hundred an hour is
    #     the app broken for every writer, and the two are the same exception. Most of
    #     the app handles it in ApplicationController's `rescue_from` (INFO, #295), so
    #     nothing reaches the capture middleware there; CsrfRejectionMonitor turns a
    #     *rate* of those into one GlitchTip event per five-minute bucket, with a fixed
    #     fingerprint so a storm is its own issue. The monitor reports the exception
    #     object, and Sentry::Client#event_from_exception consults this list on an
    #     explicit capture exactly as on a middleware one, so the monitor depends on
    #     this removal. Two surfaces have no such rescue and report per request:
    #     /supervisor (Administrate::ApplicationController) and /jobs (the GoodJob
    #     engine, `protect_from_forgery with: :exception`). Both already log the
    #     failure at ERROR, which pages; GlitchTip gets the twin of that page with the
    #     URL and user agent the log record lacks. On this deployment the host is
    #     tailnet-only, so the only clients that can reach either are tailnet members.
    #     A monitor-only `hint: { ignore_exclusions: true }` would have kept those two
    #     surfaces out of GlitchTip — silently swallowed, the shape #23 is about.
    #
    #   ActionController::UnknownFormat — not for itself, for its subclass.
    #     ActionController::MissingExactTemplate (an action with no template in ANY
    #     format, on an ordinary browser page load: a forgotten view) is a server
    #     defect, and ApplicationController deliberately re-raises it so it stays loud.
    #     It reached the capture middleware and was dropped there by this parent's
    #     entry. Plain UnknownFormat is rescued at INFO by
    #     ApplicationController#unknown_format (#453), so on that path nothing reaches
    #     the middleware; on the API, Administrate and GoodJob surfaces it reports per
    #     request, and those already log it at ERROR.
    #
    # Kept, with the reason for each:
    #
    #   ActionController::RoutingError — ErrorsController#not_found (the catch-all
    #     route) handles every miss and re-logs it at INFO, so un-excluding it reaches
    #     nothing; and a 404 rate describes clients, not the app. This is the class #23
    #     named as "and friends", and it is not the CSRF case.
    #   ActiveRecord::RecordNotFound — ApplicationController#record_not_found renders
    #     the 404; a stale link, not a fault.
    #   ActionController::ParameterMissing (and its subclass
    #     ActionController::ExpectedParameterMissing, from `params.expect`) — a Zimmer
    #     form omitting a required param would be a real bug, but the same exception is
    #     what any client posting junk to a real route raises, and the exception cannot
    #     tell the two apart. Zimmer's forms are covered by controller tests.
    #   AbstractController::ActionNotFound — a route pointing at a missing action is a
    #     server defect, but CI's routing and controller tests catch it, and it cannot
    #     reach production without every request to that route failing loudly.
    #   ActionController::TooManyRequests — Rails 8.1's rate limiter raising is the
    #     limiter working. Zimmer declares no `rate_limit`, so the entry is inert.
    #   ActionController::MethodNotAllowed, NotImplemented, UnknownHttpMethod,
    #     InvalidCrossOriginRequest, ActionDispatch::Http::MimeNegotiation::InvalidType,
    #     Rack::QueryParser::ParameterTypeError, Puma::MiniSSL::SSLError,
    #     Puma::HttpParserError, Puma::HttpParserError501 — malformed input at the
    #     protocol edge. Each is the client's mistake, none has a server-side cause a
    #     rate would reveal, and a deployment with a public domain would see scanners
    #     produce all of them.
    #   ActionController::BadRequest, ActionDispatch::Http::Parameters::ParseError,
    #     Rack::QueryParser::InvalidParameterError — re-added by the block above on
    #     purpose, so they are excluded twice over.
    #   Mongoid::Errors::DocumentNotFound, Sinatra::NotFound,
    #     ActionController::UnknownAction — no class by these names is loaded in this
    #     app (UnknownAction left Rails long ago), so the entries are inert.
    config.excluded_exceptions -= [
      "ActionController::InvalidAuthenticityToken",
      "ActionController::UnknownFormat"
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
