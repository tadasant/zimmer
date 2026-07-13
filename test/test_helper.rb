ENV["RAILS_ENV"] ||= "test"
require_relative "../config/environment"
require "rails/test_help"

# Safeguard: Fail fast if tests are not running against the test database.
# This prevents accidental pollution of development/production databases when
# tests are run via Zimmer or other spawned processes that may
# inherit environment variables from the parent process. See issue #500.
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

module ActiveSupport
  class TestCase
    # Run tests in parallel. CI sets PARALLEL_WORKERS to throttle system test jobs
    # (each worker spawns a Chrome browser) without slowing unit tests down. When
    # the env var is unset or non-positive, fall back to one worker per processor.
    parallel_workers = ENV["PARALLEL_WORKERS"].to_i
    parallelize(workers: (parallel_workers > 0) ? parallel_workers : :number_of_processors)

    # Setup all fixtures in test/fixtures/*.yml for all tests in alphabetical order.
    fixtures :all

    # Include test support helpers
    include MockHelpers
    include ProcessStatusHelpers
    include AssertionHelpers
    include FixtureHelpers
    include BroadcastHelpers

    # Add more helper methods to be used by all tests here...
  end
end
