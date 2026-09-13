# frozen_string_literal: true

require "test_helper"

class Webhooks::IngestSummaryTest < ActiveSupport::TestCase
  KEYS = %w[SLACK_TRIGGER_INGEST_MODE SLACK_SIGNING_SECRET].freeze

  setup do
    @saved = KEYS.to_h { |key| [ key, ENV[key] ] }
    KEYS.each { |key| ENV.delete(key) }
    WebhookDelivery.delete_all
    TriggerEventClaim.delete_all
    @condition = trigger_conditions(:enabled_slack_condition)
    @now = Time.current
  end

  teardown do
    @saved.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
  end

  def switch_webhook_on(secret: "s3cret")
    ENV["SLACK_TRIGGER_INGEST_MODE"] = "webhook_with_poll_fallback"
    ENV["SLACK_SIGNING_SECRET"] = secret if secret
  end

  def deliver(id, at:)
    WebhookDelivery.record_first!(source: "slack", delivery_id: id, event_type: "message", now: at)
  end

  def claim(ts, via:, at:, condition: @condition)
    TriggerEventClaim.claim!(condition, [ TriggerEventClaim.slack_event_key("C1", ts) ], via: via, now: at)
  end

  def slack(report)
    report[:sources].find { |s| s[:name] == "slack" }
  end

  test "with nothing configured every source polls and the reading is healthy" do
    report = Webhooks::IngestSummary.report(now: @now)

    assert_equal 24.hours.to_i, report[:window_seconds]
    assert_equal({ name: "slack", mode: "poll", webhook_enabled: false, accepting: false, last_delivery_at: nil,
                   deliveries_in_window: 0, webhook_claims_in_window: 0, poll_claims_in_window: 0 }, slack(report))
    assert_predicate report[:status], :healthy?
    assert_equal "Every source polls; no webhook is switched on", report[:status].message
  end

  test "counts deliveries and claims inside the window, and names the newest delivery even outside it" do
    switch_webhook_on
    deliver("Ev_old", at: @now - 3.days)
    deliver("Ev_1", at: @now - 2.hours)
    deliver("Ev_2", at: @now - 10.minutes)
    claim("1.0", via: "webhook", at: @now - 2.hours)
    claim("2.0", via: "webhook", at: @now - 10.minutes)
    claim("0.5", via: "poll", at: @now - 2.days)

    reading = slack(Webhooks::IngestSummary.report(now: @now))

    assert_equal "webhook_with_poll_fallback", reading[:mode]
    assert reading[:accepting]
    assert_in_delta (@now - 10.minutes).to_f, reading[:last_delivery_at].to_f, 1
    assert_equal 2, reading[:deliveries_in_window]
    assert_equal 2, reading[:webhook_claims_in_window]
    assert_equal 0, reading[:poll_claims_in_window], "a poll claim older than the window is not counted"
  end

  test "the last delivery is only looked for inside the delivery retention window" do
    switch_webhook_on
    deliver("Ev_ancient", at: @now - WebhookDelivery::RETENTION - 1.day)

    assert_nil slack(Webhooks::IngestSummary.report(now: @now))[:last_delivery_at]
  end

  test "a healthy webhook says when it last delivered and that the poller claimed nothing" do
    switch_webhook_on
    deliver("Ev_1", at: @now - 5.minutes)
    claim("1.0", via: "webhook", at: @now - 5.minutes)

    status = Webhooks::IngestSummary.report(now: @now)[:status]

    assert_predicate status, :healthy?
    assert_equal "slack: last delivery 5m ago; the webhook claimed 1 trigger event(s) in the last 24h, the poller none",
                 status.message
  end

  test "a poll claim while the webhook is on is a warning naming how many the webhook missed" do
    switch_webhook_on
    deliver("Ev_1", at: @now - 1.hour)
    claim("1.0", via: "webhook", at: @now - 1.hour)
    claim("2.0", via: "webhook", at: @now - 1.hour)
    claim("3.0", via: "poll", at: @now - 1.hour)

    report = Webhooks::IngestSummary.report(now: @now)

    assert_equal 1, slack(report)[:poll_claims_in_window]
    assert_predicate report[:status], :warning?
    assert_equal "slack: the poller claimed 1 of 3 trigger event(s) in the last 24h — events the webhook did not deliver first",
                 report[:status].message
  end

  # Passive listening is served only by the poller, which claims every one of its fires while the
  # webhook is on. Those claims are not misses, and counting them would keep the warning on forever.
  test "poll claims on a condition the webhook does not serve are not counted" do
    switch_webhook_on
    deliver("Ev_1", at: @now - 1.hour)
    passive = trigger_conditions(:passive_listen_all_channels_condition)
    assert_equal "passive_listen_thread", passive.event_type
    claim("9.0", via: "poll", at: @now - 1.hour, condition: passive)
    claim("1.0", via: "webhook", at: @now - 1.hour)

    report = Webhooks::IngestSummary.report(now: @now)

    assert_equal 0, slack(report)[:poll_claims_in_window]
    assert_equal 1, slack(report)[:webhook_claims_in_window]
    assert_predicate report[:status], :healthy?
  end

  test "a condition with no event_type is a new_message condition, which the webhook serves" do
    switch_webhook_on
    deliver("Ev_1", at: @now - 1.hour)
    @condition.update_columns(configuration: @condition.configuration.except("event_type"))
    assert_equal "new_message", @condition.reload.event_type
    claim("3.0", via: "poll", at: @now - 1.hour)

    assert_equal 1, slack(Webhooks::IngestSummary.report(now: @now))[:poll_claims_in_window]
  end

  test "poll claims left from a webhook since switched off do not warn" do
    claim("3.0", via: "poll", at: @now - 1.hour)

    report = Webhooks::IngestSummary.report(now: @now)

    assert_equal 1, slack(report)[:poll_claims_in_window]
    assert_predicate report[:status], :healthy?
  end

  test "a webhook switched on with no signing secret is a warning, because its endpoint is inert" do
    switch_webhook_on(secret: nil)

    report = Webhooks::IngestSummary.report(now: @now)

    refute slack(report)[:accepting]
    assert_predicate report[:status], :warning?
    assert_equal "slack: webhook is switched on but has no signing secret, so its endpoint answers 404", report[:status].message
  end

  # Slack delivers every message in every channel the bot is in, matched or not, so a day with no
  # delivery at all while the endpoint is accepting means the provider is not reaching it.
  test "an accepting webhook that received nothing in the window is a warning" do
    switch_webhook_on
    deliver("Ev_old", at: @now - 2.days)

    report = Webhooks::IngestSummary.report(now: @now)

    assert_predicate report[:status], :warning?
    assert_equal "slack: webhook is accepting but received no delivery in the last 24h — check that the provider can reach its endpoint",
                 report[:status].message
  end

  test "a claim is attributed to its source by its event key prefix" do
    switch_webhook_on
    deliver("Ev_1", at: @now - 1.hour)
    TriggerEventClaim.claim!(@condition, [ "github:tadasant/zimmer#1" ], via: "poll", now: @now)

    report = Webhooks::IngestSummary.report(now: @now)

    assert_equal 0, slack(report)[:poll_claims_in_window]
    assert_predicate report[:status], :healthy?
  end
end
