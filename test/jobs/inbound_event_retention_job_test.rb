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

    assert_equal({ deliveries: 1, claims: 1 }, result)
    assert_equal %w[Ev_new], WebhookDelivery.pluck(:delivery_id)
    assert_equal %w[slack:C1:2.000001], TriggerEventClaim.pluck(:event_key)
  end

  test "a second run deletes nothing" do
    WebhookDelivery.record_first!(source: "slack", delivery_id: "Ev_old", now: 30.days.ago)

    InboundEventRetentionJob.perform_now

    assert_equal({ deliveries: 0, claims: 0 }, InboundEventRetentionJob.perform_now)
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
