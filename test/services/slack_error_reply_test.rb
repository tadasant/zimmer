# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"

# The rules for the fixed reply Zimmer posts in the thread of a Slack request its session cannot serve.
#
#   session                                                    | result
#   -----------------------------------------------------------|-------------------------------------
#   fired by passive listening / new_message                   | settled not_addressed, never posts
#   not Claude Code                                            | settled unsupported_runtime
#   a model turn landed                                        | settled not_needed, never posts
#   failed, no model turn                                      | posts "failed", settles
#   failed by a deploy interruption or waiting on OAuth        | no "failed" reply (Zimmer resumes it)
#   quota_exhausted park / spot utilization hold or pause      | posts "quota" once the poster waited 5m
#   a quota-wall line in the transcript, no park               | waiting (the pool rotates accounts)
#   spot pause queued by a user, or preempted                  | waiting
#   quota, poster waited < 5m                                  | waiting
#   spot hold for the fleet cap (not quota)                    | waiting
#   outage-class API errors, poster waited 15m                 | posts "outage"
#   outage-class API errors, poster waited < 15m               | waiting
#   outage-class API errors only before the latest prompt      | waiting
#   quota reply already posted                                 | does not post quota again
#   quota posted, then failed                                  | posts "failed" too
#   a post that was started and never confirmed                | unconfirmed, never re-posted
#   Slack 429                                                  | intent cleared, retried next sweep
#   Slack missing_scope                                        | recorded failed:missing_scope, logged
#   archived without a model turn                              | settled ended
#   a reply in a thread                                        | posts to the thread's parent
class SlackErrorReplyTest < ActiveSupport::TestCase
  CHANNEL = "C0TESTCHAN1"

  setup do
    @now = Time.zone.parse("2026-11-21T12:00:00Z")
    @session = sessions(:running)
    @session.update!(transcript: nil, metadata: source(waited: 20.minutes))
  end

  teardown { Mocha::Mockery.instance.teardown }

  def source(waited:, event_type: "bot_mention", thread_ts: nil)
    SlackOutageMarker.source_metadata(channel_id: CHANNEL, message_ts: ts_ago(waited), event_type: event_type, thread_ts: thread_ts)
  end

  def ts_ago(duration)
    format("%.6f", (@now - duration).to_f)
  end

  def line(hash) = hash.to_json

  def api_error_line(text = "API Error: 529 Overloaded", error: "overloaded_error")
    line(type: "assistant", isApiErrorMessage: true, error: error,
         message: { role: "assistant", model: "<synthetic>", content: [ { type: "text", text: text } ] })
  end

  def quota_error_line
    api_error_line("You've hit your limit · resets 4pm (UTC)", error: "rate_limit")
  end

  def model_turn_line
    line(type: "assistant", message: { role: "assistant", model: "claude-opus-5", content: [ { type: "text", text: "Looking." } ] })
  end

  def user_line
    line(type: "user", message: { role: "user", content: "hello" })
  end

  def transcript(*lines)
    @session.update!(transcript: lines.join("\n") + "\n")
  end

  def status!(status)
    @session.update_columns(status: Session.statuses[status])
  end

  def converge
    SlackErrorReply.new(@session.reload, now: @now).converge!
  end

  def metadata = @session.reload.metadata

  def expect_post(error_class, thread_ts: nil)
    SlackService.expects(:post_message).with do |args|
      args[:channel] == CHANNEL &&
        args[:thread_ts] == (thread_ts || metadata["slack_message_ts"]) &&
        args[:text] == SlackErrorReply.render(error_class, @session)
    end.returns({ "ok" => true })
  end

  # --- source metadata ------------------------------------------------------------------

  test "source_metadata records the condition's event type and a reply's thread parent" do
    assert_equal({ "slack_channel_id" => "C1", "slack_message_ts" => "2.0", "slack_trigger_event_type" => "bot_mention",
                   "slack_thread_ts" => "1.0" },
                 SlackOutageMarker.source_metadata(channel_id: "C1", message_ts: "2.0", event_type: "bot_mention", thread_ts: "1.0"))
    # A top-level message's thread_ts is its own ts, which is not worth recording.
    assert_nil SlackOutageMarker.source_metadata(channel_id: "C1", message_ts: "2.0", thread_ts: "2.0")["slack_thread_ts"]
  end

  test "every template names the session" do
    SlackErrorReply::CLASSES.each do |error_class|
      assert_includes SlackErrorReply.render(error_class, @session), "/sessions/#{@session.id}|View the session>"
    end
  end

  # --- who gets a reply -----------------------------------------------------------------

  test "a passive-listening or new_message session is never answered" do
    %w[passive_listen_thread passive_listen_channel new_message].each do |event_type|
      @session.update!(metadata: source(waited: 1.hour, event_type: event_type))
      status!(:failed)
      SlackService.expects(:post_message).never

      assert_equal :settled, converge
      assert_equal "not_addressed", metadata["slack_error_reply_outcome"]
    end
  end

  test "a session from before the event type was recorded is never answered" do
    @session.update!(metadata: SlackOutageMarker.source_metadata(channel_id: CHANNEL, message_ts: ts_ago(1.hour)))
    status!(:failed)
    SlackService.expects(:post_message).never

    assert_equal :settled, converge
  end

  test "a non-Claude-Code session is settled unsupported_runtime" do
    @session.update_columns(agent_runtime: "codex")
    status!(:failed)
    SlackService.expects(:post_message).never

    assert_equal :settled, converge
    assert_equal "unsupported_runtime", metadata["slack_error_reply_outcome"]
  end

  test "once a model turn landed, Zimmer never replies: the agent had its chance" do
    transcript(user_line, quota_error_line, model_turn_line)
    @session.merge_metadata!("auth_outage_reason" => AuthOutageParkService::QUOTA_EXHAUSTED)
    status!(:failed)
    SlackService.expects(:post_message).never

    assert_equal :settled, converge
    assert_equal "not_needed", metadata["slack_error_reply_outcome"]
  end

  # --- failed ---------------------------------------------------------------------------

  test "a session that failed before any model turn gets the failed reply, at once, and settles" do
    @session.merge_metadata!("slack_message_ts" => ts_ago(30.seconds))
    transcript(user_line)
    status!(:failed)
    expect_post("failed")

    assert_equal :posted, converge
    assert_equal "posted", metadata["slack_error_reply_failed_outcome"]
    assert_equal "failed_reply_posted", metadata["slack_error_reply_outcome"]
    assert_match(/replied in its thread/, @session.logs.order(:id).last.content)
  end

  test "a session a deploy killed is resumed by Zimmer, so it gets no failed reply" do
    status!(:failed)
    @session.merge_metadata!("exception_class" => "GoodJob::InterruptError")
    SlackService.expects(:post_message).never

    assert_equal :settled, converge
    assert_equal "ended", metadata["slack_error_reply_outcome"]
  end

  test "a session failed waiting on an MCP server's OAuth gets no failed reply" do
    status!(:failed)
    @session.merge_metadata!("failure_reason" => "oauth_required")
    SlackService.expects(:post_message).never

    assert_equal :settled, converge
  end

  test "an archived session without a model turn settles ended, silently" do
    status!(:archived)
    SlackService.expects(:post_message).never

    assert_equal :settled, converge
    assert_equal "ended", metadata["slack_error_reply_outcome"]
  end

  # --- quota ----------------------------------------------------------------------------

  test "a session parked because the pool is out of quota gets the quota reply" do
    status!(:waiting)
    @session.merge_metadata!("auth_outage_reason" => AuthOutageParkService::QUOTA_EXHAUSTED)
    expect_post("quota")

    assert_equal :posted, converge
    assert_equal "posted", metadata["slack_error_reply_quota_outcome"]
    assert_nil metadata["slack_error_reply_settled_at"], "still watched, in case it fails later"
  end

  test "a spot session held for utilization gets the quota reply" do
    status!(:waiting)
    @session.merge_metadata!(SpotSessionHold::HELD_REASON => SpotSessionHold::UTILIZATION_REASON)
    expect_post("quota")

    assert_equal :posted, converge
  end

  test "a spot session held only for the fleet cap is busy, not out of quota" do
    status!(:waiting)
    @session.merge_metadata!(SpotSessionHold::HELD_REASON => "at_session_limit")
    SlackService.expects(:post_message).never

    assert_equal :waiting, converge
  end

  test "a spot session paused by the ceiling gets the quota reply" do
    status!(:waiting)
    @session.merge_metadata!(SpotSessionPause::PAUSED_REASON => "at_utilization_limit")
    expect_post("quota")

    assert_equal :posted, converge
  end

  test "a spot session a user queued, or a priority session preempted, is not out of quota" do
    [ SpotSessionPause::QUEUED_REASON, SpotSessionPause::PREEMPTED_REASON ].each do |reason|
      status!(:waiting)
      @session.merge_metadata!(SpotSessionPause::PAUSED_REASON => reason)
      SlackService.expects(:post_message).never

      assert_equal :waiting, converge
    end
  end

  test "a quota-wall line in the transcript alone is not quota: Claude Code rotates to another account" do
    transcript(user_line, quota_error_line)
    SlackService.expects(:post_message).never

    assert_equal :waiting, converge
  end

  test "quota waits until the poster has waited five minutes" do
    @session.merge_metadata!("slack_message_ts" => ts_ago(2.minutes))
    status!(:waiting)
    @session.merge_metadata!("auth_outage_reason" => AuthOutageParkService::QUOTA_EXHAUSTED)
    SlackService.expects(:post_message).never

    assert_equal :waiting, converge
  end

  test "the quota reply is posted once, and a later failure still gets its own reply" do
    @session.merge_metadata!("auth_outage_reason" => AuthOutageParkService::QUOTA_EXHAUSTED)
    expect_post("quota")
    assert_equal :posted, converge

    SlackService.expects(:post_message).never
    assert_equal :waiting, converge

    Mocha::Mockery.instance.teardown
    status!(:failed)
    expect_post("failed")
    assert_equal :posted, converge
    assert_equal :settled, converge
  end

  # --- outage ---------------------------------------------------------------------------

  test "outage-class API errors get the outage reply after fifteen minutes" do
    transcript(user_line, api_error_line)
    expect_post("outage")

    assert_equal :posted, converge
    assert_equal "posted", metadata["slack_error_reply_outage_outcome"]
  end

  test "outage-class API errors under fifteen minutes wait (the reaction covers those)" do
    @session.merge_metadata!("slack_message_ts" => ts_ago(10.minutes))
    transcript(user_line, api_error_line)
    SlackService.expects(:post_message).never

    assert_equal :waiting, converge
  end

  test "outage errors from before the latest prompt do not count" do
    transcript(user_line, api_error_line, user_line)
    SlackService.expects(:post_message).never

    assert_equal :waiting, converge
  end

  test "a slow session with no error is never answered" do
    transcript(user_line)
    SlackService.expects(:post_message).never

    assert_equal :waiting, converge
  end

  test "an auth_unrecoverable park gets the outage reply" do
    status!(:waiting)
    @session.merge_metadata!("auth_outage_reason" => AuthOutageParkService::AUTH_UNRECOVERABLE)
    expect_post("outage")

    assert_equal :posted, converge
  end

  # --- threads, crashes and Slack errors ------------------------------------------------

  test "a reply inside a thread is answered in that thread" do
    @session.update!(metadata: source(waited: 20.minutes, thread_ts: "1700000000.000100"))
    status!(:failed)
    expect_post("failed", thread_ts: "1700000000.000100")

    assert_equal :posted, converge
  end

  test "a post that was started and never confirmed is not posted again" do
    status!(:failed)
    @session.merge_metadata!(SlackErrorReply.posting_key("failed") => (@now - 1.minute).iso8601)
    SlackService.expects(:post_message).never

    assert_equal :settled, converge
    assert_equal "unconfirmed", metadata["slack_error_reply_failed_outcome"]
    assert_equal "ended", metadata["slack_error_reply_outcome"]
  end

  test "a 429 clears the intent so the next sweep posts" do
    status!(:failed)
    SlackService.expects(:post_message).raises(SlackService::RateLimitedError.new("rate limited", retry_after: 30))

    assert_equal :error, converge
    assert_nil metadata[SlackErrorReply.posting_key("failed")]
    assert_nil metadata["slack_error_reply_settled_at"]

    Mocha::Mockery.instance.teardown
    expect_post("failed")
    assert_equal :posted, converge
  end

  test "a missing scope is recorded and logged, never retried, never raised" do
    status!(:failed)
    SlackService.expects(:post_message).once
      .raises(SlackService::ApiError.new("Slack API error: missing_scope", code: "missing_scope"))

    assert_equal :post_failed, converge
    assert_equal "failed:missing_scope", metadata["slack_error_reply_failed_outcome"]
    assert_equal "post_failed:missing_scope", metadata["slack_error_reply_outcome"]
    assert_match(/chat:write/, @session.logs.order(:id).last.content)
    assert_equal :settled, converge
  end

  test "a model turn that landed after the sweep loaded the row wins" do
    transcript(user_line, api_error_line)
    stale = Session.find(@session.id)
    Session.find(@session.id).update_columns(transcript: [ user_line, api_error_line, model_turn_line ].join("\n") + "\n")
    SlackService.expects(:post_message).never

    assert_equal :settled, SlackErrorReply.new(stale, now: @now).converge!
    assert_equal "not_needed", metadata["slack_error_reply_outcome"]
  end

  # --- candidates -----------------------------------------------------------------------

  test "candidates are recent, Slack-spawned and unsettled" do
    @session.update_columns(created_at: @now - 1.hour)
    assert_includes SlackErrorReply.candidates(now: @now), @session

    @session.merge_metadata!("slack_error_reply_settled_at" => @now.iso8601)
    assert_not_includes SlackErrorReply.candidates(now: @now), @session

    @session.remove_metadata!("slack_error_reply_settled_at")
    @session.update_columns(created_at: @now - 2.days)
    assert_not_includes SlackErrorReply.candidates(now: @now), @session
  end
end
