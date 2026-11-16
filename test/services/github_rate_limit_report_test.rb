# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"

# GithubRateLimitReport is what every human-facing surface says about a spent GitHub budget.
# It reads GithubRateLimit's breakers and snapshot, and never calls GitHub.
class GithubRateLimitReportTest < ActiveSupport::TestCase
  include GithubRateLimitStateHelpers

  setup do
    @original_cache = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
    use_test_gh_token
    # Nothing here may reach GitHub: every reading comes from the cache.
    GithubCli.expects(:run).never
    BoundedSubprocess.expects(:capture).never
    @now = Time.zone.parse("2026-11-15T21:15:00Z")
    travel_to @now
  end

  teardown do
    travel_back
    Rails.cache = @original_cache
    restore_gh_tokens
  end

  test "nothing known to be wrong reads as nothing" do
    assert_empty GithubRateLimitReport.readings
    assert_nil GithubRateLimitReport.diagnosis
    refute GithubRateLimitReport.sweep_blocked?(GithubRateLimitReport.readings)
  end

  test "a spent core budget names the budget, the login, remaining/limit, the UTC reset and how long until it, and that polling continues" do
    reset = @now + 12.minutes
    open_rate_limit_breaker("core", reset)
    write_rate_limit_snapshot("core" => [ 0, 5000, reset ], "search" => [ 28, 30, @now + 40.seconds ],
                              "graphql" => [ 4800, 5000, reset ])
    remember_github_login("tadasant")

    reading = GithubRateLimitReport.readings.sole
    assert reading.spent
    assert_equal "core", reading.resource
    assert reading.polling_continues?
    assert_equal "GH_TOKEN (tadasant)'s core budget is spent: 0/5000 left, resets 2026-11-15 21:27 UTC (in 12 min). " \
                 "GitHub trigger polling continues through it: its sweep spends only the search budget (28/30 left).",
                 reading.message
    refute GithubRateLimitReport.sweep_blocked?([ reading ])

    hash = reading.to_h
    assert_equal "continues", hash[:trigger_polling]
    assert_equal "2026-11-15T21:27:00Z", hash[:reset_at]
    assert_equal "tadasant", hash[:login]
  end

  test "a spent search budget pauses trigger polling, and says so" do
    reset = @now + 40.seconds
    write_rate_limit_snapshot("core" => [ 4000, 5000, @now + 30.minutes ], "search" => [ 0, 30, reset ])

    reading = GithubRateLimitReport.readings.sole
    assert_equal "search", reading.resource
    assert_includes reading.message, "GH_TOKEN's search budget is spent: 0/30 left, resets 2026-11-15 21:15 UTC (in under a minute)."
    assert_includes reading.message, "GitHub trigger polling is paused until then."
    assert GithubRateLimitReport.sweep_blocked?(GithubRateLimitReport.readings)
  end

  test "core and search both spent: core's reading says polling is paused, not continuing" do
    open_rate_limit_breaker("core", @now + 12.minutes)
    open_rate_limit_breaker("search", @now + 30.seconds)

    core = GithubRateLimitReport.readings.find { |r| r.resource == "core" }
    assert_includes core.message, "GitHub trigger polling is paused too, but by the spent search budget, not this one."
    assert_equal "paused", core.to_h[:trigger_polling]
    refute core.polling_continues?
  end

  test "an open breaker with no snapshot still reports, and leaves unsaid what it cannot know" do
    open_rate_limit_breaker("core", @now + 12.minutes)

    reading = GithubRateLimitReport.readings.sole
    assert_equal "GH_TOKEN's core budget is spent: 0 left, resets 2026-11-15 21:27 UTC (in 12 min).", reading.message
    assert_nil reading.to_h[:trigger_polling]
  end

  test "a low core budget is reported but not as spent, and spent budgets sort first" do
    write_rate_limit_snapshot("core" => [ 312, 5000, @now + 20.minutes ], "search" => [ 0, 30, @now + 30.seconds ])

    readings = GithubRateLimitReport.readings
    assert_equal %w[search core], readings.map(&:resource)
    assert_includes readings.last.message, "GH_TOKEN's core budget is running low: 312/5000 left"
    assert_equal [ "search" ], GithubRateLimitReport.spent.map(&:resource)
  end

  test "the diagnosis is one paragraph of every reading, with the per-user explanation" do
    open_rate_limit_breaker("core", @now + 12.minutes)
    write_rate_limit_snapshot("core" => [ 0, 5000, @now + 12.minutes ], "search" => [ 30, 30, @now + 50.seconds ])

    diagnosis = GithubRateLimitReport.diagnosis
    assert diagnosis.start_with?("GitHub rate limit: GH_TOKEN's core budget is spent: 0/5000 left, resets 2026-11-15 21:27 UTC (in 12 min).")
    assert_includes diagnosis, "polling continues through it"
    assert_includes diagnosis, "agent sessions running `gh` as the same user spend it too"
    refute_includes diagnosis, TEST_GH_TOKEN
  end

  test "a report that cannot read the state falls back to GithubRateLimit.diagnosis" do
    GithubRateLimit.stubs(:snapshot).raises(RuntimeError, "cache down")
    GithubRateLimit.stubs(:diagnosis).returns("GitHub rate limit: GH_TOKEN's core budget is spent until 2026-11-15T21:27:00Z.")

    assert_equal "GitHub rate limit: GH_TOKEN's core budget is spent until 2026-11-15T21:27:00Z.", GithubRateLimitReport.diagnosis
    assert_empty GithubRateLimitReport.readings, "the structured readings fail open to nothing known"
  end

  test "relative reset text" do
    assert_equal "in 3 min", GithubRateLimitReport.relative(@now + 150.seconds, now: @now)
    assert_equal "in under a minute", GithubRateLimitReport.relative(@now + 10.seconds, now: @now)
    assert_equal "now", GithubRateLimitReport.relative(@now - 1.second, now: @now)
  end

  test "an open breaker reads as 0 left even when an older snapshot counted more" do
    write_rate_limit_snapshot("core" => [ 312, 5000, @now + 12.minutes ])
    open_rate_limit_breaker("core", @now + 12.minutes)

    assert_includes GithubRateLimitReport.readings.sole.message, "core budget is spent: 0/5000 left"
  end

  test "a search reading whose reset has passed says the budget has refilled, so polling continues" do
    open_rate_limit_breaker("core", @now + 12.minutes)
    write_rate_limit_snapshot("core" => [ 0, 5000, @now + 12.minutes ], "search" => [ 0, 30, @now - 5.seconds ])

    reading = GithubRateLimitReport.readings.sole
    assert_equal "core", reading.resource, "a search reading past its reset is not spent"
    assert_includes reading.message, "its sweep spends only the search budget (refilled since the last reading)."
  end

  test "a spent snapshot whose reset has passed, with no breaker, reports nothing" do
    write_rate_limit_snapshot("core" => [ 0, 5000, @now - 1.minute ])

    assert_empty GithubRateLimitReport.readings
  end

  test "with several tokens, each reading is scoped to its own token, and the sweep is blocked only when every search budget is" do
    ENV["GH_TOKEN__ACME"] = "ghp_acme_token_for_tests"
    acme = GithubRateLimit.credentials.find { |c| c[:label] == "GH_TOKEN__ACME" }
    Rails.cache.write(GithubRateLimit.exhausted_key(acme, "search"), (@now + 40.seconds).to_i)

    readings = GithubRateLimitReport.readings
    assert_equal [ "GH_TOKEN__ACME" ], readings.map(&:credential)
    refute GithubRateLimitReport.sweep_blocked?(readings)

    open_rate_limit_breaker("search", @now + 40.seconds)
    assert GithubRateLimitReport.sweep_blocked?(GithubRateLimitReport.readings)
  end

  test "with no token, the stored gh login is named as such and no login is guessed" do
    ENV.delete("GH_TOKEN")
    open_rate_limit_breaker("core", @now + 12.minutes)

    reading = GithubRateLimitReport.readings.sole
    assert_equal "the stored gh login", reading.credential
    assert_nil reading.login
  end

  test "cached_login reads only the cache, and ignores a probe that failed" do
    assert_nil GithubTokenStatus.cached_login(TEST_GH_TOKEN)
    remember_github_login("tadasant")
    assert_equal "tadasant", GithubTokenStatus.cached_login(TEST_GH_TOKEN)

    Rails.cache.write(GithubTokenStatus.cache_key(TEST_GH_TOKEN), GithubTokenStatus::Probe.new(error: "GitHub answered HTTP 401"))
    assert_nil GithubTokenStatus.cached_login(TEST_GH_TOKEN)
    assert_nil GithubTokenStatus.cached_login(nil)
  end
end
