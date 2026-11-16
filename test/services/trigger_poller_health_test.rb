# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"

# The Trigger Polling section of the health report: the same pollers, heartbeats and
# thresholds TriggerPollerLivenessCheckJob pages on, plus spent GitHub budgets, so a stall
# and a rate-limited pause read as different things.
class TriggerPollerHealthTest < ActiveSupport::TestCase
  include GithubRateLimitStateHelpers

  setup do
    @original_cache = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
    use_test_gh_token
    @now = Time.zone.parse("2026-11-15T21:15:00Z")
    travel_to @now
    # Only GitHub is watched; the github_label_trigger fixture is enabled.
    TriggerCondition.where.not(condition_type: TriggerCondition::GITHUB_CONDITION_TYPES).delete_all
    # `seedable` is `gh auth status`, a live call. This surface must never make it.
    GithubSearchService.expects(:configured?).never
  end

  teardown do
    travel_back
    Rails.cache = @original_cache
    restore_gh_tokens
  end

  def stamp_github(at) = Rails.cache.write(PollerHeartbeat.cache_key(:github), at.utc.iso8601)
  def github_row(report) = report[:pollers].find { |p| p[:key] == "github" }

  test "a fresh heartbeat with nothing spent is polling and healthy" do
    stamp_github(@now - 1.minute)
    report = TriggerPollerHealth.report

    assert_equal "polling", github_row(report)[:state]
    assert_equal :healthy, report[:status].status
    assert_empty report[:github_rate_limit]
  end

  test "a stale heartbeat with nothing known spent is a plain stall, pointing at the worker" do
    stamp_github(@now - 20.minutes)
    report = TriggerPollerHealth.report
    row = github_row(report)

    assert_equal "stalled", row[:state]
    assert_includes row[:message], "GitHub trigger polling stalled: no successful poll in ~20 min (pages past 15 min)."
    assert_includes row[:message], "No GitHub budget is known to be spent"
    assert_equal :critical, report[:status].status
  end

  test "a spent search budget under the threshold reads as rate-limited, with whose budget and when it resets" do
    stamp_github(@now - 3.minutes)
    remember_github_login("tadasant")
    write_rate_limit_snapshot("core" => [ 0, 5000, @now + 12.minutes ], "search" => [ 0, 30, @now + 40.seconds ])

    report = TriggerPollerHealth.report
    row = github_row(report)

    assert_equal "rate_limited", row[:state]
    assert_equal "GitHub trigger polling is paused: GH_TOKEN (tadasant)'s GitHub search budget is spent until " \
                 "2026-11-15 21:15 UTC (in under a minute); last poll 3m ago.", row[:message]
    assert_equal :warning, report[:status].status
    assert_equal %w[core search].sort, report[:github_rate_limit].map { |r| r[:resource] }.sort
    assert report[:github_rate_limit].all? { |r| r[:trigger_polling] == "paused" }
  end

  test "past the threshold a stall stays a critical stall, even with the search budget spent right now" do
    stamp_github(@now - 40.minutes)
    write_rate_limit_snapshot("search" => [ 0, 30, @now + 40.seconds ])

    report = TriggerPollerHealth.report
    row = github_row(report)

    assert_equal "stalled", row[:state]
    assert_includes row[:message], "its window is a minute long, so it does not explain the stall alone"
    assert_equal :critical, report[:status].status
  end

  test "one token's spent search budget does not mark the whole GitHub poller paused" do
    ENV["GH_TOKEN__ACME"] = "ghp_acme_token_for_tests"
    acme = GithubRateLimit.credentials.find { |c| c[:label] == "GH_TOKEN__ACME" }
    Rails.cache.write(GithubRateLimit.exhausted_key(acme, "search"), (@now + 40.seconds).to_i)
    stamp_github(@now - 1.minute)

    report = TriggerPollerHealth.report

    assert_equal "polling", github_row(report)[:state]
    assert_equal [ "GH_TOKEN__ACME" ], report[:github_rate_limit].map { |r| r[:credential] }
    assert_equal :warning, report[:status].status

    open_rate_limit_breaker("search", @now + 40.seconds)
    assert_equal "rate_limited", github_row(TriggerPollerHealth.report)[:state], "every token's search spent pauses it"
  end

  test "a spent core budget with a fresh heartbeat warns, and says polling continues" do
    stamp_github(@now - 1.minute)
    write_rate_limit_snapshot("core" => [ 0, 5000, @now + 12.minutes ], "search" => [ 29, 30, @now + 40.seconds ])

    report = TriggerPollerHealth.report

    assert_equal "polling", github_row(report)[:state]
    assert_equal :warning, report[:status].status
    assert_includes report[:status].message, "GitHub trigger polling continues through it"
    assert_includes report[:status].message, "resets 2026-11-15 21:27 UTC (in 12 min)"
  end

  test "a stall beside a spent core budget stays a stall, and says the budget is not the cause" do
    stamp_github(@now - 20.minutes)
    write_rate_limit_snapshot("core" => [ 0, 5000, @now + 12.minutes ], "search" => [ 29, 30, @now + 40.seconds ])

    row = github_row(TriggerPollerHealth.report)

    assert_equal "stalled", row[:state]
    assert_includes row[:message], "A spent core budget does not stop the sweep, which spends only search."
  end

  test "a stall beside a spent core budget says it is not the cause even with no search reading" do
    stamp_github(@now - 20.minutes)
    open_rate_limit_breaker("core", @now + 12.minutes)

    assert_includes github_row(TriggerPollerHealth.report)[:message], "A spent core budget does not stop the sweep"
  end

  test "the health report carries the section, and a section that raises degrades to a warning" do
    stamp_github(@now - 1.minute)
    assert_equal "polling", github_row(HealthMonitorService.new.send(:trigger_poller_health))[:state]

    TriggerPollerHealth.stubs(:report).raises(RuntimeError, "boom")
    degraded = HealthMonitorService.new.send(:trigger_poller_health)
    assert_equal :warning, degraded[:status].status
    assert_empty degraded[:pollers]
  end
end
