# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"
require "ostruct"

class SlackTriggerPollerJobTest < ActiveJob::TestCase
  setup do
    @trigger = triggers(:enabled_slack_trigger)
    @condition = trigger_conditions(:enabled_slack_condition)
  end

  teardown do
    Mocha::Mockery.instance.teardown
  end

  test "job does nothing when Slack is not configured" do
    SlackService.stubs(:configured?).returns(false)
    # Should not raise and should not process any conditions
    assert_nothing_raised do
      SlackTriggerPollerJob.perform_now
    end
  end

  test "job skips conditions with blank channel_id" do
    SlackService.stubs(:configured?).returns(true)
    @condition.configuration = {}
    @condition.save!(validate: false)

    job = SlackTriggerPollerJob.new
    # Should return early without calling SlackService
    assert_nothing_raised do
      job.send(:process_condition, @condition)
    end
  end

  test "job establishes baseline on first poll" do
    SlackService.stubs(:configured?).returns(true)
    condition_without_ts = trigger_conditions(:new_slack_condition)
    condition_without_ts.update!(last_message_ts: nil)

    mock_messages = [
      OpenStruct.new(ts: "1704067200.000000", text: "First message")
    ]

    SlackService.stubs(:get_channel_history).returns(mock_messages)

    job = SlackTriggerPollerJob.new
    # fetch_new_messages takes (channel_id, last_ts)
    messages = job.send(:fetch_new_messages, condition_without_ts.channel_id, nil)

    # Should return the baseline messages (caller is responsible for not processing them)
    assert_equal 1, messages.length
    assert_equal "1704067200.000000", messages.first.ts
  end

  test "job does NOT filter out bot messages (bots like CI bots are valid trigger sources)" do
    SlackService.stubs(:configured?).returns(true)
    messages = [
      OpenStruct.new(ts: "1704067300.000000", text: "User message", bot_id: nil, thread_ts: nil),
      OpenStruct.new(ts: "1704067400.000000", text: "Bot message", bot_id: "B123", thread_ts: nil)
    ]

    SlackService.stubs(:get_messages_since).returns(messages)

    job = SlackTriggerPollerJob.new
    filtered = job.send(:fetch_new_messages, @condition.channel_id, @condition.last_message_ts)

    # Both messages should be included - bot messages are NOT filtered
    assert_equal 2, filtered.length
    assert_equal "User message", filtered[0].text
    assert_equal "Bot message", filtered[1].text
  end

  test "job filters out thread replies" do
    SlackService.stubs(:configured?).returns(true)
    messages = [
      OpenStruct.new(ts: "1704067300.000000", text: "Parent message", bot_id: nil, thread_ts: nil),
      OpenStruct.new(ts: "1704067400.000000", text: "Thread reply", bot_id: nil, thread_ts: "1704067300.000000")
    ]

    SlackService.stubs(:get_messages_since).returns(messages)

    job = SlackTriggerPollerJob.new
    filtered = job.send(:fetch_new_messages, @condition.channel_id, @condition.last_message_ts)

    assert_equal 1, filtered.length
    assert_equal "Parent message", filtered[0].text
  end

  test "bot_mention condition only processes messages containing bot mention from allowed users" do
    SlackService.stubs(:configured?).returns(true)
    SlackService.stubs(:bot_user_id).returns("U_BOT_123")
    SlackService.stubs(:list_dm_channels).returns([])

    condition = trigger_conditions(:bot_mention_slack_condition)
    # Ensure allowed_user_ids includes U222 so the mention is processed
    condition.configuration["allowed_user_ids"] = %w[U222]
    condition.save!

    messages = [
      OpenStruct.new(ts: "1704067300.000000", text: "Hello everyone", bot_id: nil, thread_ts: nil, user: "U111"),
      OpenStruct.new(ts: "1704067400.000000", text: "Hey <@U_BOT_123> can you help?", bot_id: nil, thread_ts: nil, user: "U222"),
      OpenStruct.new(ts: "1704067500.000000", text: "Just a regular message", bot_id: nil, thread_ts: nil, user: "U333")
    ]

    SlackService.stubs(:get_messages_since).returns(messages)
    SlackService.stubs(:get_message_permalink).returns("https://slack.com/msg/123")
    SlackService.stubs(:get_user_name).returns("Test User")

    mock_agent_root = OpenStruct.new(
      url: "https://github.com/test/repo",
      default_branch: "main",
      subdirectory: nil
    )
    AgentRootsConfig.stubs(:find!).returns(mock_agent_root)
    AgentSessionJob.stubs(:enqueue_new_session)

    job = SlackTriggerPollerJob.new

    assert_difference("Session.count", 1) do
      job.send(:process_condition, condition)
    end

    # last_message_ts should be updated to the newest message ts (not just the mention)
    condition.reload
    assert_equal "1704067500.000000", condition.last_message_ts
  end

  test "bot_mention condition updates last_message_ts even when no mentions found" do
    SlackService.stubs(:configured?).returns(true)
    SlackService.stubs(:bot_user_id).returns("U_BOT_123")
    SlackService.stubs(:list_dm_channels).returns([])

    condition = trigger_conditions(:bot_mention_slack_condition)

    messages = [
      OpenStruct.new(ts: "1704067300.000000", text: "Hello everyone", bot_id: nil, thread_ts: nil, user: "U111"),
      OpenStruct.new(ts: "1704067400.000000", text: "No mentions here", bot_id: nil, thread_ts: nil, user: "U222")
    ]

    SlackService.stubs(:get_messages_since).returns(messages)

    job = SlackTriggerPollerJob.new

    assert_no_difference("Session.count") do
      job.send(:process_condition, condition)
    end

    # Should still advance last_message_ts to avoid reprocessing
    condition.reload
    assert_equal "1704067400.000000", condition.last_message_ts
  end

  test "new_message condition continues to process all messages (not just mentions)" do
    SlackService.stubs(:configured?).returns(true)

    messages = [
      OpenStruct.new(ts: "1704067300.000000", text: "Hello everyone", bot_id: nil, thread_ts: nil, user: "U111"),
      OpenStruct.new(ts: "1704067400.000000", text: "Hey <@U_BOT_123> can you help?", bot_id: nil, thread_ts: nil, user: "U222")
    ]

    SlackService.stubs(:get_messages_since).returns(messages)
    SlackService.stubs(:get_message_permalink).returns("https://slack.com/msg/123")
    SlackService.stubs(:get_user_name).returns("Test User")

    mock_agent_root = OpenStruct.new(
      url: "https://github.com/test/repo",
      default_branch: "main",
      subdirectory: nil
    )
    AgentRootsConfig.stubs(:find!).returns(mock_agent_root)
    AgentSessionJob.stubs(:enqueue_new_session)

    job = SlackTriggerPollerJob.new

    # new_message condition should process ALL messages, not just mentions
    assert_difference("Session.count", 2) do
      job.send(:process_condition, @condition)
    end
  end

  # --- All-channel bot_mention tests ---

  test "bot_mention condition without channel polls all member channels for mentions" do
    SlackService.stubs(:configured?).returns(true)
    SlackService.stubs(:bot_user_id).returns("U_BOT_123")
    SlackService.stubs(:list_dm_channels).returns([])

    condition = trigger_conditions(:bot_mention_all_channels_condition)
    condition.configuration["allowed_user_ids"] = %w[U222]
    # Pre-set channel_timestamps so messages aren't treated as baseline
    condition.configuration["channel_timestamps"] = { "C_GENERAL" => "1704067000.000000", "C_TESTING" => "1704067000.000000" }
    condition.save!

    # Simulate two channels the bot is a member of
    member_channels = [
      OpenStruct.new(id: "C_GENERAL", name: "general", is_member: true),
      OpenStruct.new(id: "C_TESTING", name: "testing", is_member: true)
    ]
    SlackService.stubs(:list_member_channels).returns(member_channels)

    # Channel 1: has a bot mention from allowed user
    general_messages = [
      OpenStruct.new(ts: "1704067300.000000", text: "Hey <@U_BOT_123> help!", bot_id: nil, thread_ts: nil, user: "U222")
    ]
    # Channel 2: has a message but no bot mention
    testing_messages = [
      OpenStruct.new(ts: "1704067400.000000", text: "Just chatting", bot_id: nil, thread_ts: nil, user: "U333")
    ]

    SlackService.stubs(:get_messages_since).with("C_GENERAL", since_ts: "1704067000.000000").returns(general_messages)
    SlackService.stubs(:get_messages_since).with("C_TESTING", since_ts: "1704067000.000000").returns(testing_messages)
    SlackService.stubs(:get_message_permalink).returns("https://slack.com/msg/123")
    SlackService.stubs(:get_user_name).returns("Test User")
    SlackService.stubs(:get_channel).returns(OpenStruct.new(name: "general"))

    mock_agent_root = OpenStruct.new(
      url: "https://github.com/test/repo",
      default_branch: "main",
      subdirectory: nil
    )
    AgentRootsConfig.stubs(:find!).returns(mock_agent_root)
    AgentSessionJob.stubs(:enqueue_new_session)

    job = SlackTriggerPollerJob.new

    # Should create 1 session (only the mention in #general)
    assert_difference("Session.count", 1) do
      job.send(:process_condition, condition)
    end

    # Both channel timestamps should be updated
    condition.reload
    assert_equal "1704067300.000000", condition.channel_timestamps["C_GENERAL"]
    assert_equal "1704067400.000000", condition.channel_timestamps["C_TESTING"]
  end

  test "bot_mention condition without channel establishes baseline on first poll per channel" do
    SlackService.stubs(:configured?).returns(true)
    SlackService.stubs(:bot_user_id).returns("U_BOT_123")
    SlackService.stubs(:list_dm_channels).returns([])

    condition = trigger_conditions(:bot_mention_all_channels_condition)
    condition.configuration["allowed_user_ids"] = %w[U222]
    # No channel_timestamps set — first poll
    condition.save!

    member_channels = [
      OpenStruct.new(id: "C_GENERAL", name: "general", is_member: true)
    ]
    SlackService.stubs(:list_member_channels).returns(member_channels)

    # First poll returns baseline message
    baseline_message = [
      OpenStruct.new(ts: "1704067200.000000", text: "Hey <@U_BOT_123> old mention", bot_id: nil, thread_ts: nil, user: "U222")
    ]
    SlackService.stubs(:get_channel_history).with("C_GENERAL", limit: 1).returns(baseline_message)

    job = SlackTriggerPollerJob.new

    # Should NOT create any sessions (baseline establishment only)
    assert_no_difference("Session.count") do
      job.send(:process_condition, condition)
    end

    # Should record the baseline timestamp
    condition.reload
    assert_equal "1704067200.000000", condition.channel_timestamps["C_GENERAL"]
  end

  test "bot_mention condition without channel ignores mentions from non-allowed users" do
    SlackService.stubs(:configured?).returns(true)
    SlackService.stubs(:bot_user_id).returns("U_BOT_123")
    SlackService.stubs(:list_dm_channels).returns([])

    condition = trigger_conditions(:bot_mention_all_channels_condition)
    condition.configuration["allowed_user_ids"] = %w[U222]
    condition.configuration["channel_timestamps"] = { "C_GENERAL" => "1704067000.000000" }
    condition.save!

    member_channels = [
      OpenStruct.new(id: "C_GENERAL", name: "general", is_member: true)
    ]
    SlackService.stubs(:list_member_channels).returns(member_channels)

    # Mention from a non-allowed user
    messages = [
      OpenStruct.new(ts: "1704067300.000000", text: "Hey <@U_BOT_123> help!", bot_id: nil, thread_ts: nil, user: "U999")
    ]
    SlackService.stubs(:get_messages_since).with("C_GENERAL", since_ts: "1704067000.000000").returns(messages)

    job = SlackTriggerPollerJob.new

    assert_no_difference("Session.count") do
      job.send(:process_condition, condition)
    end

    # Timestamp should still advance
    condition.reload
    assert_equal "1704067300.000000", condition.channel_timestamps["C_GENERAL"]
  end

  test "bot_mention condition with channel still uses single-channel behavior" do
    SlackService.stubs(:configured?).returns(true)
    SlackService.stubs(:bot_user_id).returns("U_BOT_123")
    SlackService.stubs(:list_dm_channels).returns([])

    condition = trigger_conditions(:bot_mention_slack_condition)
    condition.configuration["allowed_user_ids"] = %w[U222]
    condition.save!

    messages = [
      OpenStruct.new(ts: "1704067300.000000", text: "Hey <@U_BOT_123> help!", bot_id: nil, thread_ts: nil, user: "U222")
    ]

    SlackService.stubs(:get_messages_since).returns(messages)
    SlackService.stubs(:get_message_permalink).returns("https://slack.com/msg/123")
    SlackService.stubs(:get_user_name).returns("Test User")

    mock_agent_root = OpenStruct.new(
      url: "https://github.com/test/repo",
      default_branch: "main",
      subdirectory: nil
    )
    AgentRootsConfig.stubs(:find!).returns(mock_agent_root)
    AgentSessionJob.stubs(:enqueue_new_session)

    # Should NOT call list_member_channels since channel_id is present
    SlackService.expects(:list_member_channels).never

    job = SlackTriggerPollerJob.new

    assert_difference("Session.count", 1) do
      job.send(:process_condition, condition)
    end
  end

  test "bot_mention condition without channel continues processing when one channel errors" do
    SlackService.stubs(:configured?).returns(true)
    SlackService.stubs(:bot_user_id).returns("U_BOT_123")
    SlackService.stubs(:list_dm_channels).returns([])

    condition = trigger_conditions(:bot_mention_all_channels_condition)
    condition.configuration["allowed_user_ids"] = %w[U222]
    condition.configuration["channel_timestamps"] = { "C_BAD" => "1704067000.000000", "C_GOOD" => "1704067000.000000" }
    condition.save!

    member_channels = [
      OpenStruct.new(id: "C_BAD", name: "bad-channel", is_member: true),
      OpenStruct.new(id: "C_GOOD", name: "good-channel", is_member: true)
    ]
    SlackService.stubs(:list_member_channels).returns(member_channels)

    # First channel errors
    SlackService.stubs(:get_messages_since).with("C_BAD", since_ts: "1704067000.000000").raises(SlackService::ApiError.new("channel_not_found"))

    # Second channel works
    good_messages = [
      OpenStruct.new(ts: "1704067300.000000", text: "Hey <@U_BOT_123> help!", bot_id: nil, thread_ts: nil, user: "U222")
    ]
    SlackService.stubs(:get_messages_since).with("C_GOOD", since_ts: "1704067000.000000").returns(good_messages)
    SlackService.stubs(:get_message_permalink).returns("https://slack.com/msg/123")
    SlackService.stubs(:get_user_name).returns("Test User")
    SlackService.stubs(:get_channel).returns(OpenStruct.new(name: "good-channel"))

    mock_agent_root = OpenStruct.new(
      url: "https://github.com/test/repo",
      default_branch: "main",
      subdirectory: nil
    )
    AgentRootsConfig.stubs(:find!).returns(mock_agent_root)
    AgentSessionJob.stubs(:enqueue_new_session)

    job = SlackTriggerPollerJob.new

    # Should still create session from the working channel
    assert_difference("Session.count", 1) do
      job.send(:process_condition, condition)
    end

    # Good channel timestamp should be updated, bad channel unchanged
    condition.reload
    assert_equal "1704067000.000000", condition.channel_timestamps["C_BAD"]
    assert_equal "1704067300.000000", condition.channel_timestamps["C_GOOD"]
  end

  # --- Thread reply mention tests ---

  test "bot_mention condition detects @mentions in thread replies using channel baseline" do
    SlackService.stubs(:configured?).returns(true)
    SlackService.stubs(:bot_user_id).returns("U_BOT_123")
    SlackService.stubs(:list_dm_channels).returns([])

    condition = trigger_conditions(:bot_mention_slack_condition)
    condition.configuration["allowed_user_ids"] = %w[U222]
    condition.save!

    # No new top-level messages (the thread parent is old)
    SlackService.stubs(:get_messages_since).returns([])

    # Recent channel history shows a thread parent with a reply newer than channel baseline
    # The condition's last_message_ts (channel baseline) is "1704067200.000000" from fixtures
    thread_parent = OpenStruct.new(
      ts: "1704066000.000000", text: "Original message", reply_count: 2,
      latest_reply: "1704067500.000000", bot_id: nil, thread_ts: nil, user: "U222"
    )
    SlackService.stubs(:get_channel_history).with(condition.channel_id, limit: 50).returns([ thread_parent ])

    # Thread has a reply that mentions the bot — newer than channel baseline
    thread_replies = [
      OpenStruct.new(ts: "1704067500.000000", text: "<@U_BOT_123> can you also do X?", bot_id: nil,
                     thread_ts: "1704066000.000000", user: "U222")
    ]
    SlackService.stubs(:get_thread_replies).with(condition.channel_id, "1704066000.000000", oldest: nil).returns(thread_replies)
    SlackService.stubs(:get_message_permalink).returns("https://slack.com/msg/thread")
    SlackService.stubs(:get_user_name).returns("Test User")

    mock_agent_root = OpenStruct.new(
      url: "https://github.com/test/repo",
      default_branch: "main",
      subdirectory: nil
    )
    AgentRootsConfig.stubs(:find!).returns(mock_agent_root)
    AgentSessionJob.stubs(:enqueue_new_session)

    job = SlackTriggerPollerJob.new

    # Reply is newer than channel baseline — should create session immediately
    # (no per-thread baseline needed when channel has been polled)
    assert_difference("Session.count", 1) do
      job.send(:process_condition, condition)
    end

    # Thread timestamp should be recorded
    condition.reload
    thread_key = "#{condition.channel_id}:1704066000.000000"
    assert_equal "1704067500.000000", condition.thread_timestamps[thread_key]
  end

  test "bot_mention condition skips thread replies older than channel baseline" do
    SlackService.stubs(:configured?).returns(true)
    SlackService.stubs(:bot_user_id).returns("U_BOT_123")
    SlackService.stubs(:list_dm_channels).returns([])

    condition = trigger_conditions(:bot_mention_slack_condition)
    condition.configuration["allowed_user_ids"] = %w[U222]
    condition.save!

    # No new top-level messages
    SlackService.stubs(:get_messages_since).returns([])

    # Thread parent is old and reply is OLDER than channel baseline
    # The condition's last_message_ts (channel baseline) is "1704067200.000000" from fixtures
    thread_parent = OpenStruct.new(
      ts: "1704060000.000000", text: "Ancient thread", reply_count: 1,
      latest_reply: "1704066000.000000", bot_id: nil, thread_ts: nil, user: "U222"
    )
    SlackService.stubs(:get_channel_history).with(condition.channel_id, limit: 50).returns([ thread_parent ])

    # Reply predates channel baseline — should NOT create a session
    thread_replies = [
      OpenStruct.new(ts: "1704066000.000000", text: "<@U_BOT_123> old request", bot_id: nil,
                     thread_ts: "1704060000.000000", user: "U222")
    ]
    SlackService.stubs(:get_thread_replies).with(condition.channel_id, "1704060000.000000", oldest: nil).returns(thread_replies)

    job = SlackTriggerPollerJob.new

    # Reply is older than channel baseline — no session created
    assert_no_difference("Session.count") do
      job.send(:process_condition, condition)
    end

    # Thread timestamp should still be recorded (to track we've seen it)
    condition.reload
    thread_key = "#{condition.channel_id}:1704060000.000000"
    assert_equal "1704066000.000000", condition.thread_timestamps[thread_key]
  end

  test "bot_mention condition skips thread replies from non-allowed users" do
    SlackService.stubs(:configured?).returns(true)
    SlackService.stubs(:bot_user_id).returns("U_BOT_123")
    SlackService.stubs(:list_dm_channels).returns([])

    condition = trigger_conditions(:bot_mention_slack_condition)
    condition.configuration["allowed_user_ids"] = %w[U222]
    # Pre-set thread timestamp so we're past baseline
    condition.configuration["thread_timestamps"] = { "#{condition.channel_id}:1704067000.000000" => "1704067400.000000" }
    condition.save!

    SlackService.stubs(:get_messages_since).returns([])

    thread_parent = OpenStruct.new(
      ts: "1704067000.000000", text: "Original message", reply_count: 2,
      latest_reply: "1704067500.000000", bot_id: nil, thread_ts: nil, user: "U222"
    )
    SlackService.stubs(:get_channel_history).with(condition.channel_id, limit: 50).returns([ thread_parent ])

    # Reply from non-allowed user
    thread_replies = [
      OpenStruct.new(ts: "1704067500.000000", text: "<@U_BOT_123> help me", bot_id: nil,
                     thread_ts: "1704067000.000000", user: "U999")
    ]
    SlackService.stubs(:get_thread_replies).with(condition.channel_id, "1704067000.000000", oldest: "1704067400.000000").returns(thread_replies)

    job = SlackTriggerPollerJob.new

    assert_no_difference("Session.count") do
      job.send(:process_condition, condition)
    end

    # Thread timestamp should still advance
    condition.reload
    thread_key = "#{condition.channel_id}:1704067000.000000"
    assert_equal "1704067500.000000", condition.thread_timestamps[thread_key]
  end

  test "bot_mention condition skips threads with no new replies since last check" do
    SlackService.stubs(:configured?).returns(true)
    SlackService.stubs(:bot_user_id).returns("U_BOT_123")
    SlackService.stubs(:list_dm_channels).returns([])

    condition = trigger_conditions(:bot_mention_slack_condition)
    condition.configuration["allowed_user_ids"] = %w[U222]
    # Thread already checked up to latest_reply
    condition.configuration["thread_timestamps"] = { "#{condition.channel_id}:1704067000.000000" => "1704067500.000000" }
    condition.save!

    SlackService.stubs(:get_messages_since).returns([])

    thread_parent = OpenStruct.new(
      ts: "1704067000.000000", text: "Original message", reply_count: 2,
      latest_reply: "1704067500.000000", bot_id: nil, thread_ts: nil, user: "U222"
    )
    SlackService.stubs(:get_channel_history).with(condition.channel_id, limit: 50).returns([ thread_parent ])

    # Should NOT call get_thread_replies since latest_reply <= our tracked timestamp
    SlackService.expects(:get_thread_replies).never

    job = SlackTriggerPollerJob.new

    assert_no_difference("Session.count") do
      job.send(:process_condition, condition)
    end
  end

  test "bot_mention condition does not create duplicate sessions from inclusive oldest param" do
    SlackService.stubs(:configured?).returns(true)
    SlackService.stubs(:bot_user_id).returns("U_BOT_123")
    SlackService.stubs(:list_dm_channels).returns([])

    condition = trigger_conditions(:bot_mention_slack_condition)
    condition.configuration["allowed_user_ids"] = %w[U222]
    # Thread was previously checked up to this reply
    condition.configuration["thread_timestamps"] = { "#{condition.channel_id}:1704067000.000000" => "1704067400.000000" }
    condition.save!

    SlackService.stubs(:get_messages_since).returns([])

    thread_parent = OpenStruct.new(
      ts: "1704067000.000000", text: "Original message", reply_count: 3,
      latest_reply: "1704067500.000000", bot_id: nil, thread_ts: nil, user: "U222"
    )
    SlackService.stubs(:get_channel_history).with(condition.channel_id, limit: 50).returns([ thread_parent ])

    # Slack returns the already-seen reply (oldest is inclusive) PLUS a new reply
    thread_replies = [
      OpenStruct.new(ts: "1704067400.000000", text: "<@U_BOT_123> old mention", bot_id: nil,
                     thread_ts: "1704067000.000000", user: "U222"),
      OpenStruct.new(ts: "1704067500.000000", text: "<@U_BOT_123> new mention", bot_id: nil,
                     thread_ts: "1704067000.000000", user: "U222")
    ]
    SlackService.stubs(:get_thread_replies).with(condition.channel_id, "1704067000.000000", oldest: "1704067400.000000").returns(thread_replies)
    SlackService.stubs(:get_message_permalink).returns("https://slack.com/msg/thread")
    SlackService.stubs(:get_user_name).returns("Test User")

    mock_agent_root = OpenStruct.new(
      url: "https://github.com/test/repo",
      default_branch: "main",
      subdirectory: nil
    )
    AgentRootsConfig.stubs(:find!).returns(mock_agent_root)
    AgentSessionJob.stubs(:enqueue_new_session)

    job = SlackTriggerPollerJob.new

    # Should create only 1 session (the new reply), NOT 2 (which would happen if
    # the already-seen reply at ts=1704067400 was not filtered out)
    assert_difference("Session.count", 1) do
      job.send(:process_condition, condition)
    end
  end

  test "bot_mention all-channels condition also checks thread replies" do
    SlackService.stubs(:configured?).returns(true)
    SlackService.stubs(:bot_user_id).returns("U_BOT_123")
    SlackService.stubs(:list_dm_channels).returns([])

    condition = trigger_conditions(:bot_mention_all_channels_condition)
    condition.configuration["allowed_user_ids"] = %w[U222]
    condition.configuration["channel_timestamps"] = { "C_GENERAL" => "1704067000.000000" }
    # Pre-set thread timestamp so we're past baseline
    condition.configuration["thread_timestamps"] = { "C_GENERAL:1704066000.000000" => "1704067100.000000" }
    condition.save!

    member_channels = [
      OpenStruct.new(id: "C_GENERAL", name: "general", is_member: true)
    ]
    SlackService.stubs(:list_member_channels).returns(member_channels)

    # No new top-level messages
    SlackService.stubs(:get_messages_since).with("C_GENERAL", since_ts: "1704067000.000000").returns([])

    # But there's a thread with a new reply
    thread_parent = OpenStruct.new(
      ts: "1704066000.000000", text: "Old thread", reply_count: 3,
      latest_reply: "1704067300.000000", bot_id: nil, thread_ts: nil, user: "U222"
    )
    SlackService.stubs(:get_channel_history).with("C_GENERAL", limit: 50).returns([ thread_parent ])

    thread_replies = [
      OpenStruct.new(ts: "1704067300.000000", text: "<@U_BOT_123> new question in thread",
                     bot_id: nil, thread_ts: "1704066000.000000", user: "U222")
    ]
    SlackService.stubs(:get_thread_replies).with("C_GENERAL", "1704066000.000000", oldest: "1704067100.000000").returns(thread_replies)
    SlackService.stubs(:get_message_permalink).returns("https://slack.com/msg/thread")
    SlackService.stubs(:get_user_name).returns("Test User")
    SlackService.stubs(:get_channel).returns(OpenStruct.new(name: "general"))

    mock_agent_root = OpenStruct.new(
      url: "https://github.com/test/repo",
      default_branch: "main",
      subdirectory: nil
    )
    AgentRootsConfig.stubs(:find!).returns(mock_agent_root)
    AgentSessionJob.stubs(:enqueue_new_session)

    job = SlackTriggerPollerJob.new

    assert_difference("Session.count", 1) do
      job.send(:process_condition, condition)
    end

    condition.reload
    assert_equal "1704067300.000000", condition.thread_timestamps["C_GENERAL:1704066000.000000"]
  end

  test "bot_mention condition skips thread checking on first poll (baseline)" do
    SlackService.stubs(:configured?).returns(true)
    SlackService.stubs(:bot_user_id).returns("U_BOT_123")
    SlackService.stubs(:list_dm_channels).returns([])

    condition = trigger_conditions(:bot_mention_all_channels_condition)
    condition.configuration["allowed_user_ids"] = %w[U222]
    # No channel_timestamps, no last_message_ts — first poll
    condition.save!

    member_channels = [
      OpenStruct.new(id: "C_GENERAL", name: "general", is_member: true)
    ]
    SlackService.stubs(:list_member_channels).returns(member_channels)

    baseline_message = [
      OpenStruct.new(ts: "1704067200.000000", text: "baseline", reply_count: 5,
                     latest_reply: "1704067500.000000", bot_id: nil, thread_ts: nil, user: "U222")
    ]
    SlackService.stubs(:get_channel_history).with("C_GENERAL", limit: 1).returns(baseline_message)

    # Should NOT call get_thread_replies on first poll
    SlackService.expects(:get_thread_replies).never
    # Should NOT call get_channel_history with limit: 50 (thread parent fetch)
    # (it should only call with limit: 1 for baseline)

    job = SlackTriggerPollerJob.new

    assert_no_difference("Session.count") do
      job.send(:process_condition, condition)
    end
  end

  # --- Aged-out tracked thread re-check tests ---
  #
  # A long-lived thread (e.g. a months-old digest thread that still receives
  # daily replies) eventually scrolls its parent past the last-50 recent-history
  # window that fetch_recent_thread_parents scans. Once that happens the thread
  # stops being visited even though it stays tracked in thread_timestamps, so
  # @mentions posted as replies to it are silently missed. The poller re-checks
  # tracked threads directly (bounded by RECHECK_HORIZON + MAX_TRACKED_THREAD_RECHECKS)
  # to catch these.

  test "bot_mention condition re-checks tracked thread whose parent aged out of recent window" do
    SlackService.stubs(:configured?).returns(true)
    SlackService.stubs(:bot_user_id).returns("U_BOT_123")
    SlackService.stubs(:list_dm_channels).returns([])

    # Slack timestamps relative to now so the tracked reply falls inside RECHECK_HORIZON.
    parent_ts = format("%.6f", 60.days.ago.to_f)   # parent long aged out of the top-50 window
    tracked_ts = format("%.6f", 3.days.ago.to_f)   # last reply we saw — well within the horizon
    new_reply_ts = format("%.6f", 1.day.ago.to_f)  # brand-new @mention reply

    condition = trigger_conditions(:bot_mention_slack_condition)
    condition.configuration["allowed_user_ids"] = %w[U222]
    condition.configuration["thread_timestamps"] = { "#{condition.channel_id}:#{parent_ts}" => tracked_ts }
    condition.save!

    SlackService.stubs(:get_messages_since).returns([])

    # The parent is NOT in the recent-50 window — this is the whole point.
    SlackService.stubs(:get_channel_history).with(condition.channel_id, limit: 50).returns([])

    thread_replies = [
      OpenStruct.new(ts: new_reply_ts, text: "<@U_BOT_123> hello? are you there?", bot_id: nil,
                     thread_ts: parent_ts, user: "U222")
    ]
    SlackService.stubs(:get_thread_replies).with(condition.channel_id, parent_ts, oldest: tracked_ts).returns(thread_replies)
    SlackService.stubs(:get_message_permalink).returns("https://slack.com/msg/aged-out-thread")
    SlackService.stubs(:get_user_name).returns("Test User")

    mock_agent_root = OpenStruct.new(
      url: "https://github.com/test/repo",
      default_branch: "main",
      subdirectory: nil
    )
    AgentRootsConfig.stubs(:find!).returns(mock_agent_root)
    AgentSessionJob.stubs(:enqueue_new_session)

    job = SlackTriggerPollerJob.new

    # The aged-out thread is re-checked directly and the mention creates a session.
    assert_difference("Session.count", 1) do
      job.send(:process_condition, condition)
    end

    # Tracked timestamp advances to the newest reply so it stays fresh.
    condition.reload
    assert_equal new_reply_ts, condition.thread_timestamps["#{condition.channel_id}:#{parent_ts}"]
  end

  test "bot_mention condition does not re-check tracked thread beyond recheck horizon" do
    SlackService.stubs(:configured?).returns(true)
    SlackService.stubs(:bot_user_id).returns("U_BOT_123")
    SlackService.stubs(:list_dm_channels).returns([])

    # Two tracked threads in the same channel, both aged out of the top-50 window.
    # Only the horizon distinguishes them: the dormant one must be skipped while the
    # within-horizon one is still fetched. This proves the RECHECK_HORIZON bound is
    # what excludes the dormant thread — not merely the absence of the re-check feature.
    dormant_parent_ts = format("%.6f", 200.days.ago.to_f)
    dormant_tracked_ts = format("%.6f", 100.days.ago.to_f) # older than RECHECK_HORIZON (45d) -> skipped
    fresh_parent_ts = format("%.6f", 60.days.ago.to_f)
    fresh_tracked_ts = format("%.6f", 3.days.ago.to_f)     # within horizon -> re-checked

    condition = trigger_conditions(:bot_mention_slack_condition)
    condition.configuration["allowed_user_ids"] = %w[U222]
    condition.configuration["thread_timestamps"] = {
      "#{condition.channel_id}:#{dormant_parent_ts}" => dormant_tracked_ts,
      "#{condition.channel_id}:#{fresh_parent_ts}" => fresh_tracked_ts
    }
    condition.save!

    SlackService.stubs(:get_messages_since).returns([])
    SlackService.stubs(:get_channel_history).with(condition.channel_id, limit: 50).returns([])

    # The within-horizon thread IS fetched (no new replies), proving the poller reached
    # the re-check path at all...
    SlackService.expects(:get_thread_replies)
      .with(condition.channel_id, fresh_parent_ts, oldest: fresh_tracked_ts)
      .returns([])
    # ...but the dormant thread past the horizon must NOT be fetched.
    SlackService.expects(:get_thread_replies)
      .with(condition.channel_id, dormant_parent_ts, oldest: dormant_tracked_ts)
      .never

    job = SlackTriggerPollerJob.new

    assert_no_difference("Session.count") do
      job.send(:process_condition, condition)
    end
  end

  # --- Thread-scoped new_message condition tests ---
  #
  # When a new_message condition has thread_ts configured, it monitors new REPLIES
  # in that specific thread instead of new top-level channel messages. This is the
  # fix for feeds whose posts arrive as thread replies (e.g. a daily digest thread),
  # which conversations.history-based channel polling never surfaces (issue #4335).

  test "fetch_new_thread_replies establishes baseline (newest reply) on first poll" do
    # Slack's conversations.replies is NOT globally sorted across pages, so the
    # newest reply is deliberately NOT the last array element here. The baseline
    # must still be selected by max timestamp, not array position.
    replies = [
      OpenStruct.new(ts: "1704067200.000000", text: "newest reply"),
      OpenStruct.new(ts: "1704067100.000000", text: "older reply")
    ]
    SlackService.stubs(:get_thread_replies).with("C123", "TS_PARENT").returns(replies)

    job = SlackTriggerPollerJob.new
    result = job.send(:fetch_new_thread_replies, "C123", "TS_PARENT", nil)

    # Only the newest reply is returned as the baseline (caller records it without acting)
    assert_equal 1, result.length
    assert_equal "1704067200.000000", result.first.ts
  end

  test "fetch_new_thread_replies returns empty when thread has no replies on first poll" do
    SlackService.stubs(:get_thread_replies).with("C123", "TS_PARENT").returns([])

    job = SlackTriggerPollerJob.new
    assert_empty job.send(:fetch_new_thread_replies, "C123", "TS_PARENT", nil)
  end

  test "fetch_new_thread_replies excludes already-seen reply on subsequent polls" do
    replies = [
      OpenStruct.new(ts: "1704067200.000000", text: "already seen"),
      OpenStruct.new(ts: "1704067300.000000", text: "brand new")
    ]
    # Slack's oldest param is inclusive, so it returns the already-seen reply too
    SlackService.stubs(:get_thread_replies).with("C123", "TS_PARENT", oldest: "1704067200.000000").returns(replies)

    job = SlackTriggerPollerJob.new
    result = job.send(:fetch_new_thread_replies, "C123", "TS_PARENT", "1704067200.000000")

    assert_equal 1, result.length
    assert_equal "brand new", result.first.text
  end

  test "thread-scoped new_message condition records baseline on first poll without creating sessions" do
    SlackService.stubs(:configured?).returns(true)

    condition = trigger_conditions(:new_slack_condition) # last_message_ts is nil
    condition.configuration["thread_ts"] = "1704000000.000000"
    condition.save!

    replies = [
      OpenStruct.new(ts: "1704067100.000000", text: "older digest", bot_id: "B123",
                     username: "ClawdBot", thread_ts: "1704000000.000000", user: nil),
      OpenStruct.new(ts: "1704067200.000000", text: "newest digest", bot_id: "B123",
                     username: "ClawdBot", thread_ts: "1704000000.000000", user: nil)
    ]
    SlackService.stubs(:get_thread_replies).with(condition.channel_id, "1704000000.000000").returns(replies)
    # Must NOT use channel-history polling for a thread-scoped condition
    SlackService.expects(:get_messages_since).never

    job = SlackTriggerPollerJob.new

    assert_no_difference("Session.count") do
      job.send(:process_condition, condition)
    end

    condition.reload
    assert_equal "1704067200.000000", condition.last_message_ts
  end

  test "thread-scoped new_message condition creates a session for a new thread reply" do
    SlackService.stubs(:configured?).returns(true)

    condition = trigger_conditions(:enabled_slack_condition) # baseline last_message_ts "1704067200.000000"
    condition.configuration["thread_ts"] = "1704000000.000000"
    condition.save!

    new_reply = OpenStruct.new(ts: "1704067300.000000", text: "Daily anomaly digest", bot_id: "B123",
                               username: "ClawdBot", thread_ts: "1704000000.000000", user: nil)
    SlackService.stubs(:get_thread_replies)
      .with(condition.channel_id, "1704000000.000000", oldest: "1704067200.000000")
      .returns([ new_reply ])
    SlackService.stubs(:get_message_permalink).returns("https://slack.com/msg/thread")
    # Thread-scoped conditions must never fall back to channel-history polling
    SlackService.expects(:get_messages_since).never

    mock_agent_root = OpenStruct.new(
      url: "https://github.com/test/repo",
      default_branch: "main",
      subdirectory: nil
    )
    AgentRootsConfig.stubs(:find!).returns(mock_agent_root)
    AgentSessionJob.stubs(:enqueue_new_session)

    job = SlackTriggerPollerJob.new

    assert_difference("Session.count", 1) do
      job.send(:process_condition, condition)
    end

    condition.reload
    assert_equal "1704067300.000000", condition.last_message_ts
  end

  test "thread-scoped condition advances baseline to the newest reply even when replies arrive out of order" do
    SlackService.stubs(:configured?).returns(true)

    condition = trigger_conditions(:enabled_slack_condition) # baseline last_message_ts "1704067200.000000"
    condition.configuration["thread_ts"] = "1704000000.000000"
    condition.save!

    # conversations.replies is NOT globally ordered across paginated pages: the
    # newest reply is deliberately NOT last in the array. The condition must
    # still advance last_message_ts to the MAX ts (a regression to .last would
    # persist the older ts and re-process the newer reply forever).
    replies = [
      OpenStruct.new(ts: "1704067400.000000", text: "newest digest", bot_id: "B123",
                     username: "ClawdBot", thread_ts: "1704000000.000000", user: nil),
      OpenStruct.new(ts: "1704067300.000000", text: "older new digest", bot_id: "B123",
                     username: "ClawdBot", thread_ts: "1704000000.000000", user: nil)
    ]
    SlackService.stubs(:get_thread_replies)
      .with(condition.channel_id, "1704000000.000000", oldest: "1704067200.000000")
      .returns(replies)
    SlackService.stubs(:get_message_permalink).returns("https://slack.com/msg/thread")
    SlackService.expects(:get_messages_since).never

    mock_agent_root = OpenStruct.new(
      url: "https://github.com/test/repo",
      default_branch: "main",
      subdirectory: nil
    )
    AgentRootsConfig.stubs(:find!).returns(mock_agent_root)
    AgentSessionJob.stubs(:enqueue_new_session)

    job = SlackTriggerPollerJob.new

    assert_difference("Session.count", 2) do
      job.send(:process_condition, condition)
    end

    condition.reload
    assert_equal "1704067400.000000", condition.last_message_ts
  end

  test "get_author_name returns bot username for bot messages" do
    message = OpenStruct.new(bot_id: "B123", username: "ClawBot", user: nil)

    job = SlackTriggerPollerJob.new
    name = job.send(:get_author_name, message)
    assert_equal "ClawBot", name
  end

  test "get_author_name falls back to bot profile name" do
    bot_profile = OpenStruct.new(name: "CI Bot")
    message = OpenStruct.new(bot_id: "B123", username: nil, bot_profile: bot_profile, user: nil)

    job = SlackTriggerPollerJob.new
    name = job.send(:get_author_name, message)
    assert_equal "CI Bot", name
  end

  test "get_author_name returns Bot as fallback for bot messages without name" do
    message = OpenStruct.new(bot_id: "B123", username: nil, bot_profile: nil, user: nil)

    job = SlackTriggerPollerJob.new
    name = job.send(:get_author_name, message)
    assert_equal "Bot", name
  end

  test "get_author_name returns Unknown for blank user" do
    message = OpenStruct.new(bot_id: nil, user: nil)

    job = SlackTriggerPollerJob.new
    name = job.send(:get_author_name, message)
    assert_equal "Unknown", name
  end

  test "get_author_name falls back to user id on error" do
    message = OpenStruct.new(bot_id: nil, user: "U123")

    SlackService.stubs(:get_user_name).raises(SlackService::ApiError.new("User not found"))

    job = SlackTriggerPollerJob.new
    name = job.send(:get_author_name, message)
    assert_equal "U123", name
  end
end
