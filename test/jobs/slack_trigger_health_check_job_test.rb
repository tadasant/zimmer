# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"
require "ostruct"

class SlackTriggerHealthCheckJobTest < ActiveJob::TestCase
  setup do
    @condition = trigger_conditions(:enabled_slack_condition) # channel C0A6BF8T45R, last_message_ts "1704067200.000000"
  end

  teardown do
    Mocha::Mockery.instance.teardown
  end

  # A timestamp newer than the condition's processed baseline but, being from
  # 2024, far more than the staleness threshold (3h) in the past — i.e. stalled.
  STALLED_TS = "1704067260.000000"

  # A timestamp newer than the baseline AND recent enough to be within threshold.
  def recent_ts
    format("%.6f", Time.now.to_f - 60)
  end

  test "job does nothing when Slack is not configured" do
    SlackService.stubs(:configured?).returns(false)
    ErrorReporter.expects(:report_message).never

    assert_nothing_raised do
      SlackTriggerHealthCheckJob.perform_now
    end
  end

  test "alerts when a new_message condition has fallen hours behind" do
    SlackService.stubs(:configured?).returns(true)
    SlackService.stubs(:get_channel_history)
      .with(@condition.channel_id, limit: SlackTriggerHealthCheckJob::HISTORY_SCAN_LIMIT)
      .returns([ OpenStruct.new(ts: STALLED_TS, thread_ts: nil) ])

    # Both halves of the page: the ERROR record (which is what trips the Grafana
    # rule — this detector has no other log line at all) and the GlitchTip event.
    reports = []
    entries = nil
    ErrorReporter.stub(:report_message, ->(message, context: {}, level: :error) {
      reports << [ message, context, level ]
    }) do
      entries = capture_log_entries { SlackTriggerHealthCheckJob.new.send(:check_condition, @condition) }
    end

    assert_equal 1, reports.size
    message, context, level = reports.first
    assert_equal "Slack trigger feed stalled", message
    assert_equal :error, level
    assert_equal "SlackTriggerHealthCheckJob", context[:source]
    assert_equal @condition.id, context[:condition_id]
    assert_equal @condition.trigger_id, context[:trigger_id]

    errors = entries.select { |severity, _message| severity == "ERROR" }
    assert_equal 1, errors.size, "a stalled feed must emit exactly one ERROR record — that is the page"
    assert_match(/Slack trigger feed stalled/, errors.first.last)
  end

  test "does not alert when the condition is caught up" do
    SlackService.stubs(:configured?).returns(true)
    # Newest available message equals what the poller already processed
    SlackService.stubs(:get_channel_history)
      .with(@condition.channel_id, limit: SlackTriggerHealthCheckJob::HISTORY_SCAN_LIMIT)
      .returns([ OpenStruct.new(ts: @condition.last_message_ts, thread_ts: nil) ])

    ErrorReporter.expects(:report_message).never

    SlackTriggerHealthCheckJob.new.send(:check_condition, @condition)
  end

  test "does not alert when the newest message is recent (within threshold)" do
    SlackService.stubs(:configured?).returns(true)
    SlackService.stubs(:get_channel_history)
      .with(@condition.channel_id, limit: SlackTriggerHealthCheckJob::HISTORY_SCAN_LIMIT)
      .returns([ OpenStruct.new(ts: recent_ts, thread_ts: nil) ])

    ErrorReporter.expects(:report_message).never

    SlackTriggerHealthCheckJob.new.send(:check_condition, @condition)
  end

  test "does not alert when the condition has no baseline yet" do
    SlackService.stubs(:configured?).returns(true)
    @condition.update!(last_message_ts: nil)

    # No baseline → nothing to fall behind on; Slack should not even be queried
    SlackService.expects(:get_channel_history).never
    ErrorReporter.expects(:report_message).never

    SlackTriggerHealthCheckJob.new.send(:check_condition, @condition)
  end

  test "skips unscoped bot_mention conditions (no single monitored source)" do
    SlackService.stubs(:configured?).returns(true)
    condition = trigger_conditions(:bot_mention_slack_condition)

    SlackService.expects(:get_channel_history).never
    SlackService.expects(:get_thread_replies).never
    ErrorReporter.expects(:report_message).never

    SlackTriggerHealthCheckJob.new.send(:check_condition, condition)
  end

  # Scoping a bot_mention to a thread gives it a single source and cursor, so
  # it can stall the same way a thread-scoped new_message can, and is checked.
  test "checks a thread-scoped bot_mention condition against its thread's newest reply" do
    SlackService.stubs(:configured?).returns(true)
    condition = trigger_conditions(:bot_mention_slack_condition)
    condition.update!(configuration: condition.configuration.merge("thread_ts" => "1704000000.000000"))

    SlackService.stubs(:get_thread_replies)
      .with(condition.channel_id, "1704000000.000000", oldest: condition.last_message_ts)
      .returns([ OpenStruct.new(ts: STALLED_TS, thread_ts: "1704000000.000000") ])
    SlackService.expects(:get_channel_history).never

    ErrorReporter.expects(:report_message).once.with do |message, opts|
      message == "Slack trigger feed stalled" &&
        opts[:context][:details].include?("thread 1704000000.000000")
    end

    SlackTriggerHealthCheckJob.new.send(:check_condition, condition)
  end

  test "skips dm_message conditions (one cursor per DM, no single source)" do
    SlackService.stubs(:configured?).returns(true)
    condition = trigger_conditions(:bot_mention_slack_condition)
    condition.configuration["event_type"] = "dm_message"

    SlackService.expects(:get_channel_history).never
    SlackService.expects(:get_thread_replies).never
    ErrorReporter.expects(:report_message).never

    SlackTriggerHealthCheckJob.new.send(:check_condition, condition)
  end

  test "skips every passive-listening condition (no single monitored source)" do
    SlackService.stubs(:configured?).returns(true)
    condition = trigger_conditions(:passive_listen_all_channels_condition)

    SlackService.expects(:get_channel_history).never
    SlackService.expects(:get_thread_replies).never
    ErrorReporter.expects(:report_message).never

    %w[passive_listen_thread passive_listen_channel].each do |event_type|
      condition.configuration["event_type"] = event_type
      SlackTriggerHealthCheckJob.new.send(:check_condition, condition)
    end
  end

  test "ignores thread replies when finding the newest top-level message" do
    SlackService.stubs(:configured?).returns(true)

    # Newest message is a recent thread reply the poller intentionally ignores;
    # the newest TOP-LEVEL message is stale. Comparing against the reply would be
    # a false negative — the feed is genuinely stalled at the top level.
    messages = [
      OpenStruct.new(ts: recent_ts, thread_ts: "1704000000.000000"), # thread reply (broadcast) — skip
      OpenStruct.new(ts: STALLED_TS, thread_ts: nil)                  # real top-level — stale
    ]
    SlackService.stubs(:get_channel_history)
      .with(@condition.channel_id, limit: SlackTriggerHealthCheckJob::HISTORY_SCAN_LIMIT)
      .returns(messages)

    ErrorReporter.expects(:report_message).once

    SlackTriggerHealthCheckJob.new.send(:check_condition, @condition)
  end

  test "thread-scoped condition compares against the newest thread reply" do
    SlackService.stubs(:configured?).returns(true)

    @condition.configuration["thread_ts"] = "1704000000.000000"
    @condition.save!

    # Newest reply in the monitored thread is stale relative to the baseline.
    # The scan is bounded by the last processed ts so it never walks the whole thread.
    SlackService.stubs(:get_thread_replies)
      .with(@condition.channel_id, "1704000000.000000", oldest: @condition.last_message_ts)
      .returns([ OpenStruct.new(ts: STALLED_TS, thread_ts: "1704000000.000000") ])
    # Thread-scoped conditions must not use channel-history polling
    SlackService.expects(:get_channel_history).never

    ErrorReporter.expects(:report_message).once.with do |message, opts|
      message == "Slack trigger feed stalled" &&
        opts[:context][:details].include?("thread 1704000000.000000")
    end

    SlackTriggerHealthCheckJob.new.send(:check_condition, @condition)
  end

  test "a Slack API error checking one condition does not raise (logged at info, self-resolves)" do
    SlackService.stubs(:configured?).returns(true)
    SlackService.stubs(:get_channel_history).raises(SlackService::ApiError.new("channel_not_found"))
    ErrorReporter.expects(:report_message).never

    assert_nothing_raised do
      SlackTriggerHealthCheckJob.new.perform
    end
  end
end
