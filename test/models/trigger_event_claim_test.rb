# frozen_string_literal: true

require "test_helper"

class TriggerEventClaimTest < ActiveSupport::TestCase
  setup do
    @condition = trigger_conditions(:enabled_slack_condition)
    @other = trigger_conditions(:new_slack_condition)
  end

  test "a claim is won once per condition and event, and lost every time after" do
    assert_equal %w[slack:C1:1.000001], TriggerEventClaim.claim!(@condition, %w[slack:C1:1.000001], via: "webhook")
    assert_empty TriggerEventClaim.claim!(@condition, %w[slack:C1:1.000001], via: "poll")
  end

  test "a claim returns only the keys this call won when some were already taken" do
    TriggerEventClaim.claim!(@condition, %w[slack:C1:2.000001], via: "webhook")

    won = TriggerEventClaim.claim!(@condition, %w[slack:C1:1.000001 slack:C1:2.000001 slack:C1:3.000001], via: "poll")

    assert_equal %w[slack:C1:1.000001 slack:C1:3.000001], won.sort
  end

  test "two conditions each claim the same event, as two triggers each fire on one message" do
    assert_equal 1, TriggerEventClaim.claim!(@condition, %w[slack:C1:1.000001], via: "poll").size
    assert_equal 1, TriggerEventClaim.claim!(@other, %w[slack:C1:1.000001], via: "poll").size
  end

  test "an open group is one anchored within the window before the message and holding a session" do
    session = sessions(:running)
    TriggerEventClaim.claim!(@condition, %w[slack:C1:100.000000], via: "webhook",
                             group_key: "slack:C1:U1", anchor_ts: "100.000000", session_id: session.id)

    assert_equal session.id, TriggerEventClaim.open_group(@condition, "slack:C1:U1", "159.000000", 60)&.session_id
    assert_nil TriggerEventClaim.open_group(@condition, "slack:C1:U1", "161.000000", 60), "past the window"
    assert_nil TriggerEventClaim.open_group(@condition, "slack:C1:U2", "101.000000", 60), "another author"
    assert_nil TriggerEventClaim.open_group(@condition, "slack:C1:U1", "101.000000", 0), "coalescing off"
  end

  test "a group whose fire spawned nothing is not open" do
    TriggerEventClaim.claim!(@condition, %w[slack:C1:100.000000], via: "webhook", group_key: "slack:C1:U1", anchor_ts: "100.000000")

    assert_nil TriggerEventClaim.open_group(@condition, "slack:C1:U1", "101.000000", 60)
  end

  test "deleting a condition deletes its claims" do
    TriggerEventClaim.claim!(@condition, %w[slack:C1:1.000001], via: "poll")

    assert_difference -> { TriggerEventClaim.count }, -1 do
      @condition.destroy!
    end
  end
end
