# frozen_string_literal: true

require "test_helper"

class Webhooks::GithubShadowComparisonTest < ActiveSupport::TestCase
  setup do
    @now = Time.zone.parse("2026-11-16 12:00:00")
    @issue = trigger_conditions(:github_issue_condition)
    @label = trigger_conditions(:github_label_condition)
    @saved = ENV.slice("GITHUB_TRIGGER_POLL_INTERVAL_MINUTES")
    ENV.delete("GITHUB_TRIGGER_POLL_INTERVAL_MINUTES")
  end

  teardown { ENV["GITHUB_TRIGGER_POLL_INTERVAL_MINUTES"] = @saved["GITHUB_TRIGGER_POLL_INTERVAL_MINUTES"] }

  def observe(condition, key, path, ago)
    TriggerShadowObservation.record!(condition, key, path: path, delivery_id: (path == "webhook" ? SecureRandom.uuid : nil), now: @now - ago)
  end

  def report(**options)
    Webhooks::GithubShadowComparison.report(now: @now, **options)
  end

  test "classifies matched, webhook-only, poll-only and pending, and measures the webhook's lead" do
    observe(@issue, "github:r#1:opened", "webhook", 2.hours)
    observe(@issue, "github:r#1:opened", "poll", 2.hours - 50.seconds)
    observe(@issue, "github:r#2:opened", "webhook", 3.hours)
    observe(@issue, "github:r#3:opened", "poll", 3.hours)
    observe(@issue, "github:r#4:opened", "webhook", 5.minutes)
    observe(@label, "github:r#5:label:x", "webhook", 1.hour)
    observe(@label, "github:r#5:label:x", "poll", 1.hour - 10.seconds)

    result = report

    assert_equal({ matched: 2, webhook_only: 1, poll_only: 1, pending: 1 }, result[:totals])
    assert_equal({ samples: 2, median_seconds: 10, p90_seconds: 50, max_seconds: 50 }, result[:latency])
    assert_equal 15.minutes.to_i, result[:grace_seconds]

    rows = result[:conditions].index_by { |row| row[:condition_id] }
    assert_equal({ matched: 1, webhook_only: 1, poll_only: 1, pending: 1 }, rows[@issue.id][:counts])
    assert_equal({ matched: 1, webhook_only: 0, poll_only: 0, pending: 0 }, rows[@label.id][:counts])
    assert_equal "github_label", rows[@label.id][:condition_type]
    assert_equal @label.trigger.name, rows[@label.id][:trigger_name]

    assert_equal %w[pending matched matched webhook_only poll_only].sort, result[:recent].map { |e| e[:status] }.sort
    assert_equal "github:r#4:opened", result[:recent].first[:event]
  end

  test "a poller ahead of the webhook reads as a negative lead" do
    observe(@issue, "github:r#1:opened", "poll", 1.hour)
    observe(@issue, "github:r#1:opened", "webhook", 1.hour - 30.seconds)

    assert_equal(-30, report[:latency][:median_seconds])
  end

  test "the same key twice pairs in time order, so a re-added label is two events" do
    observe(@label, "github:r#9:label:x", "webhook", 3.hours)
    observe(@label, "github:r#9:label:x", "poll", 3.hours - 60.seconds)
    observe(@label, "github:r#9:label:x", "webhook", 1.hour)

    assert_equal({ matched: 1, webhook_only: 1, poll_only: 0, pending: 0 }, report[:totals])
    assert_equal [ 60 ], [ report[:latency][:median_seconds] ]
  end

  test "a second delivery for an event the webhook already saw folds into it" do
    # `issues.opened` carrying the label, then `issues.labeled` for it: two webhook rows, one event.
    observe(@label, "github:r#9:label:x", "webhook", 2.hours)
    observe(@label, "github:r#9:label:x", "webhook", 2.hours - 1.second)
    observe(@label, "github:r#9:label:x", "poll", 2.hours - 50.seconds)

    assert_equal({ matched: 1, webhook_only: 0, poll_only: 0, pending: 0 }, report[:totals])
    assert_equal 50, report[:latency][:median_seconds]
  end

  test "one dropped delivery does not shift the pairs after it" do
    observe(@label, "github:r#9:label:x", "poll", 5.hours)
    observe(@label, "github:r#9:label:x", "webhook", 2.hours)
    observe(@label, "github:r#9:label:x", "poll", 2.hours - 30.seconds)

    result = report
    assert_equal({ matched: 1, webhook_only: 0, poll_only: 1, pending: 0 }, result[:totals])
    assert_equal 30, result[:latency][:median_seconds]
  end

  test "an event that straddles the window's start pairs, and one wholly before it is not counted" do
    observe(@issue, "github:r#1:opened", "webhook", 24.hours + 30.seconds)
    observe(@issue, "github:r#1:opened", "poll", 24.hours - 30.seconds)
    observe(@issue, "github:r#2:opened", "webhook", 24.hours + 5.minutes)
    observe(@issue, "github:r#3:opened", "poll", 24.hours - 1.minute)
    observe(@issue, "github:r#3:opened", "webhook", 24.hours - 2.minutes)

    totals = report[:totals]
    assert_equal 0, totals[:webhook_only], "an event first seen before the window is not counted as a miss"
    assert_equal 1, totals[:matched], "r#3 is in the window and matched; r#1 started before it"
  end

  test "a longer poll interval widens the default grace" do
    ENV["GITHUB_TRIGGER_POLL_INTERVAL_MINUTES"] = "15"
    observe(@issue, "github:r#1:opened", "webhook", 20.minutes)

    result = report
    assert_equal 35.minutes.to_i, result[:grace_seconds]
    assert_equal 900, result[:poll_interval_seconds]
    assert_equal 1, result[:totals][:pending], "20 minutes is inside two 15-minute polls"
  end

  test "narrows to one condition, to a visible scope, and to unmatched events" do
    observe(@issue, "github:r#1:opened", "webhook", 1.hour)
    observe(@issue, "github:r#1:opened", "poll", 1.hour)
    observe(@label, "github:r#5:label:x", "poll", 1.hour)

    assert_equal [ @label.id ], report(condition_id: @label.id)[:conditions].map { |row| row[:condition_id] }
    assert_equal [ @issue.id ], report(conditions: TriggerCondition.where(id: @issue.id))[:conditions].map { |row| row[:condition_id] }
    assert_equal %w[poll_only], report(recent_unmatched: true)[:recent].map { |e| e[:status] }
  end

  test "nothing recorded is an empty reading" do
    result = report

    assert_equal({ matched: 0, webhook_only: 0, poll_only: 0, pending: 0 }, result[:totals])
    assert_equal 0, result[:latency][:samples]
    assert_empty result[:conditions]
  end
end
