# frozen_string_literal: true

require "test_helper"

class InboundEventRetentionJobTest < ActiveJob::TestCase
  setup { @condition = trigger_conditions(:enabled_slack_condition) }

  test "deletes deliveries and claims past their retention and keeps everything inside it" do
    now = Time.current
    WebhookDelivery.record_first!(source: "slack", delivery_id: "Ev_old", now: now - WebhookDelivery::RETENTION - 1.hour)
    WebhookDelivery.record_first!(source: "slack", delivery_id: "Ev_new", now: now - 1.hour)
    TriggerEventClaim.claim!(@condition, %w[slack:C1:1.000001], via: "poll", now: now - TriggerEventClaim::RETENTION - 1.hour)
    TriggerEventClaim.claim!(@condition, %w[slack:C1:2.000001], via: "poll", now: now - 8.days)

    result = InboundEventRetentionJob.perform_now(now: now)

    assert_equal({ deliveries: 1, claims: 1, shadow_observations: 0, github_pr_signals: 0 }, result)
    assert_equal %w[Ev_new], WebhookDelivery.pluck(:delivery_id)
    assert_equal %w[slack:C1:2.000001], TriggerEventClaim.pluck(:event_key)
  end

  test "deletes shadow observations past their retention" do
    condition = trigger_conditions(:github_issue_condition)
    now = Time.current
    TriggerShadowObservation.record!(condition, "github:r#1:opened", path: "poll", now: now - TriggerShadowObservation::RETENTION - 1.hour)
    TriggerShadowObservation.record!(condition, "github:r#2:opened", path: "poll", now: now - 1.day)

    assert_equal 1, InboundEventRetentionJob.perform_now(now: now)[:shadow_observations]
    assert_equal %w[github:r#2:opened], TriggerShadowObservation.pluck(:event_key)
  end

  test "deletes GitHub PR signals nobody has repeated for a day" do
    now = Time.current
    GithubPrSignal.signal!([ %w[tadasant/zimmer delivery] ], at: now - GithubPrSignal::RETENTION - 1.hour)
    GithubPrSignal.signal!([ [ "https://github.com/tadasant/zimmer/pull/1", "status" ] ], at: now - 1.hour)

    assert_equal 1, InboundEventRetentionJob.perform_now(now: now)[:github_pr_signals]
    assert_equal %w[status], GithubPrSignal.pluck(:kind)
  end

  test "a second run deletes nothing" do
    WebhookDelivery.record_first!(source: "slack", delivery_id: "Ev_old", now: 30.days.ago)

    InboundEventRetentionJob.perform_now

    assert_equal({ deliveries: 0, claims: 0, shadow_observations: 0, github_pr_signals: 0 }, InboundEventRetentionJob.perform_now)
  end

  test "a backlog bigger than one batch drains in one run" do
    stub_const(InboundEventRetentionJob, :BATCH_SIZE, 2) do
      5.times { |i| WebhookDelivery.record_first!(source: "slack", delivery_id: "Ev#{i}", now: 30.days.ago) }

      assert_equal 5, InboundEventRetentionJob.perform_now[:deliveries]
    end
  end

  private

  def stub_const(klass, name, value)
    original = klass.const_get(name)
    klass.send(:remove_const, name)
    klass.const_set(name, value)
    yield
  ensure
    klass.send(:remove_const, name)
    klass.const_set(name, original)
  end
end
