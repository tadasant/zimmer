# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"

class SlackOutageMarkerJobTest < ActiveJob::TestCase
  teardown { Mocha::Mockery.instance.teardown }

  def stuck_session(fixture, channel: "C1")
    session = sessions(fixture)
    session.update_columns(
      status: Session.statuses[:running],
      created_at: 1.hour.ago,
      metadata: SlackOutageMarker.source_metadata(channel_id: channel, message_ts: format("%.6f", 10.minutes.ago.to_f)),
      transcript: { type: "assistant", isApiErrorMessage: true, message: { model: "<synthetic>", content: [] } }.to_json + "\n"
    )
    session
  end

  test "does nothing when Slack is not configured" do
    SlackService.stubs(:configured?).returns(false)
    stuck_session(:running)
    SlackService.expects(:add_reaction).never

    SlackOutageMarkerJob.perform_now
  end

  test "marks every stuck candidate, and one session's failure does not stop the rest" do
    SlackService.stubs(:configured?).returns(true)
    broken = stuck_session(:running, channel: "C_BROKEN")
    healthy = stuck_session(:waiting, channel: "C_OK")

    SlackService.stubs(:add_reaction).with(has_entry(channel: "C_BROKEN")).raises(RuntimeError, "boom")
    SlackService.stubs(:add_reaction).with(has_entry(channel: "C_OK")).returns(:added)
    ErrorReporter.expects(:report_exception).once

    assert_nothing_raised { SlackOutageMarkerJob.perform_now }
    assert healthy.reload.metadata["slack_outage_marker_added_at"].present?
    # Untouched, so the next sweep tries it again.
    assert_nil broken.reload.metadata["slack_outage_marker_settled_at"]
  end

  test "a sweep marks, and a later sweep after the model turn lands removes" do
    SlackService.stubs(:configured?).returns(true)
    session = stuck_session(:running)

    SlackService.expects(:add_reaction).once.returns(:added)
    SlackOutageMarkerJob.perform_now
    assert session.reload.metadata["slack_outage_marker_added_at"].present?

    session.update!(transcript: session.transcript + { type: "assistant", message: { model: "claude-opus-5", content: [] } }.to_json + "\n")
    SlackService.expects(:remove_reaction).once.returns(:removed)
    SlackOutageMarkerJob.perform_now
    assert_equal "removed", session.reload.metadata["slack_outage_marker_outcome"]

    # Settled: a third sweep does not touch Slack again.
    SlackOutageMarkerJob.perform_now
  end
end
