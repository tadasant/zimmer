# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"

# Which delivered Slack events fire which conditions. Every rule here is the poller's rule for
# the same condition shape; the comments name the poller method each one mirrors.
class SlackEventJobTest < ActiveJob::TestCase
  include SlackWebhookTestHelpers

  setup { setup_slack_webhook }
  teardown { teardown_slack_webhook }

  def run_event(event, event_id: "Ev#{SecureRandom.hex(4)}")
    SlackEventJob.perform_now(event_id, SlackEventJob.event_arguments(event))
  end

  def fires(event)
    before = Session.count
    run_event(event)
    Session.count - before
  end

  def mention(text = "can you look at this")
    "<@#{BOT_ID}> #{text}"
  end

  # --- new_message (#process_new_message_condition) ----------------------------------

  test "new_message fires on a top-level message in its channel, bots included" do
    assert_equal 1, fires(slack_event(ts: "1756500000.000100"))
    assert_equal 1, fires(slack_event(ts: "1756500900.000100", user: nil, bot_id: "B_CI", username: "CI"))
  end

  test "new_message does not fire on a thread reply in its channel" do
    assert_equal 0, fires(slack_event(ts: "1756500000.000200", thread_ts: "1756400000.000100"))
  end

  test "thread-scoped new_message fires on a reply in its thread and nothing else" do
    configure_condition("channel_id" => CHANNEL, "channel_name" => "eng-ci", "event_type" => "new_message",
                        "thread_ts" => "1756400000.000100")

    assert_equal 1, fires(slack_event(ts: "1756500000.000200", thread_ts: "1756400000.000100"))
    assert_equal 0, fires(slack_event(ts: "1756500900.000200", thread_ts: "1756400999.000100"))
    assert_equal 0, fires(slack_event(ts: "1756501800.000100"))
  end

  test "an edit, a delete or a hidden event is never a new message" do
    %w[message_changed message_deleted message_replied].each_with_index do |subtype, i|
      assert_equal 0, fires(slack_event(ts: "175650000#{i}.000100", subtype: subtype)), subtype
    end
    assert_equal 0, fires(slack_event(ts: "1756500005.000100", hidden: true))
  end

  # --- bot_mention (#process_*_mentions, #process_dm_messages) -------------------------

  test "bot_mention fires on a mention from an allowed user and not on a message without one" do
    configure_condition("channel_id" => CHANNEL, "event_type" => "bot_mention", "allowed_user_ids" => [ "U_ALICE" ])

    assert_equal 0, fires(slack_event(ts: "1756500000.000100", text: "no mention here"))
    assert_equal 1, fires(slack_event(ts: "1756500900.000100", text: mention))
  end

  test "bot_mention ignores a mention from someone outside the allow-list" do
    configure_condition("channel_id" => CHANNEL, "event_type" => "bot_mention", "allowed_user_ids" => [ "U_ALICE" ])

    assert_equal 0, fires(slack_event(ts: "1756500000.000100", text: mention, user: "U_MALLORY"))
  end

  test "bot_mention never fires on the bot's own message" do
    configure_condition("channel_id" => CHANNEL, "event_type" => "bot_mention", "allowed_user_ids" => [ BOT_ID ])

    assert_equal 0, fires(slack_event(ts: "1756500000.000100", text: mention, user: BOT_ID))
  end

  test "bot_mention fires on a mention in a thread reply" do
    configure_condition("channel_id" => CHANNEL, "event_type" => "bot_mention", "allowed_user_ids" => [ "U_ALICE" ])

    assert_equal 1, fires(slack_event(ts: "1756500000.000200", thread_ts: "1756400000.000100", text: mention))
  end

  test "an all-channel bot_mention fires in any channel the bot hears from" do
    configure_condition("event_type" => "bot_mention", "allowed_user_ids" => [ "U_ALICE" ])

    assert_equal 1, fires(slack_event(ts: "1756500000.000100", channel: "C_OTHER", text: mention))
    assert_equal 1, fires(slack_event(ts: "1756500900.000100", channel: "G_PRIVATE", channel_type: "group", text: mention))
  end

  test "a group DM is not a channel the poller reads, so it does not fire" do
    configure_condition("event_type" => "bot_mention", "allowed_user_ids" => [ "U_ALICE" ])

    assert_equal 0, fires(slack_event(ts: "1756500000.000100", channel: "G_MPIM", channel_type: "mpim", text: mention))
  end

  test "bot_mention fires on any DM from an allowed user, with no mention required" do
    configure_condition("channel_id" => CHANNEL, "event_type" => "bot_mention", "allowed_user_ids" => [ "U_ALICE" ])

    assert_equal 1, fires(slack_event(ts: "1756500000.000100", channel: "D_ALICE", channel_type: "im", text: "hi"))
    assert_equal 0, fires(slack_event(ts: "1756500900.000100", channel: "D_MAL", channel_type: "im", text: "hi", user: "U_MALLORY"))
  end

  test "thread-scoped bot_mention fires on mentions in its thread only" do
    configure_condition("channel_id" => CHANNEL, "event_type" => "bot_mention", "thread_ts" => "1756400000.000100",
                        "allowed_user_ids" => [ "U_ALICE" ])

    assert_equal 1, fires(slack_event(ts: "1756500000.000200", thread_ts: "1756400000.000100", text: mention))
    assert_equal 0, fires(slack_event(ts: "1756500900.000100", text: mention))
    assert_equal 0, fires(slack_event(ts: "1756501800.000100", channel: "D_ALICE", channel_type: "im", text: "hi"))
  end

  # --- dm_message (#process_dm_message_condition) ---------------------------------------

  test "dm_message fires on a DM and never on a channel message" do
    configure_condition("event_type" => "dm_message", "allowed_user_ids" => [ "U_ALICE" ])

    assert_equal 1, fires(slack_event(ts: "1756500000.000100", channel: "D_ALICE", channel_type: "im"))
    assert_equal 0, fires(slack_event(ts: "1756500900.000100", text: mention))
    assert_equal 0, fires(slack_event(ts: "1756501800.000100", channel: "D_ALICE", channel_type: "im", user: BOT_ID))
  end

  # --- what the webhook leaves to the poller --------------------------------------------

  test "passive-listening conditions are never fired from a delivery" do
    TriggerCondition::PASSIVE_EVENT_TYPES.each_with_index do |event_type, i|
      configure_condition("channel_id" => CHANNEL, "event_type" => event_type, "allowed_user_ids" => [ "U_ALICE" ])

      assert_equal 0, fires(slack_event(ts: "175650000#{i}.000100")), event_type
    end
  end

  test "a delivery never moves the poller's cursor" do
    before = @condition.last_message_ts

    run_event(slack_event(ts: "1756500000.000100"))

    assert_equal before, @condition.reload.last_message_ts
  end

  test "a job that runs after Slack was switched back to poll fires nothing" do
    ENV["SLACK_TRIGGER_INGEST_MODE"] = "poll"

    assert_equal 0, fires(slack_event(ts: "1756500000.000100"))
  end

  # --- failure and folding ------------------------------------------------------------

  test "a fire that raises rolls its claim back, so the poller can still fire the message" do
    Trigger.any_instance.stubs(:create_session!).raises(RuntimeError, "spawn exploded")

    assert_nothing_raised { run_event(slack_event(ts: "1756500000.000100")) }
    assert_equal 0, TriggerEventClaim.count

    Trigger.any_instance.unstub(:create_session!)
    assert_difference -> { Session.count }, 1 do
      poll_channel([ polled_message(ts: "1756500000.000100") ])
    end
  end

  test "a burst whose session has already been archived opens a new session instead of folding" do
    run_event(slack_event(ts: "1756500000.000100", user: "U_ALERTS"))
    Session.order(:id).last.update_columns(status: "archived")

    assert_equal 1, fires(slack_event(ts: "1756500000.600100", user: "U_ALERTS"))
  end

  test "a burst's folded message is queued for the session and recorded against it" do
    users(:tadasant).update!(slack_user_ids: [ "U_ALERTS" ])

    run_event(slack_event(ts: "1756500000.000100", user: "U_ALERTS", text: "alert 1"))
    session = Session.order(:id).last

    assert_difference -> { HumanMessage.where(session: session).count }, 1 do
      assert_equal 0, fires(slack_event(ts: "1756500000.600100", user: "U_ALERTS", text: "alert 2"))
    end

    queued = session.enqueued_messages.sole
    assert_equal "pending", queued.status
    assert_includes queued.content, "alert 2"
    assert_includes queued.content, "#eng-ci"
  end
end
