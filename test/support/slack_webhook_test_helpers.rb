# frozen_string_literal: true

require "ostruct"

# Shared setup for the Slack webhook tests: a signing secret, the ingest mode, Slack stubbed at
# the service boundary, and one enabled Slack trigger with every other trigger switched off so
# "exactly one session" means this trigger's session.
module SlackWebhookTestHelpers
  SIGNING_SECRET = "8f742231b10e8888abcd99yyyzzz85a5"
  CHANNEL = "C0A6BF8T45R"
  BOT_ID = "U_ZIMMER_BOT"
  ENV_KEYS = %w[SLACK_TRIGGER_INGEST_MODE SLACK_SIGNING_SECRET].freeze

  def setup_slack_webhook(mode: "webhook_with_poll_fallback", secret: SIGNING_SECRET)
    @saved_webhook_env = ENV_KEYS.to_h { |key| [ key, ENV[key] ] }
    ENV_KEYS.each { |key| ENV.delete(key) }
    ENV["SLACK_TRIGGER_INGEST_MODE"] = mode if mode
    ENV["SLACK_SIGNING_SECRET"] = secret if secret

    SlackService.stubs(:configured?).returns(true)
    SlackService.stubs(:bot_user_id).returns(BOT_ID)
    SlackService.stubs(:get_user_name).returns("Alice")
    SlackService.stubs(:get_message_permalink).returns("https://slack.example/archives/#{CHANNEL}/p1")
    AgentRootsConfig.stubs(:find!).returns(
      OpenStruct.new(url: "https://github.com/test/repo", default_branch: "main", subdirectory: nil)
    )
    AgentSessionJob.stubs(:enqueue_new_session)

    @trigger = triggers(:enabled_slack_trigger)
    @condition = trigger_conditions(:enabled_slack_condition)
    Trigger.where.not(id: @trigger.id).update_all(status: "disabled")
  end

  def teardown_slack_webhook
    @saved_webhook_env&.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
    Mocha::Mockery.instance.teardown
  end

  # Replace the fixture condition's configuration without its callbacks, which would
  # otherwise merge poll state across or re-baseline a thread change.
  def configure_condition(configuration)
    @condition.update_columns(configuration: configuration)
    @condition.reload
  end

  def slack_event(ts:, text: "the build is red", user: "U_ALICE", channel: CHANNEL, channel_type: "channel",
                  type: "message", thread_ts: nil, **extra)
    { "type" => type, "channel" => channel, "channel_type" => channel_type, "user" => user,
      "text" => text, "ts" => ts, "thread_ts" => thread_ts }.compact.merge(extra.transform_keys(&:to_s))
  end

  def event_callback(event, event_id: "Ev#{SecureRandom.hex(4)}")
    { "token" => "legacy", "team_id" => "T0001", "api_app_id" => "A0001", "type" => "event_callback",
      "event_id" => event_id, "event_time" => event["ts"].to_i, "event" => event }
  end

  # A message as SlackService returns it to the poller.
  def polled_message(ts:, text: "the build is red", user: "U_ALICE", thread_ts: nil)
    OpenStruct.new(ts: ts, text: text, user: user, bot_id: nil, username: nil, thread_ts: thread_ts, subtype: nil)
  end

  # Run the real poller over +messages+ as if conversations.history had returned them.
  def poll_channel(messages)
    SlackService.stubs(:get_messages_since).returns(messages)
    SlackTriggerPollerJob.new.send(:process_condition, @condition.reload)
  end
end
