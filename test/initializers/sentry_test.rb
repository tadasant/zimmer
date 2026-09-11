# frozen_string_literal: true

require "test_helper"

# Exercises the real config/initializers/sentry.rb by loading it with a fake DSN
# in ENV and Rails.env stubbed, then routing the SDK's output into an in-memory
# DummyTransport. Nothing is mocked about the gate itself: the environment, the
# enabled_environments allowlist, and the DSN all come from the initializer.
#
# The bug this pins (issue #176): Zimmer's agent sessions run inside the *production*
# container, so every agent-session shell inherits production's SENTRY_DSN_BACKEND.
# A `RAILS_ENV=test bin/rails db:prepare` in an agent's repo clone therefore
# initialized the SDK against the production GlitchTip DSN, and the resulting
# PG::ConnectionBad paged the production Slack #alerts channel with an error that
# never happened in production. Gating on the DSN's presence cannot prevent this —
# the DSN really is present. The environment allowlist is what holds.
class SentryInitializerTest < ActiveSupport::TestCase
  # Well-formed but unroutable: the initializer must never see the real DSN here,
  # and DummyTransport means nothing leaves the process regardless.
  FAKE_DSN = "https://public@glitchtip.example.test/1"

  INITIALIZER = Rails.root.join("config/initializers/sentry.rb").to_s

  # Loads the real initializer as if the app were booting in `rails_env` with
  # SENTRY_DSN_BACKEND set, then swaps in a DummyTransport (and disables the
  # background worker) so captured events are observable synchronously and
  # in-memory. The swapped-in client is built from a dup of the initializer's own
  # configuration — dsn, environment, enabled_environments — and the SDK drops
  # disallowed events in Client#capture_event, *before* the transport. So the
  # send/drop decision under test is the initializer's, not the test's: strip
  # enabled_environments from the initializer and these events land in the
  # DummyTransport and the assertions fail.
  #
  # Do NOT "simplify" this to Sentry::TestHelper#setup_sentry_test. That helper
  # force-adds the current environment to enabled_environments, which would
  # silently destroy the exact thing being tested.
  #
  # Sentry.close (in the ensure) nils the main hub and the thread-local hub, so
  # each case starts and ends with an uninitialized SDK — which is what the rest
  # of the suite (e.g. ErrorReporterTest) assumes. Two residues survive close and
  # are harmless: the SDK's Net::HTTP/Redis patches stay prepended (they no-op
  # unless Sentry.initialized?), and each init stacks an at_exit { close } (a
  # repeat close is a no-op).
  def boot_sentry(rails_env, dsn: FAKE_DSN)
    original_dsn = ENV["SENTRY_DSN_BACKEND"]
    ENV["SENTRY_DSN_BACKEND"] = dsn

    Rails.stub(:env, ActiveSupport::StringInquirer.new(rails_env)) do
      load INITIALIZER
    end

    if Sentry.initialized?
      config = Sentry.configuration.dup
      config.transport.transport_class = Sentry::DummyTransport
      config.background_worker_threads = 0
      Sentry.get_main_hub.bind_client(Sentry::Client.new(config))
    end

    yield
  ensure
    Sentry.close if Sentry.initialized?
    if original_dsn.nil?
      ENV.delete("SENTRY_DSN_BACKEND")
    else
      ENV["SENTRY_DSN_BACKEND"] = original_dsn
    end
  end

  def captured_events
    Sentry.get_current_client.transport.events
  end

  test "test env with the production DSN present sends nothing" do
    boot_sentry("test") do
      assert Sentry.initialized?, "the DSN is present, so the SDK does initialize"
      assert_equal "test", Sentry.configuration.environment
      refute Sentry.configuration.enabled_in_current_env?
      refute Sentry.configuration.sending_allowed?

      assert_nil Sentry.capture_exception(ActiveRecord::DatabaseConnectionError.new("boom"))
      Sentry.capture_message("also nothing")

      assert_empty captured_events,
        "a RAILS_ENV=test process must not ship events to the production GlitchTip project"
    end
  end

  test "ErrorReporter, the app's own reporting seam, also sends nothing from the test env" do
    boot_sentry("test") do
      ErrorReporter.report_exception(StandardError.new("boom"), context: { session_id: 154 })
      ErrorReporter.report_message("lifecycle warning")

      assert_empty captured_events
    end
  end

  test "development env sends nothing even with a DSN present" do
    boot_sentry("development") do
      refute Sentry.configuration.sending_allowed?

      Sentry.capture_exception(StandardError.new("boom"))
      assert_empty captured_events
    end
  end

  test "production still reports" do
    boot_sentry("production") do
      assert Sentry.configuration.enabled_in_current_env?
      assert Sentry.configuration.sending_allowed?

      Sentry.capture_exception(StandardError.new("real production failure"))

      assert_equal 1, captured_events.size
      event = captured_events.first.to_h
      assert_equal "production", event[:environment]
      assert_includes event[:exception][:values].first[:value], "real production failure"
    end
  end

  test "staging still reports" do
    boot_sentry("staging") do
      assert Sentry.configuration.sending_allowed?

      Sentry.capture_exception(StandardError.new("real staging failure"))

      assert_equal 1, captured_events.size
      assert_equal "staging", captured_events.first.to_h[:environment]
    end
  end

  test "the allowlist is exactly production and staging" do
    boot_sentry("production") do
      assert_equal %w[production staging], Sentry.configuration.enabled_environments
    end
  end

  test "no DSN is still a hard no-op: the SDK never initializes" do
    boot_sentry("production", dsn: nil) do
      refute Sentry.initialized?
      refute ErrorReporter.reporting_enabled?
    end
  end

  # An empty Kamal secret is a plausible production misconfiguration, and `.present?`
  # (not `nil?`) is what stands between it and a DSN-less Sentry.init raise.
  test "an empty DSN is a hard no-op, not a half-initialized SDK" do
    boot_sentry("production", dsn: "") do
      refute Sentry.initialized?
    end
  end

  # --- issue #767: an interactive `rails runner` is an operator, not the app ----------
  #
  # sentry-rails' runner hook tags every uncaught `bin/rails runner` exception
  # `source: runner`. Two very different things wear that tag on the prod box: the deploy
  # workflow's job-drain gate (`docker exec` and `docker exec -i`, no TTY either way) and
  # an operator hand-typing a one-liner at a `docker exec -it` prompt. Five of the latter
  # paged #alerts five times in an hour on 2026-09-02.
  #
  # The filter's failure mode is silence, so all three directions are pinned explicitly:
  # the console typo drops, the drain gate still reports, and non-runner events are
  # untouched. Delete the `attached_to_terminal` half of the initializer's before_send and
  # the "drain gate" cases below fail; delete the `source == runner` half and the
  # "unaffected" cases fail.

  # Stubs the three standard streams, always all three, so a case means the same thing
  # whether the suite runs under a developer's terminal or a CI runner's pipe.
  def with_ttys(stdin: false, stdout: false, stderr: false, &block)
    $stdin.stub(:tty?, stdin) do
      $stdout.stub(:tty?, stdout) do
        $stderr.stub(:tty?, stderr, &block)
      end
    end
  end

  # What sentry-rails' `runner` railtie hook does at_exit with an uncaught exception.
  def capture_runner_exception(message)
    Sentry.capture_exception(StandardError.new(message), tags: { source: "runner" })
  end

  test "an interactive rails runner exception is not reported" do
    boot_sentry("production") do
      with_ttys(stdin: true, stdout: true, stderr: true) do
        capture_runner_exception("PG::UndefinedColumn: column sessions.initial_prompt does not exist")
      end

      assert_empty captured_events,
        "a hand-typed console typo must not open a GlitchTip issue or page #alerts"
    end
  end

  # `docker exec -t` (no `-i`) leaves stdin unattached but allocates a terminal on the
  # output side. Any one of the three streams being a terminal means a human is there.
  test "a runner exception with a terminal on any single stream is not reported either" do
    boot_sentry("production") do
      [ :stdin, :stdout, :stderr ].each do |stream|
        with_ttys(stream => true) do
          capture_runner_exception("PG::UndefinedColumn: no column post_deploy_task_runs.#{stream}")
        end

        assert_empty captured_events, "a terminal on #{stream} alone still means an operator"
      end
    end
  end

  # The job-drain gate, both of its invocations: the canary fed to `bin/rails runner -`
  # over `docker exec -i`, and the queue-capability one-liner passed as an argument to
  # plain `docker exec`. Neither allocates a terminal, and that is the ONLY thing this
  # seam can see — the two are deliberately indistinguishable here, because a filter that
  # could tell them apart would be keyed on the wrong thing and would silence the second.
  # This is the signal the filter must not touch: a raise here means an unverified deploy.
  test "a non-interactive rails runner exception is still reported, in either shape" do
    boot_sentry("production") do
      with_ttys do
        capture_runner_exception("job drain canary never ran")
        capture_runner_exception("queue capability probe blew up")
      end

      assert_equal 2, captured_events.size,
        "the deploy workflow's drain gate runs the runner without a TTY and must still page"
      events = captured_events.map(&:to_h)
      values = events.map { |e| e[:exception][:values].first[:value] }
      assert(values.any? { |v| v.include?("job drain canary never ran") })
      assert(values.any? { |v| v.include?("queue capability probe blew up") })
      assert_equal [ "runner", "runner" ], events.map { |e| e[:tags][:source] },
        "the events reach GlitchTip with their runner tag intact"
    end
  end

  # The gem passes `source` as a symbol today. If a future version hands it over as a
  # string the filter must still match, so that branch is pinned rather than assumed.
  test "a string-keyed source tag is matched too" do
    boot_sentry("production") do
      with_ttys(stdin: true) do
        Sentry.capture_exception(StandardError.new("typo"), tags: { "source" => "runner" })
      end

      assert_empty captured_events
    end
  end

  # The SDK fails CLOSED: Client#capture_event rescues whatever before_send raises and
  # drops the event. So the initializer's own `rescue` is the only thing between a bug in
  # this filter and a silent project-wide mute, and it is worth a test of its own —
  # without this case, deleting that rescue breaks nothing visible.
  test "a predicate that blows up reports the event instead of eating it" do
    boot_sentry("production") do
      exploding = ->(*) { raise "tty? is not answerable here" }

      # Runner-tagged and would otherwise be dropped, so the assertion turns on the
      # rescue rather than on the tag: `attached_to_terminal` is computed before the
      # tag is consulted, so the raise lands whatever the event is.
      $stdin.stub(:tty?, exploding) do
        capture_runner_exception("a real production failure")
      end

      assert_equal 1, captured_events.size,
        "a broken before_send must fail open, never mute the project"
    end
  end

  test "a non-runner exception is unaffected, terminal or not" do
    boot_sentry("production") do
      with_ttys(stdin: true, stdout: true, stderr: true) do
        Sentry.capture_exception(StandardError.new("a real web request failed"))
        Sentry.capture_exception(StandardError.new("a real job failed"), tags: { source: "application.active_job" })
        ErrorReporter.report_exception(StandardError.new("a real lifecycle failure"), context: { session_id: 767 })
      end

      assert_equal 3, captured_events.size,
        "the filter must key on the runner tag; ordinary app errors are none of its business"
      values = captured_events.map { |e| e.to_h[:exception][:values].first[:value] }
      assert(values.any? { |v| v.include?("a real web request failed") })
      assert(values.any? { |v| v.include?("a real job failed") })
      assert(values.any? { |v| v.include?("a real lifecycle failure") })
    end
  end

  test "the filter does not disturb an untagged message event at a terminal" do
    boot_sentry("production") do
      with_ttys(stdin: true) do
        ErrorReporter.report_message("lifecycle warning")
      end

      assert_equal 1, captured_events.size
    end
  end

  # Staging runs the same initializer; the filter is not production-only.
  test "staging drops the interactive runner and keeps the non-interactive one" do
    boot_sentry("staging") do
      with_ttys(stdin: true) { capture_runner_exception("typo on staging") }
      assert_empty captured_events

      with_ttys { capture_runner_exception("staging drain gate") }
      assert_equal 1, captured_events.size
    end
  end

  # --- issue #23: what this initializer takes back out of the inherited list ----------
  #
  # `excluded_exceptions` arrives pre-populated: sentry-ruby seeds it, then
  # sentry-rails' after(:initialize) hook concatenates Sentry::Rails::IGNORE_DEFAULT
  # plus ActionController::TooManyRequests on Rails >= 8.1.1 — all before the
  # initializer's own block runs. ActionController::InvalidAuthenticityToken sat in it
  # unaudited, and a storm of CSRF 422s in which every write in the UI failed (#19)
  # reached GlitchTip zero times.
  #
  # These cases run against the REAL resolved configuration, not against the literal in
  # the file, which is what makes them survive the SDK changing its own defaults.

  REMOVED_FROM_INHERITED = %w[
    ActionController::InvalidAuthenticityToken
    ActionController::UnknownFormat
  ].freeze

  # The whole resolved list, deduplicated. Pinned in full so that a bump to ANY of the
  # SDK's default lists — sentry-ruby's IGNORE_DEFAULT or PUMA_IGNORE_DEFAULT,
  # sentry-rails' IGNORE_DEFAULT or RAILS_8_1_1_IGNORE_DEFAULT — fails here rather than
  # silently changing what production reports. Every entry is accounted for, by name,
  # in the audit comment in config/initializers/sentry.rb; a new one needs a line there.
  RESOLVED_EXCLUSIONS = %w[
    AbstractController::ActionNotFound
    ActionController::BadRequest
    ActionController::InvalidCrossOriginRequest
    ActionController::MethodNotAllowed
    ActionController::NotImplemented
    ActionController::ParameterMissing
    ActionController::RoutingError
    ActionController::TooManyRequests
    ActionController::UnknownAction
    ActionController::UnknownHttpMethod
    ActionDispatch::Http::MimeNegotiation::InvalidType
    ActionDispatch::Http::Parameters::ParseError
    ActiveRecord::RecordNotFound
    Errno::EIO
    Mongoid::Errors::DocumentNotFound
    Puma::HttpParserError
    Puma::HttpParserError501
    Puma::MiniSSL::SSLError
    Rack::QueryParser::InvalidParameterError
    Rack::QueryParser::ParameterTypeError
    Rack::Timeout::RequestTimeoutError
    Sinatra::NotFound
  ].freeze

  def csrf_exception
    ActionController::InvalidAuthenticityToken.new("Can't verify CSRF token authenticity.")
  end

  def missing_exact_template
    ActionController::MissingExactTemplate.new(
      "SessionsController#show is missing a template for request formats: text/html", nil, "show"
    )
  end

  # If the gem stopped shipping these, the `-=` in the initializer would be a silent
  # no-op and its audit comment would be describing a list that no longer exists.
  test "sentry-rails ships the two defaults the initializer subtracts" do
    REMOVED_FROM_INHERITED.each do |name|
      assert_includes Sentry::Rails::IGNORE_DEFAULT, name
    end
  end

  test "the resolved exclusion list is exactly the audited one" do
    boot_sentry("production") do
      assert_equal RESOLVED_EXCLUSIONS, Sentry.configuration.excluded_exceptions.uniq.sort
    end
  end

  test "neither subtracted class is in the resolved exclusion list" do
    boot_sentry("production") do
      REMOVED_FROM_INHERITED.each do |name|
        refute_includes Sentry.configuration.excluded_exceptions, name
      end
    end
  end

  # The behavioural assertion, and the one that holds. A future SDK could exclude the
  # class under another name or via a new ancestor, and a list check would still pass
  # while nothing reported.
  test "a CSRF rejection builds and ships a real event in production" do
    boot_sentry("production") do
      assert Sentry.configuration.exception_class_allowed?(csrf_exception)

      Sentry.capture_exception(csrf_exception)

      assert_equal 1, captured_events.size,
        "issue #19 was hours of universal write failure that GlitchTip never saw"
      assert_equal "ActionController::InvalidAuthenticityToken",
        captured_events.first.to_h[:exception][:values].first[:type]
    end
  end

  # Exclusion matches with `===`, so excluding UnknownFormat also excluded its subclass
  # MissingExactTemplate — a forgotten view, which ApplicationController deliberately
  # re-raises so it stays loud. It reached the capture middleware and was dropped there.
  test "a missing template, a server defect, builds and ships a real event" do
    boot_sentry("production") do
      assert Sentry.configuration.exception_class_allowed?(missing_exact_template)

      Sentry.capture_exception(missing_exact_template)

      assert_equal 1, captured_events.size
      assert_equal "ActionController::MissingExactTemplate",
        captured_events.first.to_h[:exception][:values].first[:type]
    end
  end

  # CsrfRejectionMonitor reports through ErrorReporter with a fixed fingerprint, so the
  # seam the app uses is pinned end to end, extras and grouping included.
  test "the rate monitor's reporting seam reaches GlitchTip with its context and fingerprint" do
    boot_sentry("production") do
      ErrorReporter.report_exception(
        csrf_exception,
        context: { csrf_rejections_in_window: 42, window_seconds: 300 },
        fingerprint: CsrfRejectionMonitor::FINGERPRINT
      )

      assert_equal 1, captured_events.size
      event = captured_events.first.to_h
      assert_equal 42, event[:extra][:csrf_rejections_in_window]
      assert_equal 300, event[:extra][:window_seconds]
      assert_equal [ "csrf-rejection-rate" ], event[:fingerprint]
    end
  end

  test "an ErrorReporter call without a fingerprint leaves the SDK's default grouping alone" do
    boot_sentry("production") do
      ErrorReporter.report_exception(StandardError.new("ordinary failure"))

      assert_equal [], captured_events.first.to_h[:fingerprint]
    end
  end

  # The subtraction is exactly two classes wide. Everything this initializer
  # deliberately adds must still be dropped — otherwise the removal was written as a
  # rewrite of the list rather than a subtraction from it.
  test "the deliberate exclusions this initializer adds are untouched" do
    boot_sentry("production") do
      [
        Errno::EIO.new("bot"),
        Rack::QueryParser::InvalidParameterError.new("malformed query"),
        ActionController::BadRequest.new("malformed request"),
        ActionDispatch::Http::Parameters::ParseError.new("malformed body")
      ].each do |exception|
        Sentry.capture_exception(exception)
      end

      assert_empty captured_events,
        "removing inherited defaults must not disturb the exclusions added above them"
    end
  end

  # The audited-and-kept half of #23. Each of these is handled elsewhere in the app or
  # is malformed client input; the initializer records why each stays. A change that
  # widens the `-=` into "un-exclude the 4xx family" fails here.
  test "the inherited defaults the audit deliberately kept are still excluded" do
    boot_sentry("production") do
      [
        ActionController::RoutingError.new("No route matches"),
        ActiveRecord::RecordNotFound.new("Couldn't find Session"),
        ActionController::ParameterMissing.new(:session),
        ActionController::ExpectedParameterMissing.new(:session),
        ActionController::MethodNotAllowed.new("only POST"),
        ActionController::InvalidCrossOriginRequest.new("cross-origin"),
        ActionController::UnknownHttpMethod.new("PROPFIND"),
        AbstractController::ActionNotFound.new("no action")
      ].each do |exception|
        Sentry.capture_exception(exception)
      end

      assert_empty captured_events,
        "these stay excluded on purpose — see the audit in config/initializers/sentry.rb"
    end
  end
end
