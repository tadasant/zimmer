# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"

class SlackErrorReplyJobTest < ActiveJob::TestCase
  teardown { Mocha::Mockery.instance.teardown }

  def failed_session(fixture, channel: "C1")
    session = sessions(fixture)
    session.update_columns(
      status: Session.statuses[:failed],
      created_at: 1.hour.ago,
      transcript: nil,
      metadata: SlackOutageMarker.source_metadata(channel_id: channel, message_ts: format("%.6f", 10.minutes.ago.to_f),
                                                  event_type: "bot_mention")
    )
    session
  end

  test "does nothing when Slack is not configured" do
    SlackService.stubs(:configured?).returns(false)
    failed_session(:running)
    SlackService.expects(:post_message).never

    SlackErrorReplyJob.perform_now
  end

  test "replies on every due candidate once, and one session's failure does not stop the rest" do
    SlackService.stubs(:configured?).returns(true)
    broken = failed_session(:running, channel: "C_BROKEN")
    healthy = failed_session(:waiting, channel: "C_OK")

    SlackService.stubs(:post_message).with(has_entry(channel: "C_BROKEN")).raises(RuntimeError, "boom")
    SlackService.expects(:post_message).with(has_entry(channel: "C_OK")).once.returns({ "ok" => true })
    ErrorReporter.expects(:report_exception).once

    assert_nothing_raised { SlackErrorReplyJob.perform_now }
    assert_equal "posted", healthy.reload.metadata["slack_error_reply_failed_outcome"]
    assert broken.reload.metadata["slack_error_reply_reported_at"].present?

    # The healthy one is settled; the broken one is retried but not reported again.
    assert_nothing_raised { SlackErrorReplyJob.perform_now }
  end

  # The whole path with no mock at the Slack boundary: the sweep, the decision, the template, and
  # the real slack-ruby-client posting over HTTP to a local fake of Slack's Web API.
  test "end to end: a quota-parked session's poster gets one threaded reply over the real Slack client" do
    api = FakeSlackWebApi.start
    SlackService.stubs(:configured?).returns(true)
    SlackService.stubs(:client).returns(api.client)

    message_ts = format("%.6f", 7.minutes.ago.to_f)
    session = sessions(:running)
    session.update_columns(
      status: Session.statuses[:waiting], created_at: 10.minutes.ago, transcript: nil,
      metadata: SlackOutageMarker.source_metadata(channel_id: "C_E2E", message_ts: message_ts, event_type: "dm_message")
        .merge("auth_outage_reason" => AuthOutageParkService::QUOTA_EXHAUSTED)
    )

    SlackErrorReplyJob.perform_now
    SlackErrorReplyJob.perform_now # still parked: no second reply

    assert_equal 1, api.calls.size
    method, params = api.calls.first
    assert_equal "chat.postMessage", method
    assert_equal "C_E2E", params["channel"]
    assert_equal message_ts, params["thread_ts"]
    assert_includes params["text"], "out of inference quota"
    assert_includes params["text"], "/sessions/#{session.id}|View the session>"
    assert_equal "posted", session.reload.metadata["slack_error_reply_quota_outcome"]

    # It then fails: one more reply, and the session settles.
    session.update_columns(status: Session.statuses[:failed])
    SlackErrorReplyJob.perform_now
    assert_equal 2, api.calls.size
    assert_includes api.calls.last.last["text"], "failed before the agent could reply"
    assert_equal "failed_reply_posted", session.reload.metadata["slack_error_reply_outcome"]
  ensure
    api&.stop
  end

  test "end to end: a missing chat:write scope is settled and logged, not raised" do
    api = FakeSlackWebApi.start
    api.refuse("chat.postMessage", "missing_scope")
    SlackService.stubs(:configured?).returns(true)
    SlackService.stubs(:client).returns(api.client)
    ErrorReporter.expects(:report_exception).never

    session = failed_session(:running, channel: "C_E2E")
    SlackErrorReplyJob.perform_now
    SlackErrorReplyJob.perform_now

    assert_equal 1, api.calls.size
    assert_equal "post_failed:missing_scope", session.reload.metadata["slack_error_reply_outcome"]
    assert_match(/chat:write/, session.logs.order(:id).last.content)
  ensure
    api&.stop
  end
end
