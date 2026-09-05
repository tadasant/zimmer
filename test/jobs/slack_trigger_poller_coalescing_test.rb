# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"
require "ostruct"

# Coalescing a burst of Slack messages into ONE session.
#
# The defect this covers: on 2026-08-29 a single MCP `bulk_archive` posted seven
# alerts to `#alerts` in three seconds, and the `#alerts` → router trigger spawned
# seven sessions in nine seconds. Six of them archived within three minutes having
# worked out they were duplicates (tadasant/tadasant-internal#1857).
#
# Both directions are asserted here, deliberately, because only one of them
# announces itself when it is wrong. A burst that still fans out is visible in the
# session list; a window that swallows a genuinely distinct alert produces
# SILENCE, and nothing responds to it. So every "one session" test below has a
# "still two sessions" twin.
class SlackTriggerPollerCoalescingTest < ActiveJob::TestCase
  CHANNEL = "C0A6BF8T45R"

  # A plausible burst: the seven alerts of the incident, half a second apart.
  BURST_ANCHOR = 1_756_500_000.0

  setup do
    SlackService.stubs(:configured?).returns(true)
    SlackService.stubs(:get_user_name).returns("Obs Alerts")
    SlackService.stubs(:get_message_permalink).returns(nil)
    AgentRootsConfig.stubs(:find!).returns(
      OpenStruct.new(url: "https://github.com/test/repo", default_branch: "main", subdirectory: nil)
    )
    AgentSessionJob.stubs(:enqueue_new_session)

    @trigger = triggers(:enabled_slack_trigger)
    @condition = trigger_conditions(:enabled_slack_condition)
  end

  teardown { Mocha::Mockery.instance.teardown }

  # --- the burst ----------------------------------------------------------

  test "seven alerts three seconds apart produce ONE session, not seven" do
    deliver(burst(7, spacing: 0.5))

    assert_difference("Session.count", 1) do
      SlackTriggerPollerJob.new.send(:process_condition, @condition)
    end
  end

  test "the messages folded into the surviving session are carried in its prompt" do
    messages = burst(3, spacing: 0.5)
    deliver(messages)

    SlackTriggerPollerJob.new.send(:process_condition, @condition)

    prompt = Session.order(:id).last.prompt

    # The head of the burst is what the template was rendered from.
    assert_includes prompt, "https://slack.example/#{messages.first.ts}"

    # The two that did not get their own session are named, with their links, so
    # the one session that survived knows about every event it stands in for.
    assert_includes prompt, "2 more messages landed"
    messages.drop(1).each do |folded|
      assert_includes prompt, "https://slack.example/#{folded.ts}"
      assert_includes prompt, folded.text
    end
  end

  test "every message of a burst is still recorded against the surviving session" do
    # Coalescing decides how many SESSIONS a burst produces. It must not decide
    # whose words are on the record — without this the second and later messages
    # of a burst would lose their human author entirely.
    users(:tadasant).update!(slack_user_ids: [ "U_ALERTS" ])
    messages = burst(4, spacing: 0.5)
    deliver(messages)

    assert_difference("HumanMessage.count", 4) do
      assert_difference("Session.count", 1) do
        SlackTriggerPollerJob.new.send(:process_condition, @condition)
      end
    end

    session = Session.order(:id).last
    recorded = HumanMessage.where(session: session).order(:occurred_at)
    assert_equal messages.map(&:text), recorded.map(&:content)
  end

  test "the cursor still advances past every message in a coalesced burst" do
    messages = burst(5, spacing: 0.5)
    deliver(messages)

    SlackTriggerPollerJob.new.send(:process_condition, @condition)

    assert_equal messages.last.ts, @condition.reload.last_message_ts
  end

  # --- what must NOT be coalesced -----------------------------------------

  test "two messages further apart than the window are two events and two sessions" do
    deliver([ message_at(BURST_ANCHOR, "alert one"), message_at(BURST_ANCHOR + 300, "alert two") ])

    assert_difference("Session.count", 2) do
      SlackTriggerPollerJob.new.send(:process_condition, @condition)
    end
  end

  test "a group is anchored on its first message, so a steady trickle does not chain into one" do
    # 60s window. Chaining off the previous message would make these four one
    # group spanning 150 seconds; anchoring bounds each group to the window.
    deliver([
      message_at(BURST_ANCHOR, "one"),
      message_at(BURST_ANCHOR + 50, "two"),
      message_at(BURST_ANCHOR + 100, "three"),
      message_at(BURST_ANCHOR + 150, "four")
    ])

    assert_difference("Session.count", 2) do
      SlackTriggerPollerJob.new.send(:process_condition, @condition)
    end
  end

  test "simultaneous messages in two different channels are never each other's duplicates" do
    other_trigger = Trigger.create!(
      name: "Other Channel Handler",
      agent_root_name: @trigger.agent_root_name,
      prompt_template: "There is a new message in Slack, channel {{channel}}.",
      status: "enabled",
      trigger_conditions_attributes: [
        { condition_type: "slack", configuration: { "channel_id" => "C_OTHER", "channel_name" => "other", "event_type" => "new_message" } }
      ]
    )
    other_condition = other_trigger.trigger_conditions.first
    other_condition.update!(last_message_ts: "1704067200.000000")

    here = [ message_at(BURST_ANCHOR, "alert in this channel") ]
    there = [ message_at(BURST_ANCHOR, "alert in that channel") ]
    SlackService.stubs(:get_messages_since).with(CHANNEL, since_ts: @condition.last_message_ts).returns(here)
    SlackService.stubs(:get_messages_since).with("C_OTHER", since_ts: other_condition.last_message_ts).returns(there)
    stub_permalinks(here + there)

    job = SlackTriggerPollerJob.new

    assert_difference("Session.count", 2) do
      job.send(:process_condition, @condition)
      job.send(:process_condition, other_condition)
    end
  end

  test "two different people posting seconds apart are two requests, not one burst" do
    # The correlation key includes the author on purpose. Two people @mentioning
    # Zimmer in the same minute are asking two things; folding the second into the
    # first would render the prompt from the first person's words and leave the
    # second as an excerpt in a note their trigger's template never anticipated.
    deliver([
      message_at(BURST_ANCHOR, "please look at the deploy", user: "U_ALICE"),
      message_at(BURST_ANCHOR + 5, "unrelated: the docs build is red", user: "U_BOB")
    ])

    assert_difference("Session.count", 2) do
      SlackTriggerPollerJob.new.send(:process_condition, @condition)
    end
  end

  test "an app that posts without a user id still coalesces, keyed on its bot id" do
    # An alerting app posting through a webhook carries `bot_id` and no `user`.
    # That is the incident's own shape, so it has to be a correlation key.
    deliver([
      message_at(BURST_ANCHOR, "alert 1", user: nil, bot_id: "B_OBS"),
      message_at(BURST_ANCHOR + 1, "alert 2", user: nil, bot_id: "B_OBS")
    ])

    assert_difference("Session.count", 1) do
      SlackTriggerPollerJob.new.send(:process_condition, @condition)
    end
  end

  test "two apps alerting at the same moment are two events" do
    deliver([
      message_at(BURST_ANCHOR, "disk is full", user: nil, bot_id: "B_OBS"),
      message_at(BURST_ANCHOR + 1, "build failed", user: nil, bot_id: "B_CI")
    ])

    assert_difference("Session.count", 2) do
      SlackTriggerPollerJob.new.send(:process_condition, @condition)
    end
  end

  test "a message Slack attributes to nobody is never folded into another" do
    # No identity is no evidence that two messages share a producer, and the safe
    # direction is a session too many rather than an alert nothing answers.
    deliver([
      message_at(BURST_ANCHOR, "legacy webhook one", user: nil),
      message_at(BURST_ANCHOR + 1, "legacy webhook two", user: nil)
    ])

    assert_difference("Session.count", 2) do
      SlackTriggerPollerJob.new.send(:process_condition, @condition)
    end
  end

  test "a window of 0 turns coalescing off and gives every message its own session" do
    @trigger.update!(coalesce_window_seconds: 0)
    deliver(burst(3, spacing: 0.5))

    assert_difference("Session.count", 3) do
      SlackTriggerPollerJob.new.send(:process_condition, @condition)
    end
  end

  # --- the window itself ---------------------------------------------------

  test "a wider window set on the trigger coalesces messages the default would not" do
    @trigger.update!(coalesce_window_seconds: 600)
    deliver([ message_at(BURST_ANCHOR, "alert one"), message_at(BURST_ANCHOR + 300, "alert two") ])

    assert_difference("Session.count", 1) do
      SlackTriggerPollerJob.new.send(:process_condition, @condition)
    end
  end

  test "a single message is never given a folding note" do
    deliver([ message_at(BURST_ANCHOR, "the only alert") ])

    SlackTriggerPollerJob.new.send(:process_condition, @condition)

    assert_not_includes Session.order(:id).last.prompt, "folded"
  end

  test "grouping does not depend on the order Slack returned the messages in" do
    messages = burst(3, spacing: 0.5)
    deliver(messages.reverse)

    assert_difference("Session.count", 1) do
      SlackTriggerPollerJob.new.send(:process_condition, @condition)
    end

    # The OLDEST message heads the group: it is the one a router should treat as
    # the start of the burst, whatever order the fetch came back in.
    assert_includes Session.order(:id).last.prompt, "https://slack.example/#{messages.first.ts}"
  end

  private

  def burst(count, spacing:)
    Array.new(count) { |i| message_at(BURST_ANCHOR + (i * spacing), "[production] alert #{i + 1}") }
  end

  def message_at(epoch, text, user: "U_ALERTS", bot_id: nil)
    OpenStruct.new(
      ts: format("%.6f", epoch),
      text: text,
      bot_id: bot_id,
      thread_ts: nil,
      user: user,
      username: nil
    )
  end

  def deliver(messages)
    SlackService.stubs(:get_messages_since).returns(messages)
    stub_permalinks(messages)
  end

  def stub_permalinks(messages)
    messages.each do |message|
      SlackService.stubs(:get_message_permalink)
        .with(anything, message.ts)
        .returns("https://slack.example/#{message.ts}")
    end
  end
end
