ENV["RAILS_ENV"] ||= "test"
require_relative "../config/environment"
require "rails/test_help"

# Safeguard: Fail fast if tests are not running against the test database.
# This prevents accidental pollution of development/production databases when
# tests are run via Zimmer or other spawned processes that may
# inherit environment variables from the parent process. See issue pulsemcp/agents#500.
unless Rails.env.test?
  abort <<~ERROR
    \e[31m
    ================================================================================
    SAFETY CHECK FAILED: Tests must run in the test environment!
    ================================================================================

    Current environment: #{Rails.env}
    Expected environment: test

    This safety check prevents tests from accidentally running against
    development or production databases.

    If you're running tests via an agent session, ensure the Claude CLI process
    is not inheriting database environment variables from the parent Rails process.

    To fix this, make sure RAILS_ENV=test is set when running tests.
    \e[0m
  ERROR
end

# Additional safeguard: Verify database name follows test naming convention
# This catches edge cases where RAILS_ENV is set correctly but DATABASE_URL
# points to a non-test database.
# Uses strict suffix matching (_test) to avoid false positives with names
# like "latest_db" or "protest_db" that contain "test" as a substring.
db_config = ActiveRecord::Base.connection_db_config
db_name = db_config.database.to_s
is_test_database = db_name.end_with?("_test") ||
                   db_name.match?(/[_-]test[_-]/) ||
                   db_name == "test"
unless is_test_database
  abort <<~ERROR
    \e[31m
    ================================================================================
    SAFETY CHECK FAILED: Database name must follow test naming convention!
    ================================================================================

    Current database: #{db_name}
    Expected: database name ending with "_test" or containing "_test_"

    This safety check prevents tests from accidentally running against
    development or production databases.

    Check your database configuration:
    - DATABASE_URL environment variable
    - config/database.yml test configuration

    If running via Zimmer, database environment variables from the
    parent process may be overriding the test database configuration.
    \e[0m
  ERROR
end

# Load test support files (excluding test files themselves)
Dir[Rails.root.join("test/support/**/*.rb")].each do |f|
  require f unless f.end_with?("_test.rb")
end

# Pre-install the AIR CLI and pre-warm the AirCatalogService cache once at test
# boot, before parallelize() forks workers. Two reasons:
#   1. 32 parallel workers would otherwise race to install on the same
#      AIR_INSTALL_DIR on fresh CI runners.
#   2. Many tests in agent_session_job_test.rb stub Thread.new to return a mock
#      Object. Open3.capture3 uses Thread.new internally, so any Open3 call under
#      that stub blows up with "undefined method 'value' for #<Object>". Those
#      tests hit AirCatalogService.entries_for(:mcp) transitively via
#      AgentSessionJob#perform → ensure_baseline_mcp_config!. By pre-warming the
#      catalog here, entries_for returns cached data without shelling out.
begin
  AirPrepareService.ensure_air_installed!
  AirCatalogService.entries_for(:skills)
rescue AirPrepareService::AirPrepareError, AirCatalogService::CatalogError => e
  warn "[test_helper] AIR CLI pre-warm failed: #{e.message} — individual tests may retry"
end

# Disable the 60s TTL in tests so the pre-warmed cache remains valid for the
# entire suite — a long worker run would otherwise expire the cache and force a
# real Open3 invocation. Tests that need fresh resolve output call
# AirCatalogService.reset! explicitly (see AirCatalogServiceTest).
AirCatalogService.singleton_class.class_eval do
  private

  def expired?
    false
  end
end

# Snapshot the pre-warmed tree so the global setup below can re-install it before
# every test. The TTL override above keeps the cache from expiring on its own,
# but it cannot stop a test from clearing it outright — AirCatalogServiceTest's
# teardown calls reset!, and every test that draws the next slot in that worker
# would otherwise inherit a cold cache and shell out. See
# test/support/air_catalog_cache_warmer.rb.
AirCatalogCacheWarmer.capture!

# Pre-warm the ActionView template resolver cache once at boot, before
# parallelize() forks workers. With template-load caching on (reloading
# disabled), the resolver memoizes each lookup — including empty results — so a
# single transient Dir.glob miss on the persistent CI runner would otherwise be
# cached as a permanent ActionView::MissingTemplate for an existing partial.
# Warming positive entries here makes every forked worker inherit a hit cache.
# See test/support/view_cache_warmer.rb.
if ActionView::Resolver.caching?
  begin
    ViewCacheWarmer.warm!
  rescue => e
    warn "[test_helper] view cache pre-warm failed: #{e.message} — renders will resolve lazily"
  end
end

# Resolve the ENTIRE application constant graph in the parent process, before
# parallelize() forks its workers. This replaces the per-constant "resolve gate"
# that used to live here (force-loading GoodJob::Job, its locked_jobs
# association, TranscriptFileLocator, …, one hand-added line at a time) — and
# supersedes #210, which added the TranscriptFileLocator line.
#
# The failure class it closes: a leaf constant reached only from deep service
# code — sometimes inside a background thread the session-monitoring code spawns
# — is left as a lazy Zeitwerk autoload. Ruby's autoload fires exactly once: if
# the first reference in a forked worker comes from such a thread and the load is
# interrupted (e.g. the thread is killed during test teardown), the one-shot
# autoload entry is consumed without the constant ever being defined. Every later
# reference in that worker then raises `uninitialized constant` /
# `Zeitwerk::NameError`. Which worker gets poisoned, and whether a poisoning
# reference runs first, depends entirely on the random --seed ordering (issues
# #2, #3, #5, #10; run 29525970639). Force-loading one constant at a time is
# whack-a-mole; every new leaf touched inside a thread needs another line.
#
# eager_load! loads every managed file up front, so after this call there is no
# pending autoload for any thread to race: each constant is `defined?` with a nil
# `autoload?` hook, and a reference just returns it — no load, no interruptible
# window — in every forked worker, for the whole graph rather than two hand-picked
# constants.
#
# config.eager_load is already ON in CI and OFF for a bare local `bin/rails test`
# (config/environments/test.rb ties it to ENV["CI"]). Calling eager_load! here is
# a cheap idempotent no-op when eager loading already ran at boot, and on the
# local path it extends the same guarantee without depending on the env var.
# Running it immediately before the fork keeps the guarantee tight regardless of
# the setting.
Rails.application.eager_load!

# Resolve the Rack env template once here, before parallelize() forks its workers.
#
# Rails::Application#env_config memoizes its hash — including
# "action_dispatch.logger" => Rails.logger — the first time anything asks for it, and
# Rails::Engine#build_request merges that hash *over* every request env. So the logger
# ActionDispatch::DebugExceptions writes an unhandled exception to is fixed, for the
# life of the process, to whatever Rails.logger was at that first call. It cannot be
# overridden per request.
#
# Left lazy, the first *request* in a worker wins that race. A test that swaps
# Rails.logger around a request — the common capture idiom — then leaves the memo
# pointing at its throwaway StringIO logger for the rest of the worker, and every later
# example there sees a request complete, sees the diagnostics page render, and sees no
# ERROR record at all, because the middleware is logging somewhere nobody is listening.
# Which worker got poisoned, and whether it also drew a test that observes middleware
# ERROR records, depended entirely on the random --seed ordering — the mechanism behind
# the flaky CsrfFailureLoggingTest control in issue #337.
#
# Resolving it here pins the entry to the real boot-time BroadcastLogger in every
# worker, so Rails.logger and the middleware's logger are the same object no matter
# what any example does afterwards.
#
# The same call freezes the rest of env_config at its boot values — show_exceptions,
# show_detailed_exceptions, log_rescued_responses, the CSP objects, the cookie salts.
# Nothing in the suite mutates config.action_dispatch.* mid-run, and nothing may start
# to: a request reads this hash, not the config object, so such a mutation would be
# silently ignored rather than half-applied depending on ordering.
Rails.application.env_config

module ActiveSupport
  class TestCase
    # Run tests in parallel. CI sets PARALLEL_WORKERS to throttle system test jobs
    # (each worker spawns a Chrome browser) without slowing unit tests down. When
    # the env var is unset or non-positive, fall back to one worker per processor.
    parallel_workers = ENV["PARALLEL_WORKERS"].to_i
    parallelize(workers: (parallel_workers > 0) ? parallel_workers : :number_of_processors)

    # Setup all fixtures in test/fixtures/*.yml for all tests in alphabetical order.
    fixtures :all

    # Re-install the boot-resolved AIR catalog before every test, so a test that
    # cleared or faked the process-global cache cannot change what the next test
    # in that worker sees. See test/support/air_catalog_cache_warmer.rb.
    #
    # prepend: true is what makes that unconditional. Setup callbacks otherwise
    # run in the order they were declared, and a callback added to a base class
    # is appended to the chain of every descendant that already exists — so the
    # framework test cases rails/test_help defines above (ActionController,
    # ActionView, ActionMailer) would run their own setups first. Prepending puts
    # the warm-up at the head of every chain regardless of declaration order,
    # while still leaving AirCatalogServiceTest's setup — which resets the cache
    # on purpose — to run afterwards and win.
    setup(prepend: true) { AirCatalogCacheWarmer.restore! }

    # TranscriptRedactionCache holds redacted transcript prefixes in a
    # process-global table keyed by path, so a test that reads a transcript can
    # otherwise leave an entry behind for the next test that happens to use the
    # same path. Its fingerprints make a stale hit safe rather than wrong, but a
    # test that measures cache behavior deserves a cold one.
    setup(prepend: true) { TranscriptRedactionCache.reset! }

    # Include test support helpers
    include MockHelpers
    include ProcessStatusHelpers
    include AssertionHelpers
    include FixtureHelpers
    include BroadcastHelpers
    include LogCaptureHelpers
    include McpOauthTestHelpers
    include SessionMemoryCgroupHelpers

    # The sessions dashboard shows `needs_input` only until the user filters. A
    # test that is about something else — pagination, card chrome, category
    # sections — asks for every status the way the UI does: an explicit Filters
    # submit with no status ticked, which means "show all".
    def every_status_params(extra = {})
      { SessionsController::FILTERS_SUBMITTED_PARAM => "1" }.merge(extra)
    end

    # Add more helper methods to be used by all tests here...
  end
end
