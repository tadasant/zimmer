# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"
require "ostruct"

class SlackTriggerPollerJobTest < ActiveJob::TestCase
  # The deployment-wide Slack allow-list. Most conditions in this file are
  # deliberately UNRESTRICTED -- stub_bot_mention_condition(allowed_user_ids: nil),
  # stub_passive_listening's default of [], the channel condition built inline in "a
  # trigger carrying both conditions fires on either signal", and several taken
  # straight from trigger_conditions(:bot_mention_slack_condition) with no allow-list
  # of their own. An unrestricted condition falls through to
  # TriggerCondition.default_allowed_user_ids, which resolves the encrypted credential
  # first and process ENV second, so unless BOTH sources are neutralised nothing here
  # is unrestricted on a box that sets either one: the fixture users stop passing the
  # filter, DM enumeration goes out with an explicit user_ids: list instead of nil, and
  # 22 of these tests assert "this box has no Slack allow-list" rather than what they
  # claim. Controlling only the credential leaves the `||` falling through to ENV.
  #
  # A test that wants a deployment-wide default has to set one; the resolution order
  # itself is covered in test/models/trigger_condition_test.rb.
  ALLOWED_USER_IDS_KEY = "SLACK_BOT_MENTION_ALLOWED_USER_IDS"

  # An unassigned ivar reads as nil, which is indistinguishable from "the variable was
  # genuinely absent" -- and the setup below can be skipped entirely, because
  # test_helper prepends an AirCatalogCacheWarmer.restore! that AGENTS.md warns fails
  # globally on a broken catalog, and teardown runs anyway. Without a sentinel that
  # path deletes the real variable, having never read it, for the rest of this forked
  # worker process.
  ENV_NOT_SAVED = :env_not_saved

  setup do
    @previous_allowed_user_ids_env = ENV.fetch(ALLOWED_USER_IDS_KEY, ENV_NOT_SAVED)
    ENV.delete(ALLOWED_USER_IDS_KEY)

    # Sets the real variable rather than stubbing ENV#[], for the same reason
    # with_expiration_env (test/support/fixture_helpers.rb) does: a partial mocha stub
    # on ENV#[] breaks every other ENV read the poller makes.
    #
    # The credential half stubs `all` rather than `get(ALLOWED_USER_IDS_KEY)`, which is
    # where test/models/trigger_condition_test.rb's block-scoped helper stubs it. This
    # stub is class-wide, and a `.with(key)` constraint would turn every OTHER
    # SecretsLoader.get in the poller path into an unexpected-invocation failure. `get`
    # reads `all`, so dropping the one key leaves every other key `get` resolves
    # exactly as it really does. Read the real secrets BEFORE stubbing: `stubs(:all)`
    # replaces the method as the receiver of `.returns` is evaluated, so an inline read
    # would hit the stub-in-progress and hand back nil.
    credentials = SecretsLoader.all.except(ALLOWED_USER_IDS_KEY)
    SecretsLoader.stubs(:all).returns(credentials)

    @trigger = triggers(:enabled_slack_trigger)
    @condition = trigger_conditions(:enabled_slack_condition)
  end

  teardown do
    saved = @previous_allowed_user_ids_env
    if saved == ENV_NOT_SAVED
      ENV.delete(ALLOWED_USER_IDS_KEY)
    elsif !saved.nil?
      ENV[ALLOWED_USER_IDS_KEY] = saved
    end

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

  # --- Tracked-thread re-check rotation (#518) ---
  #
  # MAX_TRACKED_THREAD_RECHECKS is a per-poll BUDGET, not a coverage cap. Truncating
  # it — keeping the 20 most-recently-active aged-out threads and dropping the rest,
  # every poll — leaves most of a live condition's hundreds of tracked threads never
  # re-checked at all, unrecoverably: the ranking is by tracked activity, and a reply
  # nobody fetches never advances a tracked timestamp. These pin the rotation that
  # spends the same budget so every eligible thread comes round instead.

  # Seed `count` aged-out tracked threads in one channel, ordered so that thread key
  # order and tracked-activity order agree: index 0 is BOTH the lowest key and the
  # least-recently-active, index count-1 the highest and the most recent. That makes
  # "which threads does poll N re-check" predictable from the index alone.
  def seed_tracked_threads(condition, channel_id, count)
    base = Time.current.to_f - 40.days.to_i
    parents = (0...count).map { |i| format("%.6f", base + i) }
    condition.configuration["thread_timestamps"] = parents.each_with_index.to_h do |parent_ts, i|
      [ "#{channel_id}:#{parent_ts}", format("%.6f", base + 10.days.to_i + i) ]
    end
    condition.save!
    parents
  end

  test "bot_mention condition fires on a reply in a tracked thread outside the top slice by activity" do
    SlackService.stubs(:configured?).returns(true)
    SlackService.stubs(:bot_user_id).returns("U_BOT_123")
    SlackService.stubs(:list_dm_channels).returns([])

    condition = trigger_conditions(:bot_mention_slack_condition)
    condition.configuration["allowed_user_ids"] = %w[U222]
    # 25 tracked threads against a budget of 20: five more than one poll can hold.
    parents = seed_tracked_threads(condition, condition.channel_id, 25)

    # The LEAST recently active of the 25 — rank 25 of 25, so the old truncation
    # dropped it every poll and the mention below was never seen.
    target_parent_ts = parents.first
    target_tracked_ts = condition.thread_timestamps["#{condition.channel_id}:#{target_parent_ts}"]
    mention_ts = format("%.6f", Time.current.to_f - 1.minute.to_i)

    SlackService.stubs(:get_messages_since).returns([])
    # No parent is in the recent-50 window: every one of these is aged out.
    SlackService.stubs(:get_channel_history).with(condition.channel_id, limit: 50).returns([])
    SlackService.stubs(:get_thread_replies).returns([])
    SlackService.stubs(:get_thread_replies)
      .with(condition.channel_id, target_parent_ts, oldest: target_tracked_ts)
      .returns([
        OpenStruct.new(ts: mention_ts, text: "<@U_BOT_123> still waiting on this", bot_id: nil,
                       thread_ts: target_parent_ts, user: "U222")
      ])
    SlackService.stubs(:get_message_permalink).returns("https://slack.com/msg/rotated-in")
    SlackService.stubs(:get_user_name).returns("Test User")
    AgentRootsConfig.stubs(:find!).returns(
      OpenStruct.new(url: "https://github.com/test/repo", default_branch: "main", subdirectory: nil)
    )
    AgentSessionJob.stubs(:enqueue_new_session)

    assert_difference("Session.count", 1) do
      SlackTriggerPollerJob.new.send(:process_condition, condition)
    end

    assert_equal mention_ts, condition.reload.thread_timestamps["#{condition.channel_id}:#{target_parent_ts}"]
  end

  test "thread condition fires on a reply in a tracked thread outside the top slice by activity" do
    condition = stub_passive_listening(event_type: "passive_listen_thread")
    condition.configuration["channel_timestamps"] = { PASSIVE_CHANNEL => passive_ts(3.hours) }
    parents = seed_tracked_threads(condition, PASSIVE_CHANNEL, 25)

    target_parent_ts = parents.first
    target_tracked_ts = condition.thread_timestamps["#{PASSIVE_CHANNEL}:#{target_parent_ts}"]
    reply_ts = passive_ts(1.minute)

    # Zimmer is already known to be in the thread, so the reply qualifies passively.
    condition.configuration["participating_threads"] = [ "#{PASSIVE_CHANNEL}:#{target_parent_ts}" ]
    condition.save!

    SlackService.stubs(:get_messages_since).returns([])
    SlackService.stubs(:get_channel_history).with(PASSIVE_CHANNEL, limit: 50).returns([])
    SlackService.stubs(:get_thread_replies).returns([])
    SlackService.stubs(:get_thread_replies)
      .with(PASSIVE_CHANNEL, target_parent_ts, oldest: target_tracked_ts)
      .returns([ passive_message(reply_ts, thread_ts: target_parent_ts) ])

    assert_difference("Session.count", 1) do
      SlackTriggerPollerJob.new.send(:process_condition, condition)
    end

    # The rotation only advances because the cursor written mid-sweep survives the
    # batched configuration write the caller makes after the thread loop. Snapshot
    # `configuration` before that loop and the rotation freezes on poll 1 forever,
    # with every other assertion in this file still passing.
    condition.reload
    assert_equal "#{PASSIVE_CHANNEL}:#{parents[9]}", condition.thread_recheck_cursors[PASSIVE_CHANNEL]
    assert_equal reply_ts, condition.thread_timestamps["#{PASSIVE_CHANNEL}:#{target_parent_ts}"]
  end

  test "a rotating thread that receives a reply is promoted into the always-checked band" do
    condition = trigger_conditions(:bot_mention_slack_condition)
    channel_id = condition.channel_id
    parents = seed_tracked_threads(condition, channel_id, 25)

    # The least-recently-active thread: bottom of the rotation, nowhere near the hot
    # band. Give it a reply newer than every other tracked timestamp, which is what
    # a re-check that found something would have recorded.
    woken = parents.first
    condition.configuration["thread_timestamps"]["#{channel_id}:#{woken}"] =
      format("%.6f", Time.current.to_f)
    condition.save!

    slice = SlackTriggerPollerJob.new.send(:aged_out_thread_parents, condition, channel_id, []).map(&:ts)

    # Promotion is what stops the rotation from being a 17-minute cadence for a live
    # conversation: the wake-up costs one sweep, the rest of the exchange does not.
    hot = slice.first(SlackTriggerPollerJob::HOT_TRACKED_THREAD_RECHECKS)
    assert_includes hot, woken
  end

  test "the rotation wraps back to the start of the band once a sweep completes" do
    condition = trigger_conditions(:bot_mention_slack_condition)
    channel_id = condition.channel_id
    # 30 eligible: 10 hot and 20 rotating through 10 slots, so the second poll lands
    # exactly on the last key of the band and the third has to wrap rather than
    # running off the end.
    seed_tracked_threads(condition, channel_id, 30)

    job = SlackTriggerPollerJob.new
    polls = 3.times.map { job.send(:aged_out_thread_parents, condition.reload, channel_id, []).map(&:ts) }

    assert_equal polls[0], polls[2], "the third poll should restart the sweep the first one began"
    assert_empty polls[0] & (polls[1] - polls[0].first(SlackTriggerPollerJob::HOT_TRACKED_THREAD_RECHECKS)),
                 "the two rotating bands of a single sweep must not overlap"
  end

  test "every tracked thread inside the horizon is re-checked within a bounded number of polls" do
    condition = trigger_conditions(:bot_mention_slack_condition)
    channel_id = condition.channel_id
    # 45 eligible threads: 10 hot + 35 rotating through 10 slots => a full sweep
    # every 4 polls, and 5 threads the old truncation would never have visited.
    parents = seed_tracked_threads(condition, channel_id, 45)

    job = SlackTriggerPollerJob.new
    polls = 4.times.map do
      slice = job.send(:aged_out_thread_parents, condition.reload, channel_id, []).map(&:ts)
      # The budget is what bounds Slack API pressure: it must hold on every poll,
      # not on average.
      assert_equal SlackTriggerPollerJob::MAX_TRACKED_THREAD_RECHECKS, slice.size
      assert_equal slice.uniq, slice, "a poll must not spend two calls on the same thread"
      slice
    end

    assert_equal parents.sort, polls.flatten.uniq.sort,
                 "every eligible tracked thread should be visited within a full rotation"

    # The most-recently-active band is not starved by the rotation: it is re-checked
    # on every poll, so a live conversation still answers at the poll cadence.
    hot = parents.last(SlackTriggerPollerJob::HOT_TRACKED_THREAD_RECHECKS)
    polls.each { |slice| assert_equal hot.sort, (slice & hot).sort }
  end

  test "a channel tracking fewer threads than the budget re-checks them all and stores no cursor" do
    condition = trigger_conditions(:bot_mention_slack_condition)
    channel_id = condition.channel_id
    parents = seed_tracked_threads(condition, channel_id, 5)

    slice = SlackTriggerPollerJob.new.send(:aged_out_thread_parents, condition, channel_id, [])

    assert_equal parents.sort, slice.map(&:ts).sort
    # Rotation state is only paid for by channels that need it — a small channel
    # keeps the old behaviour and the old write profile exactly.
    assert_empty condition.reload.thread_recheck_cursors
  end

  test "rotation resumes after the previous poll's last thread rather than restarting" do
    condition = trigger_conditions(:bot_mention_slack_condition)
    channel_id = condition.channel_id
    parents = seed_tracked_threads(condition, channel_id, 25)

    job = SlackTriggerPollerJob.new
    first = job.send(:aged_out_thread_parents, condition, channel_id, []).map(&:ts)

    cursor = condition.reload.thread_recheck_cursors[channel_id]
    assert_equal "#{channel_id}:#{first.last}", cursor,
                 "the cursor should name the last thread of the rotating band"

    second = job.send(:aged_out_thread_parents, condition, channel_id, []).map(&:ts)

    # 25 eligible: 10 hot, re-checked on both polls, and 15 rotating through 10
    # slots. The second poll must therefore reach EXACTLY the five the first could
    # not — restarting the rotation instead would re-check the same ten and leave
    # those five permanently unvisited, which is the bug.
    assert_equal (parents - first).sort, (second - first).sort
    assert_equal parents.sort, (first | second).sort
  end

  # --- Thread-scoped new_message condition tests ---
  #
  # When a new_message condition has thread_ts configured, it monitors new REPLIES
  # in that specific thread instead of new top-level channel messages. This is the
  # fix for feeds whose posts arrive as thread replies (e.g. a daily digest thread),
  # which conversations.history-based channel polling never surfaces (issue pulsemcp/pulsemcp#4335).

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

  # === Queue isolation & singleton concurrency ===
  #
  # A poll is long, external-API-bound work: SlackService retries rate-limited
  # calls with blocking sleeps, so a run can hold its worker thread for minutes.
  # On the shared `default` queue those runs starved the periodic jobs that also
  # live there (HeartbeatSweepJob every 30s, cleanup crons), collapsing
  # background throughput. The poller must run on the isolated `pollers` queue and
  # be a singleton so overlapping cron ticks can't stack minutes-long runs and
  # saturate the queue's whole thread pool.

  test "runs on the dedicated pollers queue (not default)" do
    assert_equal "pollers", SlackTriggerPollerJob.new.queue_name
  end

  test "enqueues onto the pollers queue" do
    assert_enqueued_with(job: SlackTriggerPollerJob, queue: "pollers") do
      SlackTriggerPollerJob.perform_later
    end
  end

  test "is a singleton (total_limit 1) so overlapping polls cannot stack" do
    config = SlackTriggerPollerJob.good_job_concurrency_config
    assert_equal 1, config[:total_limit]
    assert_equal "slack_trigger_poller", SlackTriggerPollerJob.new.good_job_concurrency_key
  end

  # --- bot_mention allow-list: unset means EVERYONE (not nobody) ---

  test "with no allow-list configured, a mention from any user fires the condition" do
    condition = stub_bot_mention_condition(allowed_user_ids: nil)

    SlackService.stubs(:get_messages_since).returns([
      OpenStruct.new(ts: "1704067400.000000", text: "Hey <@U_BOT_123> help",
        bot_id: nil, thread_ts: nil, user: "U_RANDOM_STRANGER")
    ])

    assert_difference("Session.count", 1) do
      SlackTriggerPollerJob.new.send(:process_condition, condition)
    end
  end

  test "with an allow-list configured, a mention from an unlisted user is ignored" do
    condition = stub_bot_mention_condition(allowed_user_ids: %w[U222])

    SlackService.stubs(:get_messages_since).returns([
      OpenStruct.new(ts: "1704067400.000000", text: "Hey <@U_BOT_123> help",
        bot_id: nil, thread_ts: nil, user: "U_RANDOM_STRANGER")
    ])

    assert_no_difference("Session.count") do
      SlackTriggerPollerJob.new.send(:process_condition, condition)
    end
  end

  # The self-trigger loop: Zimmer posts to Slack with this same token (AlertService),
  # and an unrestricted bot_mention condition with no channel configured polls EVERY
  # channel the bot is in. Its own message must never fire it, allow-list or not.
  test "the bot's own message never fires the condition, even when everyone is allowed" do
    condition = stub_bot_mention_condition(allowed_user_ids: nil)

    SlackService.stubs(:get_messages_since).returns([
      OpenStruct.new(ts: "1704067400.000000", text: "Alert from <@U_BOT_123> (self)",
        bot_id: "B_BOT", thread_ts: nil, user: "U_BOT_123")
    ])

    assert_no_difference("Session.count") do
      SlackTriggerPollerJob.new.send(:process_condition, condition)
    end
  end

  # --- DM enumeration: "everyone" cannot be expressed as a list of user IDs ---

  test "an unrestricted condition enumerates ALL DM channels" do
    condition = stub_bot_mention_condition(allowed_user_ids: nil)

    # nil (not []) is what tells SlackService to list every IM. Passing an empty
    # allow-list here would match no DMs at all -- "everyone" silently becoming "nobody".
    SlackService.expects(:list_dm_channels).with(user_ids: nil).returns([])
    SlackService.stubs(:get_messages_since).returns([])

    SlackTriggerPollerJob.new.send(:process_condition, condition)
  end

  test "a restricted condition enumerates only the allowed users' DM channels" do
    condition = stub_bot_mention_condition(allowed_user_ids: %w[U222])

    SlackService.expects(:list_dm_channels).with(user_ids: %w[U222]).returns([])
    SlackService.stubs(:get_messages_since).returns([])

    SlackTriggerPollerJob.new.send(:process_condition, condition)
  end

  test "a DM with the bot itself is never polled" do
    condition = stub_bot_mention_condition(allowed_user_ids: nil)

    SlackService.stubs(:list_dm_channels).returns([
      OpenStruct.new(id: "D_SELF", user: "U_BOT_123")
    ])
    # The self-DM is rejected before any history fetch, so nothing is polled and no
    # session is created.
    SlackService.stubs(:get_messages_since).returns([])

    assert_no_difference("Session.count") do
      SlackTriggerPollerJob.new.send(:process_condition, condition)
    end
    assert_empty condition.reload.dm_timestamps
  end

  # --- dm_message: the DM half of bot_mention, on its own -------------------

  def stub_dm_message_condition(allowed_user_ids: nil)
    condition = stub_bot_mention_condition(allowed_user_ids: allowed_user_ids)
    config = condition.configuration.merge("event_type" => "dm_message")
    # A dm_message condition watches no channel. The fixture it is built from is
    # channel-scoped, so drop that here rather than leaving a channel the type
    # ignores -- otherwise the test would not notice if it started polling it.
    config.delete("channel_id")
    config.delete("channel_name")
    condition.configuration = config
    condition.save!
    condition
  end

  test "a dm_message condition polls DMs" do
    condition = stub_dm_message_condition(allowed_user_ids: %w[U222])

    SlackService.expects(:list_dm_channels).with(user_ids: %w[U222]).returns([])

    SlackTriggerPollerJob.new.send(:process_condition, condition)
  end

  test "a dm_message condition polls no channel at all" do
    condition = stub_dm_message_condition
    SlackService.stubs(:list_dm_channels).returns([])

    # The two channel-side entry points. bot_mention would call one of them; this
    # type must call neither, whatever a leftover channel_id says.
    SlackService.expects(:list_member_channels).never
    SlackService.expects(:get_messages_since).never

    SlackTriggerPollerJob.new.send(:process_condition, condition)
    assert_not_nil condition.reload.last_polled_at
  end

  test "a dm_message condition fires on a plain DM with no @mention" do
    condition = stub_dm_message_condition
    condition.update!(configuration: condition.configuration.merge("dm_timestamps" => { "U222" => "1000.000000" }))

    SlackService.stubs(:list_dm_channels).returns([ OpenStruct.new(id: "D222", user: "U222") ])
    SlackService.stubs(:get_messages_since).returns([
      OpenStruct.new(ts: "2000.000000", text: "hey can you look at this", user: "U222", bot_id: nil, thread_ts: nil)
    ])

    assert_difference("Session.count", 1) do
      SlackTriggerPollerJob.new.send(:process_condition, condition)
    end
    assert_equal "2000.000000", condition.reload.dm_timestamps["U222"]
  end

  # Enumeration is the ONLY gate on the DM path: there is no user_allowed? check
  # behind it. So this pins the enforcement where it actually lives -- a condition
  # asks for exactly its allowed users' conversations -- rather than asserting a
  # filter that does not exist. Hand it an unlisted user's DM anyway and it WOULD
  # fire, which is why an unset allow-list means "everyone" (see limitations.md).
  test "a dm_message condition asks Slack only for its allowed users' DMs" do
    condition = stub_dm_message_condition(allowed_user_ids: %w[U999])

    SlackService.expects(:list_dm_channels).with(user_ids: %w[U999]).returns([])

    assert_no_difference("Session.count") do
      SlackTriggerPollerJob.new.send(:process_condition, condition)
    end
  end

  test "the DM conversation list is fetched once per poll, not once per condition" do
    first = stub_dm_message_condition
    second = stub_dm_message_condition

    # bot_mention and dm_message both reach process_dm_messages, and list_dm_channels
    # paginates every IM the bot has. Two conditions sharing an allow-list must not
    # walk those pages twice on a singleton poller.
    SlackService.expects(:list_dm_channels).with(user_ids: nil).once.returns([])

    job = SlackTriggerPollerJob.new
    job.send(:process_condition, first)
    job.send(:process_condition, second)
  end

  test "a dm_message condition never fires on the bot's own message in a DM" do
    condition = stub_dm_message_condition
    condition.update!(configuration: condition.configuration.merge("dm_timestamps" => { "U222" => "1000.000000" }))

    SlackService.stubs(:list_dm_channels).returns([ OpenStruct.new(id: "D222", user: "U222") ])
    SlackService.stubs(:get_messages_since).returns([
      OpenStruct.new(ts: "2000.000000", text: "on it", user: "U_BOT_123", bot_id: nil, thread_ts: nil)
    ])

    assert_no_difference("Session.count") do
      SlackTriggerPollerJob.new.send(:process_condition, condition)
    end
    # The cursor still advances past the bot's own message -- it is seen, just not
    # acted on -- so the next poll does not re-read it.
    assert_equal "2000.000000", condition.reload.dm_timestamps["U222"]
  end

  private

  # A bot_mention condition on a single channel, with Slack and session-creation
  # collaborators stubbed. allowed_user_ids: nil leaves it unrestricted (the new
  # default); an array pins an explicit per-condition allow-list.
  def stub_bot_mention_condition(allowed_user_ids:)
    SlackService.stubs(:configured?).returns(true)
    SlackService.stubs(:bot_user_id).returns("U_BOT_123")
    SlackService.stubs(:list_dm_channels).returns([])
    SlackService.stubs(:get_message_permalink).returns("https://slack.com/msg/123")
    SlackService.stubs(:get_user_name).returns("Test User")
    SlackService.stubs(:get_channel_history).returns([])
    AgentRootsConfig.stubs(:find!).returns(
      OpenStruct.new(url: "https://github.com/test/repo", default_branch: "main", subdirectory: nil)
    )
    AgentSessionJob.stubs(:enqueue_new_session)

    condition = trigger_conditions(:bot_mention_slack_condition)
    condition.configuration = condition.configuration.merge("allowed_user_ids" => allowed_user_ids)
    condition.save!
    condition
  end

  # --- Passive listening ---------------------------------------------------
  #
  # Passive listening fires without an @mention, so what it does NOT fire on
  # matters as much as what it does: the whole point is to continue conversations
  # Zimmer is already in without becoming noise in the ones it isn't.
  #
  # The two signals are two separately selectable event types, because a Trigger ORs
  # its conditions. Each test names the type it exercises; the deprecated
  # `passive_listen` runs both at once and has its own tests at the end.

  PASSIVE_CHANNEL = "C_GENERAL"

  # Slack timestamps relative to now, so tests exercise CHANNEL_ENGAGEMENT_WINDOW
  # and THREAD_BACKFILL_HORIZON against real clock arithmetic rather than
  # fixture-era constants.
  #
  # Every call re-reads Time.current, so two calls with the same `ago` return
  # different strings. A test that seeds a value here and asserts on it must bind
  # the result to a local and compare against that local; re-deriving it at
  # assertion time measures the test body's own runtime instead.
  def passive_ts(ago)
    format("%.6f", Time.current.to_f - ago.to_i)
  end

  def stub_passive_listening(event_type:, allowed_user_ids: [])
    SlackService.stubs(:configured?).returns(true)
    SlackService.stubs(:bot_user_id).returns("U_BOT_123")
    SlackService.stubs(:get_message_permalink).returns("https://slack.com/msg/passive")
    SlackService.stubs(:get_user_name).returns("Test User")
    SlackService.stubs(:get_channel).returns(OpenStruct.new(name: "general"))
    AlertService.stubs(:channel_id).returns("C_ALERTS")
    SlackService.stubs(:list_member_channels).returns(
      [ OpenStruct.new(id: PASSIVE_CHANNEL, name: "general", is_member: true) ]
    )
    AgentRootsConfig.stubs(:find!).returns(
      OpenStruct.new(url: "https://github.com/test/repo", default_branch: "main", subdirectory: nil)
    )
    AgentSessionJob.stubs(:enqueue_new_session)

    condition = trigger_conditions(:passive_listen_all_channels_condition)
    condition.configuration["event_type"] = event_type
    condition.configuration["allowed_user_ids"] = allowed_user_ids if allowed_user_ids.any?
    condition.save!
    condition
  end

  def passive_message(ts, user: "U222", text: "any update on this?", **extra)
    OpenStruct.new(ts: ts, text: text, user: user, bot_id: nil, thread_ts: nil, **extra)
  end

  # ── passive_listen_thread ───────────────────────────────────────────────────

  test "thread condition fires on a new reply in a thread Zimmer has already spoken in" do
    condition = stub_passive_listening(event_type: "passive_listen_thread")
    condition.configuration["channel_timestamps"] = { PASSIVE_CHANNEL => passive_ts(3.hours) }
    condition.save!

    parent_ts = passive_ts(5.hours)
    bot_reply_ts = passive_ts(2.hours)
    new_reply_ts = passive_ts(1.minute)

    SlackService.stubs(:get_messages_since).returns([])
    SlackService.stubs(:get_channel_history).with(PASSIVE_CHANNEL, limit: 50).returns([
      OpenStruct.new(ts: parent_ts, reply_count: 2, latest_reply: new_reply_ts, user: "U222", thread_ts: nil, bot_id: nil)
    ])
    SlackService.stubs(:get_thread_replies).with(PASSIVE_CHANNEL, parent_ts, oldest: nil).returns([
      OpenStruct.new(ts: bot_reply_ts, text: "On it.", user: "U_BOT_123", bot_id: "B_ZIMMER", thread_ts: parent_ts),
      OpenStruct.new(ts: new_reply_ts, text: "any update?", user: "U222", bot_id: nil, thread_ts: parent_ts)
    ])

    assert_difference("Session.count", 1) do
      SlackTriggerPollerJob.new.send(:process_condition, condition)
    end

    condition.reload
    assert_equal new_reply_ts, condition.thread_timestamps["#{PASSIVE_CHANNEL}:#{parent_ts}"]
    assert_includes condition.participating_threads, "#{PASSIVE_CHANNEL}:#{parent_ts}"

    # A reply Zimmer left INSIDE a thread is not channel engagement — it makes it
    # party to that thread, not to everything else said in the channel.
    assert_empty condition.bot_activity_timestamps
  end

  test "thread condition ignores replies in a thread Zimmer has never spoken in, but still tracks it" do
    condition = stub_passive_listening(event_type: "passive_listen_thread")
    condition.configuration["channel_timestamps"] = { PASSIVE_CHANNEL => passive_ts(3.hours) }
    condition.save!

    parent_ts = passive_ts(5.hours)
    new_reply_ts = passive_ts(1.minute)

    SlackService.stubs(:get_messages_since).returns([])
    SlackService.stubs(:get_channel_history).with(PASSIVE_CHANNEL, limit: 50).returns([
      OpenStruct.new(ts: parent_ts, reply_count: 1, latest_reply: new_reply_ts, user: "U222", thread_ts: nil, bot_id: nil)
    ])
    SlackService.stubs(:get_thread_replies).with(PASSIVE_CHANNEL, parent_ts, oldest: nil).returns([
      OpenStruct.new(ts: new_reply_ts, text: "two humans talking", user: "U333", bot_id: nil, thread_ts: parent_ts)
    ])

    assert_no_difference("Session.count") do
      SlackTriggerPollerJob.new.send(:process_condition, condition)
    end

    # Tracked anyway, so if Zimmer joins later it starts from a real cursor
    # instead of replaying everything said before it arrived.
    condition.reload
    assert_equal new_reply_ts, condition.thread_timestamps["#{PASSIVE_CHANNEL}:#{parent_ts}"]
    assert_empty condition.participating_threads
  end

  test "thread condition never fires on a top-level message, however recently Zimmer posted" do
    condition = stub_passive_listening(event_type: "passive_listen_thread")
    condition.configuration["channel_timestamps"] = { PASSIVE_CHANNEL => passive_ts(3.hours) }
    condition.save!

    # Zimmer posted at the top level ten minutes ago — squarely inside the
    # engagement window a channel condition would fire on.
    SlackService.stubs(:get_channel_history).with(PASSIVE_CHANNEL, limit: 50).returns([
      OpenStruct.new(ts: passive_ts(10.minutes), text: "Deploy is out", user: "U_BOT_123", bot_id: "B_ZIMMER", thread_ts: nil, reply_count: 0)
    ])
    new_ts = passive_ts(1.minute)
    SlackService.stubs(:get_messages_since).returns([ passive_message(new_ts) ])

    assert_no_difference("Session.count") do
      SlackTriggerPollerJob.new.send(:process_condition, condition)
    end

    # The cursor still advances, and no engagement is recorded — that signal
    # belongs to the channel condition.
    condition.reload
    assert_equal new_ts, condition.channel_timestamps[PASSIVE_CHANNEL]
    assert_empty condition.bot_activity_timestamps
  end

  test "thread condition has no time limit on participation" do
    condition = stub_passive_listening(event_type: "passive_listen_thread")
    parent_ts = passive_ts(200.days)
    tracked_reply_ts = passive_ts(2.days)
    new_reply_ts = passive_ts(1.minute)
    thread_key = "#{PASSIVE_CHANNEL}:#{parent_ts}"

    # Zimmer last spoke in this thread long ago; only the memo remains.
    condition.configuration["channel_timestamps"] = { PASSIVE_CHANNEL => passive_ts(3.hours) }
    condition.configuration["thread_timestamps"] = { thread_key => tracked_reply_ts }
    condition.configuration["participating_threads"] = [ thread_key ]
    condition.save!

    SlackService.stubs(:get_messages_since).returns([])
    SlackService.stubs(:get_channel_history).with(PASSIVE_CHANNEL, limit: 50).returns([])
    SlackService.stubs(:get_thread_replies).with(PASSIVE_CHANNEL, parent_ts, oldest: tracked_reply_ts).returns([
      OpenStruct.new(ts: tracked_reply_ts, text: "already seen", user: "U222", bot_id: nil, thread_ts: parent_ts),
      OpenStruct.new(ts: new_reply_ts, text: "it regressed", user: "U222", bot_id: nil, thread_ts: parent_ts)
    ])

    assert_difference("Session.count", 1) do
      SlackTriggerPollerJob.new.send(:process_condition, condition)
    end
  end

  test "thread condition re-checks a tracked thread whose parent aged out of the recent window" do
    condition = stub_passive_listening(event_type: "passive_listen_thread")
    parent_ts = passive_ts(20.days)
    tracked_reply_ts = passive_ts(2.days)
    new_reply_ts = passive_ts(1.minute)
    thread_key = "#{PASSIVE_CHANNEL}:#{parent_ts}"

    condition.configuration["channel_timestamps"] = { PASSIVE_CHANNEL => passive_ts(3.hours) }
    condition.configuration["thread_timestamps"] = { thread_key => tracked_reply_ts }
    condition.configuration["participating_threads"] = [ thread_key ]
    condition.save!

    # The parent is far too old to appear in recent history.
    SlackService.stubs(:get_channel_history).with(PASSIVE_CHANNEL, limit: 50).returns([])
    SlackService.stubs(:get_messages_since).returns([])
    # Tail-only read, and Slack's inclusive `oldest` re-returns the cursor reply.
    SlackService.stubs(:get_thread_replies).with(PASSIVE_CHANNEL, parent_ts, oldest: tracked_reply_ts).returns([
      OpenStruct.new(ts: tracked_reply_ts, text: "already seen", user: "U222", bot_id: nil, thread_ts: parent_ts),
      OpenStruct.new(ts: new_reply_ts, text: "it regressed", user: "U222", bot_id: nil, thread_ts: parent_ts)
    ])

    assert_difference("Session.count", 1) do
      SlackTriggerPollerJob.new.send(:process_condition, condition)
    end

    assert_equal new_reply_ts, condition.reload.thread_timestamps[thread_key]
  end

  test "thread condition reads a tracked thread's tail only, and remembers participation" do
    condition = stub_passive_listening(event_type: "passive_listen_thread")
    parent_ts = passive_ts(5.hours)
    bot_reply_ts = passive_ts(2.hours)
    new_reply_ts = passive_ts(1.minute)
    thread_key = "#{PASSIVE_CHANNEL}:#{parent_ts}"

    condition.configuration["channel_timestamps"] = { PASSIVE_CHANNEL => passive_ts(3.hours) }
    condition.save!

    SlackService.stubs(:get_messages_since).returns([])
    SlackService.stubs(:get_channel_history).with(PASSIVE_CHANNEL, limit: 50).returns([
      OpenStruct.new(ts: parent_ts, reply_count: 2, latest_reply: new_reply_ts, user: "U222", thread_ts: nil, bot_id: nil)
    ])

    # First sight: no cursor, so the whole thread is read and participation learned.
    SlackService.stubs(:get_thread_replies).with(PASSIVE_CHANNEL, parent_ts, oldest: nil).returns([
      OpenStruct.new(ts: bot_reply_ts, text: "On it.", user: "U_BOT_123", bot_id: "B_ZIMMER", thread_ts: parent_ts),
      OpenStruct.new(ts: new_reply_ts, text: "any update?", user: "U222", bot_id: nil, thread_ts: parent_ts)
    ])

    SlackTriggerPollerJob.new.send(:process_condition, condition)
    condition.reload
    assert_equal [ thread_key ], condition.participating_threads

    # Next poll: a cursor exists, so only the tail is read — and it contains no
    # message of Zimmer's. The memo is what keeps the thread engaged.
    later_reply_ts = passive_ts(0)
    SlackService.unstub(:get_thread_replies)
    SlackService.stubs(:get_channel_history).with(PASSIVE_CHANNEL, limit: 50).returns([
      OpenStruct.new(ts: parent_ts, reply_count: 3, latest_reply: later_reply_ts, user: "U222", thread_ts: nil, bot_id: nil)
    ])
    SlackService.stubs(:get_thread_replies).with(PASSIVE_CHANNEL, parent_ts, oldest: new_reply_ts).returns([
      OpenStruct.new(ts: later_reply_ts, text: "and one more thing", user: "U222", bot_id: nil, thread_ts: parent_ts)
    ])

    assert_difference("Session.count", 1) do
      SlackTriggerPollerJob.new.send(:process_condition, condition)
    end
  end

  test "thread condition skips a tracked thread whose latest_reply has not moved" do
    condition = stub_passive_listening(event_type: "passive_listen_thread")
    parent_ts = passive_ts(5.hours)
    last_reply_ts = passive_ts(2.hours)

    condition.configuration["channel_timestamps"] = { PASSIVE_CHANNEL => passive_ts(3.hours) }
    condition.configuration["thread_timestamps"] = { "#{PASSIVE_CHANNEL}:#{parent_ts}" => last_reply_ts }
    condition.save!

    SlackService.stubs(:get_messages_since).returns([])
    SlackService.stubs(:get_channel_history).with(PASSIVE_CHANNEL, limit: 50).returns([
      OpenStruct.new(ts: parent_ts, reply_count: 1, latest_reply: last_reply_ts, user: "U222", thread_ts: nil, bot_id: nil)
    ])
    SlackService.expects(:get_thread_replies).never

    assert_no_difference("Session.count") do
      SlackTriggerPollerJob.new.send(:process_condition, condition)
    end
  end

  test "thread condition clamps a first-sight thread to THREAD_BACKFILL_HORIZON, not the channel window" do
    condition = stub_passive_listening(event_type: "passive_listen_thread")
    parent_ts = passive_ts(30.days)
    bot_reply_ts = passive_ts(20.days)
    ancient_reply_ts = passive_ts(5.days)
    # Older than CHANNEL_ENGAGEMENT_WINDOW (6h) but inside THREAD_BACKFILL_HORIZON
    # (24h): the two are decoupled on purpose, so retuning the channel window does
    # not silently retune first-discovery backfill.
    backfilled_reply_ts = passive_ts(10.hours)
    fresh_reply_ts = passive_ts(1.minute)

    # A channel whose conversation lives in threads: the top-level cursor is weeks
    # old, so without the clamp every reply since would fire at once.
    condition.configuration["channel_timestamps"] = { PASSIVE_CHANNEL => passive_ts(25.days) }
    condition.save!

    SlackService.stubs(:get_messages_since).returns([])
    SlackService.stubs(:get_channel_history).with(PASSIVE_CHANNEL, limit: 50).returns([
      OpenStruct.new(ts: parent_ts, reply_count: 4, latest_reply: fresh_reply_ts, user: "U222", thread_ts: nil, bot_id: nil)
    ])
    SlackService.stubs(:get_thread_replies).with(PASSIVE_CHANNEL, parent_ts, oldest: nil).returns([
      OpenStruct.new(ts: bot_reply_ts, text: "Done.", user: "U_BOT_123", bot_id: "B_ZIMMER", thread_ts: parent_ts),
      OpenStruct.new(ts: ancient_reply_ts, text: "old backlog reply", user: "U222", bot_id: nil, thread_ts: parent_ts),
      OpenStruct.new(ts: backfilled_reply_ts, text: "ten hours ago", user: "U222", bot_id: nil, thread_ts: parent_ts),
      OpenStruct.new(ts: fresh_reply_ts, text: "still broken", user: "U222", bot_id: nil, thread_ts: parent_ts)
    ])

    # The 10-hour-old and the fresh reply fire; the 5-day-old one does not.
    assert_difference("Session.count", 2) do
      SlackTriggerPollerJob.new.send(:process_condition, condition)
    end
  end

  test "thread condition clamps a thread whose OWN cursor went stale, not just a first-sight one" do
    condition = stub_passive_listening(event_type: "passive_listen_thread")
    parent_ts = passive_ts(30.days)

    # A thread Zimmer is already in, with a cursor of its own — but one that fell 10
    # days behind, which is what a thread starved by a truncated re-check budget (or
    # met across a deploy or an outage) looks like when the rotation finally reaches
    # it. Without the clamp, the whole 10-day backlog fires a session apiece.
    stale_cursor_ts = passive_ts(10.days)
    ancient_reply_ts = passive_ts(5.days)
    backfilled_reply_ts = passive_ts(10.hours)
    fresh_reply_ts = passive_ts(1.minute)

    condition.configuration["channel_timestamps"] = { PASSIVE_CHANNEL => passive_ts(3.hours) }
    condition.configuration["thread_timestamps"] = { "#{PASSIVE_CHANNEL}:#{parent_ts}" => stale_cursor_ts }
    condition.configuration["participating_threads"] = [ "#{PASSIVE_CHANNEL}:#{parent_ts}" ]
    condition.save!

    SlackService.stubs(:get_messages_since).returns([])
    SlackService.stubs(:get_channel_history).with(PASSIVE_CHANNEL, limit: 50).returns([])
    SlackService.stubs(:get_thread_replies).with(PASSIVE_CHANNEL, parent_ts, oldest: stale_cursor_ts).returns([
      OpenStruct.new(ts: ancient_reply_ts, text: "five days of backlog", user: "U222", bot_id: nil, thread_ts: parent_ts),
      OpenStruct.new(ts: backfilled_reply_ts, text: "ten hours ago", user: "U222", bot_id: nil, thread_ts: parent_ts),
      OpenStruct.new(ts: fresh_reply_ts, text: "still broken", user: "U222", bot_id: nil, thread_ts: parent_ts)
    ])

    # Only the two inside THREAD_BACKFILL_HORIZON fire; the 5-day-old one is dropped.
    assert_difference("Session.count", 2) do
      SlackTriggerPollerJob.new.send(:process_condition, condition)
    end

    # The cursor still advances past everything fetched, dropped replies included, so
    # the backlog is not re-offered on the next sweep.
    assert_equal fresh_reply_ts, condition.reload.thread_timestamps["#{PASSIVE_CHANNEL}:#{parent_ts}"]
  end

  test "thread condition does not re-check a tracked thread beyond the recheck horizon" do
    condition = stub_passive_listening(event_type: "passive_listen_thread")
    parent_ts = passive_ts(100.days)

    condition.configuration["channel_timestamps"] = { PASSIVE_CHANNEL => passive_ts(3.hours) }
    condition.configuration["thread_timestamps"] = { "#{PASSIVE_CHANNEL}:#{parent_ts}" => passive_ts(60.days) }
    condition.save!

    SlackService.stubs(:get_channel_history).with(PASSIVE_CHANNEL, limit: 50).returns([])
    SlackService.stubs(:get_messages_since).returns([])
    SlackService.expects(:get_thread_replies).never

    assert_no_difference("Session.count") do
      SlackTriggerPollerJob.new.send(:process_condition, condition)
    end
  end

  # ── passive_listen_channel ──────────────────────────────────────────────────

  test "channel condition fires on a top-level message while the engagement is fresh" do
    condition = stub_passive_listening(event_type: "passive_listen_channel")
    condition.configuration["channel_timestamps"] = { PASSIVE_CHANNEL => passive_ts(3.hours) }
    condition.configuration["bot_activity_timestamps"] = { PASSIVE_CHANNEL => passive_ts(5.hours) }
    condition.save!

    new_ts = passive_ts(1.minute)
    SlackService.stubs(:get_channel_history).with(PASSIVE_CHANNEL, limit: 50).returns([])
    SlackService.stubs(:get_messages_since).returns([ passive_message(new_ts) ])

    assert_difference("Session.count", 1) do
      SlackTriggerPollerJob.new.send(:process_condition, condition)
    end

    assert_equal new_ts, condition.reload.channel_timestamps[PASSIVE_CHANNEL]
  end

  test "channel condition stops firing once the 6-hour engagement window has lapsed, but advances the cursor" do
    condition = stub_passive_listening(event_type: "passive_listen_channel")
    condition.configuration["channel_timestamps"] = { PASSIVE_CHANNEL => passive_ts(8.hours) }
    # Seven hours ago: outside CHANNEL_ENGAGEMENT_WINDOW.
    condition.configuration["bot_activity_timestamps"] = { PASSIVE_CHANNEL => passive_ts(7.hours) }
    condition.save!

    new_ts = passive_ts(1.minute)
    SlackService.stubs(:get_channel_history).with(PASSIVE_CHANNEL, limit: 50).returns([])
    SlackService.stubs(:get_messages_since).returns([ passive_message(new_ts) ])

    assert_no_difference("Session.count") do
      SlackTriggerPollerJob.new.send(:process_condition, condition)
    end

    assert_equal new_ts, condition.reload.channel_timestamps[PASSIVE_CHANNEL]
  end

  test "channel condition never reads threads" do
    condition = stub_passive_listening(event_type: "passive_listen_channel")
    condition.configuration["channel_timestamps"] = { PASSIVE_CHANNEL => passive_ts(3.hours) }
    condition.configuration["bot_activity_timestamps"] = { PASSIVE_CHANNEL => passive_ts(1.hour) }
    condition.save!

    # An active thread sits in the channel's recent history; a channel condition
    # must not spend a conversations.replies call on it.
    SlackService.stubs(:get_channel_history).with(PASSIVE_CHANNEL, limit: 50).returns([
      OpenStruct.new(ts: passive_ts(5.hours), reply_count: 3, latest_reply: passive_ts(1.minute), user: "U222", thread_ts: nil, bot_id: nil)
    ])
    SlackService.stubs(:get_messages_since).returns([])
    SlackService.expects(:get_thread_replies).never

    assert_no_difference("Session.count") do
      SlackTriggerPollerJob.new.send(:process_condition, condition)
    end

    assert_empty condition.reload.thread_timestamps
  end

  test "channel condition learns engagement from Zimmer's own recent top-level post" do
    condition = stub_passive_listening(event_type: "passive_listen_channel")
    condition.configuration["channel_timestamps"] = { PASSIVE_CHANNEL => passive_ts(3.hours) }
    condition.save!

    bot_post_ts = passive_ts(90.minutes)
    new_ts = passive_ts(1.minute)
    SlackService.stubs(:get_channel_history).with(PASSIVE_CHANNEL, limit: 50).returns([
      OpenStruct.new(ts: bot_post_ts, text: "Deploy is out", user: "U_BOT_123", bot_id: "B_ZIMMER", thread_ts: nil, reply_count: 0)
    ])
    SlackService.stubs(:get_messages_since).returns([ passive_message(new_ts) ])

    assert_difference("Session.count", 1) do
      SlackTriggerPollerJob.new.send(:process_condition, condition)
    end

    # Remembered, so the channel stays engaged on later polls even once that post
    # scrolls out of the recent-history window.
    assert_equal bot_post_ts, condition.reload.bot_activity_timestamps[PASSIVE_CHANNEL]
  end

  test "channel condition never winds engagement backwards" do
    condition = stub_passive_listening(event_type: "passive_listen_channel")
    fresh_engagement_ts = passive_ts(2.hours)

    condition.configuration["channel_timestamps"] = { PASSIVE_CHANNEL => passive_ts(3.hours) }
    condition.configuration["bot_activity_timestamps"] = { PASSIVE_CHANNEL => fresh_engagement_ts }
    condition.save!

    # Zimmer's recent post has scrolled out of the window; the only bot message
    # still visible is an old one.
    SlackService.stubs(:get_channel_history).with(PASSIVE_CHANNEL, limit: 50).returns([
      OpenStruct.new(ts: passive_ts(9.days), text: "old news", user: "U_BOT_123", bot_id: "B_ZIMMER", thread_ts: nil, reply_count: 0)
    ])
    SlackService.stubs(:get_messages_since).returns([ passive_message(passive_ts(2.minutes)) ])

    assert_difference("Session.count", 1) do
      SlackTriggerPollerJob.new.send(:process_condition, condition)
    end

    assert_equal fresh_engagement_ts, condition.reload.bot_activity_timestamps[PASSIVE_CHANNEL]
  end

  test "channel condition never fires on Zimmer's own messages or another app's" do
    condition = stub_passive_listening(event_type: "passive_listen_channel")
    condition.configuration["channel_timestamps"] = { PASSIVE_CHANNEL => passive_ts(3.hours) }
    condition.configuration["bot_activity_timestamps"] = { PASSIVE_CHANNEL => passive_ts(1.hour) }
    condition.save!

    SlackService.stubs(:get_channel_history).with(PASSIVE_CHANNEL, limit: 50).returns([])
    SlackService.stubs(:get_messages_since).returns([
      passive_message(passive_ts(3.minutes), user: "U_BOT_123", text: "Opened PR #1"),
      passive_message(passive_ts(2.minutes), user: "U_CI_BOT", text: "Build failed", bot_id: "B_CI"),
      passive_message(passive_ts(1.minute), user: "U333", text: "Sam has joined the channel", subtype: "channel_join")
    ])

    assert_no_difference("Session.count") do
      SlackTriggerPollerJob.new.send(:process_condition, condition)
    end
  end

  test "channel condition ignores messages with no user at all" do
    condition = stub_passive_listening(event_type: "passive_listen_channel")
    condition.configuration["channel_timestamps"] = { PASSIVE_CHANNEL => passive_ts(3.hours) }
    condition.configuration["bot_activity_timestamps"] = { PASSIVE_CHANNEL => passive_ts(1.hour) }
    condition.save!

    SlackService.stubs(:get_channel_history).with(PASSIVE_CHANNEL, limit: 50).returns([])
    SlackService.stubs(:get_messages_since).returns([
      OpenStruct.new(ts: passive_ts(1.minute), text: "legacy webhook post", user: nil, bot_id: nil, thread_ts: nil)
    ])

    assert_no_difference("Session.count") do
      SlackTriggerPollerJob.new.send(:process_condition, condition)
    end
  end

  test "channel condition honors the allow-list" do
    condition = stub_passive_listening(event_type: "passive_listen_channel", allowed_user_ids: %w[U222])
    condition.configuration["channel_timestamps"] = { PASSIVE_CHANNEL => passive_ts(3.hours) }
    condition.configuration["bot_activity_timestamps"] = { PASSIVE_CHANNEL => passive_ts(1.hour) }
    condition.save!

    SlackService.stubs(:get_channel_history).with(PASSIVE_CHANNEL, limit: 50).returns([])
    SlackService.stubs(:get_messages_since).returns([
      passive_message(passive_ts(2.minutes), user: "U999", text: "not on the list"),
      passive_message(passive_ts(1.minute), user: "U222", text: "on the list")
    ])

    assert_difference("Session.count", 1) do
      SlackTriggerPollerJob.new.send(:process_condition, condition)
    end
  end

  test "channel condition does not count Zimmer's own alert posts as engagement" do
    condition = stub_passive_listening(event_type: "passive_listen_channel")
    AlertService.stubs(:channel_id).returns(PASSIVE_CHANNEL)

    condition.configuration["channel_timestamps"] = { PASSIVE_CHANNEL => passive_ts(3.hours) }
    condition.save!

    # AlertService posts with the same token, so an alert looks exactly like any
    # other message from Zimmer — but it is a feed, not a conversation.
    SlackService.stubs(:get_channel_history).with(PASSIVE_CHANNEL, limit: 50).returns([
      OpenStruct.new(ts: passive_ts(30.minutes), text: "ALERT: poller error", user: "U_BOT_123", bot_id: "B_ZIMMER", thread_ts: nil, reply_count: 0)
    ])
    SlackService.stubs(:get_messages_since).returns([ passive_message(passive_ts(1.minute), text: "looking") ])

    assert_no_difference("Session.count") do
      SlackTriggerPollerJob.new.send(:process_condition, condition)
    end
  end

  test "channel condition with a configured channel polls only that channel" do
    condition = stub_passive_listening(event_type: "passive_listen_channel")
    condition.configuration["channel_id"] = PASSIVE_CHANNEL
    condition.configuration["channel_name"] = "general"
    condition.configuration["channel_timestamps"] = { PASSIVE_CHANNEL => passive_ts(3.hours) }
    condition.configuration["bot_activity_timestamps"] = { PASSIVE_CHANNEL => passive_ts(1.hour) }
    condition.save!

    SlackService.expects(:list_member_channels).never
    SlackService.stubs(:get_channel_history).with(PASSIVE_CHANNEL, limit: 50).returns([])
    SlackService.stubs(:get_messages_since).returns([ passive_message(passive_ts(1.minute)) ])

    assert_difference("Session.count", 1) do
      SlackTriggerPollerJob.new.send(:process_condition, condition)
    end
  end

  test "channel condition batches cursors across channels and survives one channel erroring" do
    condition = stub_passive_listening(event_type: "passive_listen_channel")
    other_channel = "C_TESTING"
    SlackService.unstub(:list_member_channels)
    SlackService.stubs(:list_member_channels).returns([
      OpenStruct.new(id: PASSIVE_CHANNEL, name: "general", is_member: true),
      OpenStruct.new(id: other_channel, name: "testing", is_member: true)
    ])

    good_ts = passive_ts(1.minute)
    # Bound once: this exact string is what the erroring channel's cursor must still hold.
    untouched_ts = passive_ts(3.hours)
    condition.configuration["channel_timestamps"] = {
      PASSIVE_CHANNEL => passive_ts(3.hours), other_channel => untouched_ts
    }
    condition.configuration["bot_activity_timestamps"] = { PASSIVE_CHANNEL => passive_ts(1.hour) }
    condition.save!

    SlackService.stubs(:get_channel_history).with(PASSIVE_CHANNEL, limit: 50).returns([])
    SlackService.stubs(:get_messages_since).with(PASSIVE_CHANNEL, since_ts: anything).returns([ passive_message(good_ts) ])
    SlackService.stubs(:get_messages_since).with(other_channel, since_ts: anything)
      .raises(SlackService::SlackError, "channel_not_found")

    assert_difference("Session.count", 1) do
      SlackTriggerPollerJob.new.send(:process_condition, condition)
    end

    # The healthy channel's cursor still advances; the broken one is left alone.
    condition.reload
    assert_equal good_ts, condition.channel_timestamps[PASSIVE_CHANNEL]
    assert_equal untouched_ts, condition.channel_timestamps[other_channel]
  end

  # ── Shared behaviour ────────────────────────────────────────────────────────

  test "passive listening establishes a per-channel baseline on the first poll without firing" do
    condition = stub_passive_listening(event_type: "passive_listen_thread")
    baseline_ts = passive_ts(1.minute)

    SlackService.stubs(:get_channel_history).with(PASSIVE_CHANNEL, limit: 1).returns([ passive_message(baseline_ts) ])
    SlackService.expects(:get_messages_since).never
    SlackService.expects(:get_thread_replies).never

    assert_no_difference("Session.count") do
      SlackTriggerPollerJob.new.send(:process_condition, condition)
    end

    assert_equal baseline_ts, condition.reload.channel_timestamps[PASSIVE_CHANNEL]
  end

  test "passive listening never polls DMs" do
    %w[passive_listen_thread passive_listen_channel passive_listen].each do |event_type|
      condition = stub_passive_listening(event_type: event_type)
      condition.configuration["channel_timestamps"] = { PASSIVE_CHANNEL => passive_ts(3.hours) }
      condition.save!

      SlackService.stubs(:get_channel_history).with(PASSIVE_CHANNEL, limit: 50).returns([])
      SlackService.stubs(:get_messages_since).returns([])
      SlackService.expects(:list_dm_channels).never

      SlackTriggerPollerJob.new.send(:process_condition, condition)
    end
  end

  # ── Mentions belong to bot_mention ──────────────────────────────────────────
  #
  # A mention posted inside a thread Zimmer is in is BOTH a mention and a reply in a
  # participated thread, so before this exclusion one Slack message spawned two
  # concurrent sessions on identical text — one per matching trigger.

  test "thread condition ignores a reply that @mentions Zimmer, but not its neighbours" do
    condition = stub_passive_listening(event_type: "passive_listen_thread")
    condition.configuration["channel_timestamps"] = { PASSIVE_CHANNEL => passive_ts(3.hours) }
    condition.save!

    parent_ts = passive_ts(5.hours)
    bot_reply_ts = passive_ts(2.hours)
    mention_ts = passive_ts(2.minutes)
    plain_ts = passive_ts(1.minute)

    SlackService.stubs(:get_messages_since).returns([])
    SlackService.stubs(:get_channel_history).with(PASSIVE_CHANNEL, limit: 50).returns([
      OpenStruct.new(ts: parent_ts, reply_count: 3, latest_reply: plain_ts, user: "U222", thread_ts: nil, bot_id: nil)
    ])
    SlackService.stubs(:get_thread_replies).with(PASSIVE_CHANNEL, parent_ts, oldest: nil).returns([
      OpenStruct.new(ts: bot_reply_ts, text: "On it.", user: "U_BOT_123", bot_id: "B_ZIMMER", thread_ts: parent_ts),
      OpenStruct.new(ts: mention_ts, text: "<@U_BOT_123> can you look again?", user: "U222", bot_id: nil, thread_ts: parent_ts),
      OpenStruct.new(ts: plain_ts, text: "any update?", user: "U222", bot_id: nil, thread_ts: parent_ts)
    ])

    # Only the non-mention reply fires; the mention is bot_mention's to handle.
    assert_difference("Session.count", 1) do
      SlackTriggerPollerJob.new.send(:process_condition, condition)
    end

    # Assert WHICH one fired — the inverted bug would also spawn exactly one.
    assert_includes Session.order(:id).last.prompt, "any update?"
    assert_not_includes Session.order(:id).last.prompt, "look again"
  end

  test "a mention in a participated thread is still caught by a bot_mention condition" do
    stub_passive_listening(event_type: "passive_listen_thread")
    condition = trigger_conditions(:bot_mention_slack_condition)
    condition.update!(last_message_ts: passive_ts(3.hours))

    parent_ts = passive_ts(5.hours)
    mention_ts = passive_ts(2.minutes)

    SlackService.stubs(:list_dm_channels).returns([])
    SlackService.stubs(:get_messages_since).returns([])
    SlackService.stubs(:get_channel_history).with(condition.channel_id, limit: 50).returns([
      OpenStruct.new(ts: parent_ts, reply_count: 2, latest_reply: mention_ts, user: "U222", thread_ts: nil, bot_id: nil)
    ])
    SlackService.stubs(:get_thread_replies).with(condition.channel_id, parent_ts, oldest: nil).returns([
      OpenStruct.new(ts: mention_ts, text: "<@U_BOT_123> can you look again?", user: "U222", bot_id: nil, thread_ts: parent_ts)
    ])

    # The passive path declining it is only safe because this path still takes it.
    assert_difference("Session.count", 1) do
      SlackTriggerPollerJob.new.send(:process_condition, condition)
    end
    assert_includes Session.order(:id).last.prompt, "look again"
  end

  test "channel condition ignores a top-level message that @mentions Zimmer" do
    condition = stub_passive_listening(event_type: "passive_listen_channel")
    condition.configuration["channel_timestamps"] = { PASSIVE_CHANNEL => passive_ts(3.hours) }
    condition.configuration["bot_activity_timestamps"] = { PASSIVE_CHANNEL => passive_ts(1.hour) }
    condition.save!

    SlackService.stubs(:get_channel_history).with(PASSIVE_CHANNEL, limit: 50).returns([])
    SlackService.stubs(:get_messages_since).returns([
      passive_message(passive_ts(2.minutes), text: "hey <@U_BOT_123> can you take this?"),
      passive_message(passive_ts(1.minute), text: "unrelated chatter")
    ])

    assert_difference("Session.count", 1) do
      SlackTriggerPollerJob.new.send(:process_condition, condition)
    end

    assert_includes Session.order(:id).last.prompt, "unrelated chatter"
  end

  test "the passive exclusion and the bot_mention filter agree on what a mention is" do
    job = SlackTriggerPollerJob.new
    condition = stub_passive_listening(event_type: "passive_listen_thread")
    mention = passive_message(passive_ts(1.minute), text: "ping <@U_BOT_123>")
    plain = passive_message(passive_ts(1.minute), text: "no mention here")

    # Exactly one of the two paths claims any given message from an allowed human.
    assert job.send(:mention_for?, condition, mention, "U_BOT_123")
    assert_not job.send(:passive_candidate?, condition, mention, "U_BOT_123")

    assert_not job.send(:mention_for?, condition, plain, "U_BOT_123")
    assert job.send(:passive_candidate?, condition, plain, "U_BOT_123")
  end

  test "a message with no text at all is not treated as a mention" do
    job = SlackTriggerPollerJob.new
    condition = stub_passive_listening(event_type: "passive_listen_thread")
    textless = passive_message(passive_ts(1.minute), text: nil)

    assert_not job.send(:mentions_bot?, textless, "U_BOT_123")
    assert job.send(:passive_candidate?, condition, textless, "U_BOT_123")
  end

  # Without the guard this degrades to matching the literal "<@>".
  test "an unknown bot id never makes a message look like a mention" do
    job = SlackTriggerPollerJob.new
    condition = stub_passive_listening(event_type: "passive_listen_thread")
    odd = passive_message(passive_ts(1.minute), text: "who is <@> anyway")

    assert_not job.send(:mentions_bot?, odd, nil)
    assert job.send(:passive_candidate?, condition, odd, nil)
  end

  # ── The deprecated combined type ────────────────────────────────────────────
  #
  # Kept working so deploying the split can't strand a trigger that still names it.

  test "channel condition does not count a broadcast thread reply as engagement" do
    condition = stub_passive_listening(event_type: "passive_listen_channel")
    parent_ts = passive_ts(3.hours)
    condition.configuration["channel_timestamps"] = { PASSIVE_CHANNEL => passive_ts(3.hours) }
    condition.save!

    # A reply Zimmer broadcast back to the channel: conversations.history returns it
    # (thread_ts != ts), but it is still a thread reply, not a top-level post.
    SlackService.stubs(:get_channel_history).with(PASSIVE_CHANNEL, limit: 50).returns([
      OpenStruct.new(ts: passive_ts(20.minutes), text: "Shipped it", user: "U_BOT_123", bot_id: "B_ZIMMER",
                     thread_ts: parent_ts, subtype: "thread_broadcast", reply_count: 0)
    ])
    SlackService.stubs(:get_messages_since).returns([ passive_message(passive_ts(1.minute)) ])

    assert_no_difference("Session.count") do
      SlackTriggerPollerJob.new.send(:process_condition, condition)
    end

    assert_empty condition.reload.bot_activity_timestamps
  end

  test "thread condition leaves an existing engagement cursor untouched" do
    condition = stub_passive_listening(event_type: "passive_listen_thread")
    engagement_ts = passive_ts(1.hour)
    condition.configuration["channel_timestamps"] = { PASSIVE_CHANNEL => passive_ts(3.hours) }
    condition.configuration["bot_activity_timestamps"] = { PASSIVE_CHANNEL => engagement_ts }
    condition.save!

    SlackService.stubs(:get_channel_history).with(PASSIVE_CHANNEL, limit: 50).returns([])
    SlackService.stubs(:get_messages_since).returns([ passive_message(passive_ts(1.minute)) ])

    SlackTriggerPollerJob.new.send(:process_condition, condition)

    # Neither cleared nor advanced — a thread condition does not own this signal.
    assert_equal engagement_ts, condition.reload.bot_activity_timestamps[PASSIVE_CHANNEL]
  end

  test "a trigger carrying both conditions fires on either signal" do
    thread_condition = stub_passive_listening(event_type: "passive_listen_thread")
    trigger = thread_condition.trigger
    channel_condition = trigger.trigger_conditions.create!(
      condition_type: "slack",
      configuration: {
        "event_type" => "passive_listen_channel",
        "channel_timestamps" => { PASSIVE_CHANNEL => passive_ts(3.hours) },
        "bot_activity_timestamps" => { PASSIVE_CHANNEL => passive_ts(1.hour) }
      }
    )

    parent_ts = passive_ts(5.hours)
    bot_reply_ts = passive_ts(2.hours)
    new_reply_ts = passive_ts(1.minute)
    top_level_ts = passive_ts(2.minutes)

    thread_condition.configuration["channel_timestamps"] = { PASSIVE_CHANNEL => passive_ts(3.hours) }
    thread_condition.save!

    SlackService.stubs(:get_channel_history).with(PASSIVE_CHANNEL, limit: 50).returns([
      OpenStruct.new(ts: parent_ts, reply_count: 2, latest_reply: new_reply_ts, user: "U222", thread_ts: nil, bot_id: nil)
    ])
    SlackService.stubs(:get_thread_replies).with(PASSIVE_CHANNEL, parent_ts, oldest: nil).returns([
      OpenStruct.new(ts: bot_reply_ts, text: "On it.", user: "U_BOT_123", bot_id: "B_ZIMMER", thread_ts: parent_ts),
      OpenStruct.new(ts: new_reply_ts, text: "any update?", user: "U222", bot_id: nil, thread_ts: parent_ts)
    ])
    SlackService.stubs(:get_messages_since).returns([ passive_message(top_level_ts) ])

    # The thread reply fires the thread condition; the top-level message fires the
    # channel condition. This is the whole point of splitting them.
    job = SlackTriggerPollerJob.new
    assert_difference("Session.count", 2) do
      job.send(:process_condition, thread_condition)
      job.send(:process_condition, channel_condition)
    end

    # Each condition keeps its own bookkeeping.
    thread_condition.reload
    channel_condition.reload
    assert_includes thread_condition.participating_threads, "#{PASSIVE_CHANNEL}:#{parent_ts}"
    assert_empty thread_condition.bot_activity_timestamps
    assert_empty channel_condition.thread_timestamps
  end

  test "deprecated passive_listen does not count an in-thread reply as channel engagement" do
    condition = stub_passive_listening(event_type: "passive_listen")
    parent_ts = passive_ts(5.hours)
    bot_reply_ts = passive_ts(1.hour)
    new_reply_ts = passive_ts(2.minutes)

    condition.configuration["channel_timestamps"] = { PASSIVE_CHANNEL => passive_ts(3.hours) }
    condition.save!

    # Zimmer replied inside a thread an hour ago and has never posted at the top
    # level. The thread reply fires; the top-level message must not.
    SlackService.stubs(:get_channel_history).with(PASSIVE_CHANNEL, limit: 50).returns([
      OpenStruct.new(ts: parent_ts, reply_count: 2, latest_reply: new_reply_ts, user: "U222", thread_ts: nil, bot_id: nil)
    ])
    SlackService.stubs(:get_thread_replies).with(PASSIVE_CHANNEL, parent_ts, oldest: nil).returns([
      OpenStruct.new(ts: bot_reply_ts, text: "On it.", user: "U_BOT_123", bot_id: "B_ZIMMER", thread_ts: parent_ts),
      OpenStruct.new(ts: new_reply_ts, text: "any update?", user: "U222", bot_id: nil, thread_ts: parent_ts)
    ])
    SlackService.stubs(:get_messages_since).returns([ passive_message(passive_ts(1.minute)) ])

    assert_difference("Session.count", 1) do
      SlackTriggerPollerJob.new.send(:process_condition, condition)
    end

    assert_empty condition.reload.bot_activity_timestamps
  end

  test "deprecated passive_listen fires on both signals at once" do
    condition = stub_passive_listening(event_type: "passive_listen")
    parent_ts = passive_ts(5.hours)
    bot_reply_ts = passive_ts(2.hours)
    new_reply_ts = passive_ts(1.minute)

    condition.configuration["channel_timestamps"] = { PASSIVE_CHANNEL => passive_ts(3.hours) }
    condition.configuration["bot_activity_timestamps"] = { PASSIVE_CHANNEL => passive_ts(1.hour) }
    condition.save!

    SlackService.stubs(:get_channel_history).with(PASSIVE_CHANNEL, limit: 50).returns([
      OpenStruct.new(ts: parent_ts, reply_count: 2, latest_reply: new_reply_ts, user: "U222", thread_ts: nil, bot_id: nil)
    ])
    SlackService.stubs(:get_thread_replies).with(PASSIVE_CHANNEL, parent_ts, oldest: nil).returns([
      OpenStruct.new(ts: bot_reply_ts, text: "On it.", user: "U_BOT_123", bot_id: "B_ZIMMER", thread_ts: parent_ts),
      OpenStruct.new(ts: new_reply_ts, text: "any update?", user: "U222", bot_id: nil, thread_ts: parent_ts)
    ])
    SlackService.stubs(:get_messages_since).returns([ passive_message(passive_ts(2.minutes)) ])

    # One from the thread reply, one from the top-level message.
    assert_difference("Session.count", 2) do
      SlackTriggerPollerJob.new.send(:process_condition, condition)
    end
  end

  # --- Burst control -------------------------------------------------------
  #
  # The incident: a burst of messages landed in the alerts channel and this
  # poller spawned one session per message. A single tick can carry many
  # messages, so the cap has to bound spawns WITHIN a tick, not just across
  # ticks.

  def stub_slack_burst(messages)
    SlackService.stubs(:configured?).returns(true)
    SlackService.stubs(:get_messages_since).returns(messages)
    SlackService.stubs(:get_message_permalink).returns("https://slack.com/msg/123")
    SlackService.stubs(:get_user_name).returns("Alertmanager")

    mock_agent_root = OpenStruct.new(
      url: "https://github.com/test/repo",
      default_branch: "main",
      subdirectory: nil
    )
    AgentRootsConfig.stubs(:find!).returns(mock_agent_root)
    AgentSessionJob.stubs(:enqueue_new_session)
  end

  def alert_messages(count, start_ts: 1704067300)
    Array.new(count) do |i|
      OpenStruct.new(
        ts: format("%d.000000", start_ts + i),
        text: "ALERT #{i}: service is down",
        bot_id: nil,
        thread_ts: nil,
        user: "U111"
      )
    end
  end

  test "a 20-message tick with a limit of 3 spawns exactly 3 sessions plus one burst notice" do
    stub_slack_burst(alert_messages(20))
    @trigger.update!(max_sessions_per_minute: 3)

    job = SlackTriggerPollerJob.new

    assert_difference("Session.count", 4) do
      job.send(:process_condition, @condition)
    end

    sessions = Session.where("metadata->>'trigger_id' = ?", @trigger.id.to_s).to_a
    notices = sessions.select { |s| s.metadata["burst_notice"] }
    assert_equal 1, notices.size
    assert_equal 3, (sessions - notices).size
    assert @trigger.reload.bursting?

    # The suppressed messages are dropped, not replayed: the cursor still advanced.
    assert_equal "1704067319.000000", @condition.reload.last_message_ts
  end

  test "a continuing burst on the next tick spawns zero sessions and zero further notices" do
    stub_slack_burst(alert_messages(20))
    @trigger.update!(max_sessions_per_minute: 3)

    job = SlackTriggerPollerJob.new
    job.send(:process_condition, @condition)
    assert_equal 4, Session.where("metadata->>'trigger_id' = ?", @trigger.id.to_s).count

    # Next tick, one minute later: the outage is still producing alerts.
    travel 1.minute do
      stub_slack_burst(alert_messages(20, start_ts: 1704067400))

      assert_no_difference("Session.count") do
        SlackTriggerPollerJob.new.send(:process_condition, @condition.reload)
      end
    end

    sessions = Session.where("metadata->>'trigger_id' = ?", @trigger.id.to_s).to_a
    assert_equal 4, sessions.size
    assert_equal 1, sessions.count { |s| s.metadata["burst_notice"] }
  end

  test "a 20-message tick with no limit set spawns 20 sessions, exactly as before" do
    stub_slack_burst(alert_messages(20))
    assert_nil @trigger.max_sessions_per_minute

    assert_difference("Session.count", 20) do
      SlackTriggerPollerJob.new.send(:process_condition, @condition)
    end

    sessions = Session.where("metadata->>'trigger_id' = ?", @trigger.id.to_s).to_a
    assert_empty sessions.select { |s| s.metadata["burst_notice"] }
  end

  # --- Deferral on transient Slack failures (#77) ----------------------------
  #
  # This job is a `total_limit: 1` singleton, so while it runs it IS Slack
  # polling for the whole instance and every cron tick that lands meanwhile is
  # rejected. Waiting out a Slack outage inside the run therefore drops ticks for
  # every trigger; rescheduling the run gives the worker thread back instead.

  test "a transient Slack failure reschedules the poll instead of alerting" do
    SlackService.stubs(:configured?).returns(true)

    job = SlackTriggerPollerJob.new
    job.stubs(:process_condition)
       .raises(SlackService::TransientError, "Network error communicating with Slack: timeout")

    # Not a per-condition defect, so no alert — and the sweep stops rather than
    # grinding every remaining condition into the same wall.
    AlertService.expects(:raise_alert).never
    job.expects(:retry_job).with(wait: 30)

    job.perform_now
  end

  test "a non-transient condition error still alerts and does not defer" do
    SlackService.stubs(:configured?).returns(true)

    job = SlackTriggerPollerJob.new
    job.stubs(:process_condition).raises(StandardError, "bad condition")

    job.expects(:retry_job).never
    AlertService.expects(:raise_alert).at_least_once

    job.perform_now
  end

  test "deferral delay backs off exponentially and is capped" do
    job = SlackTriggerPollerJob.new
    error = SlackService::TransientError.new("boom")

    delays = (0..5).map do |spent|
      job.instance_variable_set(:@deferrals, spent)
      job.send(:deferral_delay, error)
    end

    assert_equal [ 30, 60, 120, 240, 480, 600 ], delays
    assert delays.all? { |d| d <= SlackTriggerPollerJob::MAX_DEFERRAL_DELAY }
  end

  test "a rate limit's retry_after floors the deferral delay" do
    job = SlackTriggerPollerJob.new

    long = SlackService::RateLimitedError.new("ratelimited", retry_after: 120)
    assert_equal 120, job.send(:deferral_delay, long), "Slack's own wait should win when longer"

    short = SlackService::RateLimitedError.new("ratelimited", retry_after: 5)
    assert_equal 30, job.send(:deferral_delay, short), "backoff should win when longer"

    unspecified = SlackService::RateLimitedError.new("ratelimited", retry_after: nil)
    assert_equal 30, job.send(:deferral_delay, unspecified), "a nil retry_after must not blow up"
  end

  test "stops deferring and alerts once MAX_DEFERRALS is spent" do
    job = SlackTriggerPollerJob.new
    job.instance_variable_set(:@deferrals, SlackTriggerPollerJob::MAX_DEFERRALS)

    job.expects(:retry_job).never
    AlertService.expects(:raise_alert).once

    job.send(:defer_poll, SlackService::TransientError.new("still down"))
  end

  # The deferral count rides in the job's own serialized params, NOT in
  # `executions` — which also counts ActiveRecord::StatementTimeout retries from
  # ApplicationJob and GoodJob's own ConcurrencyExceededError retries. Reading
  # those as deferrals would inflate the backoff and make the give-up alert claim
  # a Slack outage that never happened.
  test "the deferral count survives a reschedule and ignores unrelated retries" do
    job = SlackTriggerPollerJob.new
    job.stubs(:retry_job)

    job.send(:defer_poll, SlackService::TransientError.new("down"))
    assert_equal 1, job.send(:deferral_count)
    assert_equal 1, job.serialize["deferrals"]

    revived = SlackTriggerPollerJob.new
    revived.deserialize(job.serialize)
    assert_equal 1, revived.send(:deferral_count)

    # A retry that has nothing to do with Slack must not advance the backoff.
    revived.executions = 9
    assert_equal 60, revived.send(:deferral_delay, SlackService::TransientError.new("down"))
  end

  # The sweep's per-unit rescues swallow so the batched cursor writes for units
  # that already succeeded still happen — but the poll must still end in a
  # deferral rather than a "success" the cron re-hammers 60 seconds later.
  test "a transient failure swallowed by an inner rescue still defers the poll" do
    SlackService.stubs(:configured?).returns(true)

    job = SlackTriggerPollerJob.new
    # Stands in for the inner per-unit rescues: the failure is recorded, the sweep
    # completes normally, and nothing propagates out of the condition loop.
    job.define_singleton_method(:process_condition) do |_condition|
      note_transient(SlackService::RateLimitedError.new("ratelimited", retry_after: nil))
    end

    job.expects(:retry_job).with(wait: 30)

    job.perform_now
  end

  test "note_transient ignores errors that are not transient" do
    job = SlackTriggerPollerJob.new

    job.send(:note_transient, StandardError.new("unrelated"))
    assert_nil job.instance_variable_get(:@transient_error)

    job.send(:note_transient, SlackService::ApiError.new("channel_not_found"))
    assert_nil job.instance_variable_get(:@transient_error)
  end

  # A transient failure fetching the permalink must NOT drop the message: every
  # caller of #process_message advances its cursor past the message whether or not
  # a session came out of it, so raising here would delete it rather than defer it.
  test "a rate-limited permalink degrades to nil instead of losing the message" do
    stub_slack_burst(alert_messages(1))
    SlackService.stubs(:get_message_permalink)
                .raises(SlackService::RateLimitedError.new("ratelimited", retry_after: 60))

    assert_difference("Session.count", 1) do
      SlackTriggerPollerJob.new.send(:process_condition, @condition)
    end
  end

  # --- Severity of a recovered rate limit (#509) ------------------------------
  #
  # A 429 the deferral absorbs used to log at ERROR, and a single ERROR line trips
  # the "any Zimmer ERROR → critical" Grafana rule. A 111-second rate-limit burst
  # across nine threads therefore paged the on-call about an incident in which
  # nothing was lost: every thread was re-read on the deferred poll. Twice.
  #
  # So the two directions below are one fix, and the second half is the half that
  # matters — a change that also silenced the real failure would be worse than the
  # bug it fixed.

  # Copied from the production records (2026-08-17T09:46:07Z onward) so the
  # assertions below read against the real thing. It is a fixture, not a canary:
  # SlackService builds this string, and nothing here would notice if it changed.
  PRODUCTION_429 = "Slack rate limit exceeded: Retry after 10 seconds"

  def production_rate_limit
    SlackService::RateLimitedError.new(PRODUCTION_429, retry_after: 10)
  end

  # Swap Rails.logger for a StringIO-backed logger whose formatter keeps the
  # severity, so a test can assert the LEVEL a line was written at rather than
  # merely that it was written. StringIO-backed rather than a mocha expectation on
  # the shared logger, so a concurrent writer cannot invalidate the assertion.
  def capture_log_lines
    original_logger = Rails.logger
    buffer = StringIO.new
    logger = ActiveSupport::Logger.new(buffer)
    logger.formatter = proc { |severity, _time, _progname, msg| "#{severity} #{msg}\n" }
    Rails.logger = logger

    yield

    buffer.string.lines.map(&:chomp).grep(/SlackTriggerPollerJob/)
  ensure
    Rails.logger = original_logger
  end

  # The bot_mention half of the burst: "Error checking thread <ts> in <channel>".
  #
  # Driven through the whole job — real sweep, real thread scan, real deferral — so
  # this is evidence about the poll's behaviour and not about one method's.
  test "a rate-limited thread check logs below ERROR and defers the poll" do
    SlackService.stubs(:configured?).returns(true)
    SlackService.stubs(:bot_user_id).returns("U_BOT_123")
    SlackService.stubs(:list_dm_channels).returns([])

    condition = trigger_conditions(:bot_mention_slack_condition)
    thread_ts = "1704067000.000000"
    thread_key = "#{condition.channel_id}:#{thread_ts}"
    condition.configuration["thread_timestamps"] = { thread_key => "1704067400.000000" }
    condition.save!
    # Leave this condition as the only one the sweep will visit, so the assertions
    # below are about it and nothing else.
    Trigger.where.not(id: condition.trigger_id).update_all(status: "disabled")

    SlackService.stubs(:get_messages_since).returns([])
    SlackService.stubs(:get_channel_history).with(condition.channel_id, limit: 50).returns([
      OpenStruct.new(ts: thread_ts, text: "Original", reply_count: 2,
                     latest_reply: "1704067500.000000", bot_id: nil, thread_ts: nil, user: "U222")
    ])
    SlackService.stubs(:get_thread_replies).raises(production_rate_limit)

    job = SlackTriggerPollerJob.new
    # Slack is throttling us, not misbehaving: no alert, and the poll comes back in
    # 30s (the backoff floor, which outlives Slack's own 10s Retry-After).
    AlertService.expects(:raise_alert).never
    job.expects(:retry_job).with(wait: 30)

    lines = capture_log_lines { job.perform_now }

    assert_empty lines.grep(/^ERROR/),
      "a rate limit the deferral absorbs must not log at ERROR — that is the line that pages"
    assert_equal 1, lines.grep(/^WARN.*checking thread #{Regexp.escape(thread_ts)} in #{condition.channel_id}/).size,
      "the per-thread line must survive at WARN, message content intact"
    assert lines.any? { |line| line.start_with?("WARN") && line.include?(PRODUCTION_429) },
      "Slack's own words must still be in the log — only the severity was wrong"

    # And nothing was lost: the thread's cursor never moved, so the deferred poll
    # re-reads exactly the replies this one failed to read.
    assert_equal "1704067400.000000", condition.reload.thread_timestamps[thread_key]
  end

  # The passive half of the same burst: "Error passively checking thread <ts> in
  # <channel>". Same rescue shape, separate code path, separately regressible.
  test "a rate-limited passive thread check logs below ERROR and records the failure for deferral" do
    condition = stub_passive_listening(event_type: "passive_listen_thread")
    parent_ts = passive_ts(5.hours)
    thread_key = "#{PASSIVE_CHANNEL}:#{parent_ts}"
    condition.configuration["channel_timestamps"] = { PASSIVE_CHANNEL => passive_ts(3.hours) }
    condition.save!

    SlackService.stubs(:get_messages_since).returns([])
    SlackService.stubs(:get_channel_history).with(PASSIVE_CHANNEL, limit: 50).returns([
      OpenStruct.new(ts: parent_ts, reply_count: 2, latest_reply: passive_ts(1.minute),
                     user: "U222", thread_ts: nil, bot_id: nil)
    ])
    SlackService.stubs(:get_thread_replies).raises(production_rate_limit)

    job = SlackTriggerPollerJob.new
    lines = capture_log_lines { job.send(:process_condition, condition) }

    assert_empty lines.grep(/^ERROR/),
      "a rate limit the deferral absorbs must not log at ERROR — that is the line that pages"
    assert_equal 1, lines.grep(/^WARN.*passively checking thread #{Regexp.escape(parent_ts)} in #{PASSIVE_CHANNEL}/).size,
      "the per-thread line must survive at WARN, message content intact"

    # The failure is still on the record, so the end of the poll defers it.
    assert_instance_of SlackService::RateLimitedError, job.instance_variable_get(:@transient_error)
    assert_nil condition.reload.thread_timestamps[thread_key],
      "an unread thread must not get a cursor — the deferred poll has to re-read it"
  end

  # The half that matters. A 429 that OUTLIVES its deferrals has stopped being
  # recovered: the retry budget is spent, Slack has been unavailable for roughly a
  # quarter of an hour, and polling really has failed. That still logs at ERROR, so
  # it still pages.
  test "a rate limit that survives its deferrals logs at ERROR so it still pages" do
    job = SlackTriggerPollerJob.new
    job.instance_variable_set(:@deferrals, SlackTriggerPollerJob::MAX_DEFERRALS)

    job.expects(:retry_job).never
    AlertService.expects(:raise_alert).once

    lines = capture_log_lines { job.send(:defer_poll, production_rate_limit) }

    errors = lines.grep(/^ERROR/)
    assert_equal 1, errors.size, "the give-up line is the one ERROR this job may emit"
    assert_match(/after #{SlackTriggerPollerJob::MAX_DEFERRALS} deferrals/, errors.first)
    assert_includes errors.first, PRODUCTION_429
  end

  # Demotion is a property of the call site, not of the error. `#fetch_recent_history`
  # is not a unit boundary: it degrades to [] and its callers finish the same sweep
  # believing that slice was complete, advancing cursors past messages the empty
  # slice hid. Those are lost rather than deferred, so it keeps its ERROR.
  test "a rate-limited recent-history fetch keeps its ERROR, because the sweep loses messages" do
    job = SlackTriggerPollerJob.new
    SlackService.stubs(:get_channel_history).raises(production_rate_limit)

    lines = capture_log_lines do
      assert_empty job.send(:fetch_recent_history, "C_GENERAL")
    end

    assert_equal 1, lines.grep(/^ERROR.*fetching recent history for C_GENERAL/).size,
      "a failure the deferral cannot undo must still page"
    assert_instance_of SlackService::RateLimitedError, job.instance_variable_get(:@transient_error),
      "and it must still defer the poll"
  end

  # Nor is this blanket suppression: only a transient Slack failure is demoted. A
  # per-unit defect the deferral cannot fix — a renamed channel, a bad cursor, a bug
  # in this file — is still a defect, and still pages.
  test "a per-unit failure that is not transient keeps its ERROR" do
    job = SlackTriggerPollerJob.new

    lines = capture_log_lines do
      job.send(:note_unit_failure, SlackService::ApiError.new("channel_not_found"), "checking thread 1.0 in C1")
      job.send(:note_unit_failure, StandardError.new("undefined method for nil"), "polling DMs for user U1")
    end

    assert_equal 2, lines.grep(/^ERROR/).size, "a real per-unit failure must still page"
    assert_empty lines.grep(/^WARN/)
    assert_nil job.instance_variable_get(:@transient_error),
      "a non-transient failure must not be mistaken for a reason to defer"
  end
end
