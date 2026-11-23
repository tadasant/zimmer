# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"
require "ostruct"

# The @mention that invites the bot to a channel.
#
# Somebody mentions the bot in a channel it is not in, Slack offers to invite it, they accept. The
# next poll meets that channel for the first time, with the mention already in its history. A plain
# baseline — the newest message, nothing older — takes the bot's own join notice as the cursor and
# drops the mention. These tests drive one poll against a fake channel history and assert both
# directions: the mention fires, and nothing that is history does.
class SlackTriggerPollerJustJoinedTest < ActiveJob::TestCase
  CHANNEL = "C0JUSTJOINED"
  BOT = "U_BOT_123"
  ALLOWED = "U222"

  setup do
    SlackService.stubs(:configured?).returns(true)
    SlackService.stubs(:bot_user_id).returns(BOT)
    SlackService.stubs(:list_dm_channels).returns([])
    SlackService.stubs(:list_member_channels).returns([ OpenStruct.new(id: CHANNEL, name: "joined", is_member: true) ])
    SlackService.stubs(:get_channel).returns(OpenStruct.new(name: "joined"))
    SlackService.stubs(:get_message_permalink).returns("https://slack.example/msg")
    SlackService.stubs(:get_user_name).returns("Test User")
    AgentRootsConfig.stubs(:find!).returns(
      OpenStruct.new(url: "https://github.com/test/repo", default_branch: "main", subdirectory: nil)
    )
    AgentSessionJob.stubs(:enqueue_new_session)

    @condition = trigger_conditions(:bot_mention_all_channels_condition)
    prepare(@condition)
  end

  teardown { Mocha::Mockery.instance.teardown }

  test "the mention that invited the bot fires, and the cursor lands on the newest message" do
    join = join_notice(20.seconds)
    channel_history(mention(24.seconds), join)

    assert_difference("Session.count", 1) { poll }

    assert_equal join.ts, @condition.reload.channel_timestamps[CHANNEL]
    assert_no_difference("Session.count") { poll }
  end

  test "a mention made between the join and the poll that meets the channel fires too" do
    newest = slack_message(5.seconds, text: "no mention here")
    channel_history(join_notice(40.seconds), mention(30.seconds), newest)

    assert_difference("Session.count", 1) { poll }
    assert_equal newest.ts, @condition.reload.channel_timestamps[CHANNEL]
  end

  test "a private channel's join notice counts" do
    channel_history(mention(24.seconds), join_notice(20.seconds, subtype: "group_join"))

    assert_difference("Session.count", 1) { poll }
  end

  test "a mention in a thread reply that invited the bot fires" do
    reply = slack_message(24.seconds, text: "<@#{BOT}> help", thread_ts: ts(2.days))
    parent = slack_message(2.days, text: "an old thread", reply_count: 1, latest_reply: reply.ts)
    channel_history(parent, join_notice(20.seconds), replies: [ reply ])

    assert_difference("Session.count", 1) { poll }
    assert_equal reply.ts, @condition.reload.thread_timestamps["#{CHANNEL}:#{parent.ts}"]
  end

  test "a condition scoped to one channel catches the mention that invited the bot to it" do
    @condition = trigger_conditions(:bot_mention_slack_condition)
    prepare(@condition, "channel_id" => CHANNEL)
    join = join_notice(20.seconds)
    channel_history(mention(24.seconds), join)

    assert_difference("Session.count", 1) { poll }
    assert_equal join.ts, @condition.reload.last_message_ts
  end

  # --- what stays history ---------------------------------------------------

  test "a mention older than the lookback before the join does not fire" do
    channel_history(mention(SlackTriggerPollerJob::JOIN_LOOKBACK + 1.minute), join_notice(20.seconds))

    assert_no_difference("Session.count") { poll }
  end

  test "a thread reply older than the lookback before the join does not fire" do
    reply = slack_message(SlackTriggerPollerJob::JOIN_LOOKBACK + 1.minute, text: "<@#{BOT}> help", thread_ts: ts(2.days))
    parent = slack_message(2.days, text: "an old thread", reply_count: 1, latest_reply: reply.ts)
    channel_history(parent, join_notice(20.seconds), replies: [ reply ])

    assert_no_difference("Session.count") { poll }
  end

  test "a channel the bot joined a while ago only baselines, however recent the mention" do
    newest = mention(10.seconds)
    channel_history(join_notice(SlackTriggerPollerJob::JOIN_FRESHNESS + 1.minute), newest)

    assert_no_difference("Session.count") { poll }
    assert_equal newest.ts, @condition.reload.channel_timestamps[CHANNEL]
  end

  test "a quiet channel baselines on its newest message without reading its history" do
    newest = mention(3.days)
    channel_history(newest)

    assert_no_difference("Session.count") { poll }
    assert_empty @slack.history_calls.select { |params| params[:oldest] }
    assert_equal newest.ts, @condition.reload.channel_timestamps[CHANNEL]
  end

  test "somebody else joining is not the bot joining" do
    channel_history(mention(24.seconds), join_notice(20.seconds, user: "U_SOMEONE"))

    assert_no_difference("Session.count") { poll }
  end

  test "a condition's first poll only baselines" do
    @condition.update_column(:last_polled_at, nil)
    channel_history(mention(24.seconds), join_notice(20.seconds))

    assert_no_difference("Session.count") { poll }
  end

  test "a condition created after the join only baselines, and a lookback never reaches past its creation" do
    channel_history(mention(5.minutes), join_notice(2.minutes))

    @condition.update_column(:created_at, 1.minute.ago)
    assert_no_difference("Session.count") { poll }

    prepare(@condition)
    @condition.update_column(:created_at, 3.minutes.ago)
    channel_history(mention(5.minutes), join_notice(2.minutes))
    assert_no_difference("Session.count") { poll }
  end

  test "a lost cursor does not fire the same mention twice" do
    channel_history(mention(24.seconds), join_notice(20.seconds))
    assert_difference("Session.count", 1) { poll }

    @condition.reload.update_column(:configuration, @condition.configuration.except("channel_timestamps"))

    assert_no_difference("Session.count") { poll }
  end

  test "a lost cursor does not fire the same thread reply twice" do
    reply = slack_message(24.seconds, text: "<@#{BOT}> help", thread_ts: ts(2.days))
    parent = slack_message(2.days, text: "an old thread", reply_count: 1, latest_reply: reply.ts)
    channel_history(parent, join_notice(20.seconds), replies: [ reply ])
    assert_difference("Session.count", 1) { poll }

    @condition.reload.update_column(
      :configuration, @condition.configuration.except("channel_timestamps", "thread_timestamps")
    )

    assert_no_difference("Session.count") { poll }
  end

  test "a mention Slack's Events API already fired does not fire again" do
    Webhooks::Source.slack.stubs(:webhook_enabled?).returns(true)
    invite = mention(24.seconds)
    TriggerEventClaim.claim!(@condition, [ TriggerEventClaim.slack_event_key(CHANNEL, invite.ts) ], via: "webhook")
    channel_history(invite, join_notice(20.seconds))

    assert_no_difference("Session.count") { poll }
  end

  # --- who may fire it ------------------------------------------------------

  test "a user outside the allow-list cannot fire it, and the bot's own join notice never does" do
    notice = join_notice(20.seconds)
    notice.text = "<@#{BOT}> has joined the channel"
    channel_history(slack_message(24.seconds, text: "<@#{BOT}> help", user: "U_STRANGER"), notice)

    assert_no_difference("Session.count") { poll }
    assert_equal notice.ts, @condition.reload.channel_timestamps[CHANNEL]
  end

  test "an allow-list that cannot be resolved fires nothing and leaves the cursor for the next poll" do
    channel_history(mention(24.seconds), join_notice(20.seconds))
    TriggerCondition.any_instance.stubs(:user_allowed?).raises(ParameterStore::StoreError, "store unreachable")

    assert_no_difference("Session.count") { poll }
    assert_nil @condition.reload.channel_timestamps[CHANNEL]

    TriggerCondition.any_instance.unstub(:user_allowed?)
    assert_difference("Session.count", 1) { poll }
  end

  test "a history read Slack throws away leaves the channel for the deferred poll" do
    channel_history(mention(24.seconds), join_notice(20.seconds))
    @slack.failure = SlackService::RateLimitedError.new("rate limited")

    assert_no_difference("Session.count") { poll }
    assert_nil @condition.reload.channel_timestamps[CHANNEL]

    @slack.failure = nil
    assert_difference("Session.count", 1) { poll }
  end

  private

  def poll
    SlackTriggerPollerJob.new.send(:process_condition, TriggerCondition.find(@condition.id))
  end

  # An enabled condition the poller has been running for a while, that has never seen CHANNEL.
  def prepare(condition, extra = {})
    condition.update_columns(
      configuration: { "event_type" => "bot_mention", "allowed_user_ids" => [ ALLOWED ] }.merge(extra),
      last_message_ts: nil, last_polled_at: 1.minute.ago, created_at: 1.week.ago
    )
  end

  def ts(ago)
    format("%.6f", (@now ||= Time.current).to_f - ago.to_f)
  end

  def slack_message(ago, text:, user: ALLOWED, **attrs)
    OpenStruct.new(ts: ts(ago), text: text, user: user, bot_id: nil, thread_ts: nil, **attrs)
  end

  def mention(ago)
    slack_message(ago, text: "<@#{BOT}> can you help?")
  end

  def join_notice(ago, user: BOT, subtype: "channel_join")
    slack_message(ago, text: "<@#{user}> has joined the channel", user: user, subtype: subtype)
  end

  def channel_history(*messages, replies: [])
    @slack = FakeSlackClient.new(messages, replies)
    SlackService.stubs(:client).returns(@slack)
  end

  # The two reads the poller makes of a channel, answered the way Slack answers them: newest first,
  # `oldest` exclusive, and every reply of a thread for a replies call. One channel, one thread.
  class FakeSlackClient
    attr_reader :history_calls
    attr_accessor :failure

    def initialize(messages, replies)
      @messages = messages.sort_by(&:ts).reverse
      @replies = replies
      @history_calls = []
    end

    def conversations_history(**params)
      @history_calls << params
      raise failure if failure && params[:oldest]

      found = @messages.select { |message| params[:oldest].nil? || message.ts > params[:oldest] }
      OpenStruct.new(messages: found.first(params[:limit]))
    end

    def conversations_replies(**_params)
      OpenStruct.new(messages: @replies.dup)
    end
  end
end
