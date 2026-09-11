# frozen_string_literal: true

require "test_helper"
require "open3"

# Boots the app in a real `RAILS_ENV=production` subprocess, with SENTRY_DSN_BACKEND
# set, and asserts it gets through `Rails.application.initialize!`.
#
# WHY A SUBPROCESS RATHER THAN AN ASSERTION IN THIS PROCESS
# ---------------------------------------------------------
# The suite runs inside an already-booted app, so every `app/` constant is loadable and
# every initializer has already run. That is precisely the condition a boot bug cannot
# be seen under. `test/initializers/sentry_test.rb` claims to pin the initializer and
# does exercise the real file — but it `load`s it from a booted process, where the
# autoloader is long since set up, so it stayed green through a change that broke every
# production deploy. Only a fresh process in the target environment is evidence.
#
# WHAT IT CATCHES
# ---------------
# Rails runs `config/initializers/*.rb` from the engine's `:load_config_initializers`,
# and sets up the main Zeitwerk autoloader afterwards, in
# `Rails::Application::Finisher`'s `:setup_main_autoloader`. An `app/` constant
# referenced from an initializer body therefore raises
# `NameError: uninitialized constant` every time. That is what
# [#1121](https://github.com/tadasant/zimmer/pull/1121) shipped — `config/initializers/
# sentry.rb` reading `ErrorReporter::ALERTING_ENVIRONMENTS` — and because the whole
# `Sentry.init` block is gated on SENTRY_DSN_BACKEND, which development, test and CI never
# set, nothing outside a deployed environment ran the line. Kamal's `db:prepare` pre-deploy
# command aborted, the new container never passed its health check, and every
# `Deploy production` run rolled back.
#
# So: the DSN is set here, because that is the gate that hid the bug.
#
# The staging environment reads the same list through the same initializer, so the
# production boot covers both.
class ProductionBootTest < ActiveSupport::TestCase
  # Well-formed but unroutable. The SDK only parses it — `traces_sample_rate` is 0 and
  # nothing is captured during boot, so no transport is ever exercised.
  FAKE_DSN = "https://public@glitchtip.example.test/1"
  # A closed local port, so the exporter's background thread resolves no hostname and
  # touches no network — it only has to be *configured* for the health check below to
  # report a fully wired alerting path.
  FAKE_OTLP_ENDPOINT = "http://127.0.0.1:1/v1/logs"

  # Eager loading is skipped: it needs a populated production database (model class
  # bodies query on load), it is a later initializer than the one under test, and
  # `test/test_helper.rb` already eager loads the whole app. Everything this test is
  # about — `:load_config_initializers` and the `after_initialize` / `to_prepare`
  # hooks those initializers register — runs in full.
  PROBE = <<~RUBY
    require "./config/application"

    Rails.application.class.initializer("boot_probe_skip_eager_load", before: :eager_load!) do |app|
      app.config.eager_load = false
    end

    Rails.application.initialize!

    puts "BOOT_OK enabled_environments=\#{Sentry.configuration.enabled_environments.inspect} " \\
         "initialized=\#{Sentry.initialized?}"
  RUBY

  # One boot serves every case here — it costs a few seconds, and nothing in it is
  # per-case state.
  def self.boot_output
    @boot_output ||= begin
      env = {
        "RAILS_ENV" => "production",
        "SENTRY_DSN_BACKEND" => FAKE_DSN,
        "OTEL_LOGS_EXPORTER_ENDPOINT" => FAKE_OTLP_ENDPOINT,
        # Makes the `after_initialize` blocks that are gated on "server or worker
        # process" actually run — obs_reporting_health_check.rb is one of them, and it
        # reads the same list sentry.rb does. Without this the check no-ops and the
        # neighbour goes uncovered. GoodJob itself starts no threads in :external mode.
        "GOOD_JOB_EXECUTION_MODE" => "external",
        "SECRET_KEY_BASE" => "boot_probe_secret_key_base",
        # Nothing listens on port 1, so every database call in the boot fails with
        # ActiveRecord::ConnectionNotEstablished — which deployment_recovery.rb and
        # post_deploy_cache_clear.rb rescue by name, and which is the same shape as a
        # droplet whose Postgres has not come up yet. Deliberate, and two things at
        # once: the test can never write to a real database (it boots the PRODUCTION
        # environment inside a CI runner that has a live Postgres of its own), and it
        # asserts the same thing wherever it runs instead of depending on whether some
        # `zimmer_production` database happens to exist. Boot must not need a database:
        # Kamal runs this boot to execute db:prepare, before any schema is loaded.
        "DATABASE_HOST" => "127.0.0.1",
        "DATABASE_PORT" => "1",
        "DATABASE_SSLMODE" => "disable",
        # Production logs to STDOUT at info, which is where the health-check line lands.
        "RAILS_LOG_LEVEL" => "info"
      }

      output, status = Open3.capture2e(env, RbConfig.ruby, "-e", PROBE, chdir: Rails.root.to_s)
      [ output, status ]
    end
  end

  setup do
    @output, @status = self.class.boot_output
  end

  # A failed boot dumps a full Rails backtrace; the first lines are the ones that say
  # what broke, and repeating hundreds of frames per assertion buries them.
  def excerpt
    lines = @output.lines
    head = lines.first(30).join
    lines.size > 30 ? "#{head}… (#{lines.size - 30} more lines)" : head
  end

  test "the app boots in the production environment with SENTRY_DSN_BACKEND present" do
    assert @status.success?,
      "RAILS_ENV=production boot failed (exit #{@status.exitstatus}). " \
      "This is the deploy failing — Kamal's db:prepare runs this same boot.\n#{excerpt}"
    assert_includes @output, "BOOT_OK", "initialize! did not complete\n#{excerpt}"
  end

  test "no initializer reaches for a constant the autoloader has not set up yet" do
    refute_match(/NameError: uninitialized constant/, @output,
      "an initializer referenced an autoloaded app/ constant; initializers run before " \
      "Rails::Application::Finisher's :setup_main_autoloader\n#{excerpt}")
  end

  test "the SDK comes out of a real boot allowing exactly production and staging" do
    assert_includes @output, 'enabled_environments=["production", "staging"]',
      "the environment allowlist is what keeps an agent session's RAILS_ENV=test run " \
      "from paging #alerts on the production DSN it inherits (zimmer#176)\n#{excerpt}"
    assert_includes @output, "initialized=true", "the SDK did not initialize\n#{excerpt}"
  end

  test "the boot-time obs health check resolves the same list, in the same boot" do
    # It rescues everything and logs a warning, so a NameError in there would be
    # silent — assert on the line it prints when it resolved the list cleanly.
    assert_includes @output, "[ObsReportingHealthCheck] Alerting is configured in production.",
      "the health check did not complete; a constant it could not resolve would be " \
      "swallowed by its own rescue\n#{excerpt}"
    refute_includes @output, "[ObsReportingHealthCheck] Health check failed",
      "the health check raised\n#{excerpt}"
  end
end
