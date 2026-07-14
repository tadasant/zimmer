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
end
