# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"

# The rules for the reaction Zimmer puts on a Slack message whose session cannot reach the model.
#
#   session                                         | marker    | result
#   ------------------------------------------------|-----------|----------------------------
#   API errors, no model turn, poster waited > 5m   | none      | added
#   API errors, no model turn, poster waited < 5m   | none      | waiting
#   no API error yet, no model turn                 | none      | waiting
#   a model turn landed                             | none      | settled not_needed
#   stopped (archived/failed/needs_input)           | none      | settled not_needed
#   not Claude Code                                 | any       | settled unsupported_runtime
#   still no model turn                             | on        | waiting (kept)
#   model turn landed / stopped                     | on        | removed
class SlackOutageMarkerTest < ActiveSupport::TestCase
  CHANNEL = "C0BTK3BHNCE"

  setup do
    @now = Time.zone.parse("2026-09-22T01:30:00Z")
    @session = sessions(:running)
    @session.update!(transcript: nil, metadata: SlackOutageMarker.source_metadata(channel_id: CHANNEL, message_ts: ts_ago(10.minutes)))
  end

  teardown { Mocha::Mockery.instance.teardown }

  def ts_ago(duration)
    format("%.6f", (@now - duration).to_f)
  end

  def line(hash) = hash.to_json

  def api_error_line
    line(type: "assistant", isApiErrorMessage: true, error: "overloaded_error",
         message: { role: "assistant", model: "<synthetic>", content: [ { type: "text", text: "API Error: 529 Overloaded" } ] })
  end

  def resume_stub_line
    line(type: "assistant", message: { role: "assistant", model: "<synthetic>", content: [ { type: "text", text: "No response requested." } ] })
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

  def converge
    SlackOutageMarker.new(@session.reload, now: @now).converge!
  end

  def metadata = @session.reload.metadata

  def slack_error(code)
    SlackService::ApiError.new("Slack API error: #{code}", code: code)
  end

  # --- source_metadata ----------------------------------------------------------------

  test "source_metadata names the channel and ts, and is empty without both" do
    assert_equal({ "slack_channel_id" => "C1", "slack_message_ts" => "1.2" },
                 SlackOutageMarker.source_metadata(channel_id: "C1", message_ts: "1.2"))
    assert_equal({}, SlackOutageMarker.source_metadata(channel_id: "C1", message_ts: nil))
    assert_equal({}, SlackOutageMarker.source_metadata(channel_id: "", message_ts: "1.2"))
  end

  # --- adding ---------------------------------------------------------------------------

  test "adds the marker when the session hit API errors, never reached the model, and the poster waited past the threshold" do
    transcript(user_line, api_error_line, resume_stub_line, api_error_line)
    SlackService.expects(:add_reaction)
      .with(channel: CHANNEL, timestamp: metadata["slack_message_ts"], name: "hourglass_flowing_sand")
      .returns(:added)

    assert_equal :added, converge
    assert_equal @now.iso8601, metadata["slack_outage_marker_added_at"]
    assert_nil metadata["slack_outage_marker_settled_at"]
    assert_match(/hourglass_flowing_sand/, @session.logs.order(:id).last.content)
  end

  test "the resume stub is not a model turn, so it does not hold the marker back" do
    transcript(user_line, api_error_line, resume_stub_line)
    SlackService.expects(:add_reaction).returns(:added)

    assert_equal :added, converge
  end

  test "a reaction the bot already left counts as added" do
    transcript(user_line, api_error_line)
    SlackService.expects(:add_reaction).returns(:already_present)

    assert_equal :added, converge
    assert metadata["slack_outage_marker_added_at"].present?
  end

  test "waits while the poster has waited less than the threshold" do
    @session.merge_metadata!("slack_message_ts" => ts_ago(2.minutes))
    transcript(user_line, api_error_line)
    SlackService.expects(:add_reaction).never

    assert_equal :waiting, converge
    assert_nil metadata["slack_outage_marker_settled_at"]
  end

  test "waits while there has been no API error, however long the poster has waited" do
    transcript(user_line)
    SlackService.expects(:add_reaction).never

    assert_equal :waiting, converge
  end

  test "a waiting session is still active" do
    @session.update_column(:status, Session.statuses[:waiting])
    transcript(user_line, api_error_line)
    SlackService.expects(:add_reaction).returns(:added)

    assert_equal :added, converge
  end

  # --- never needed -------------------------------------------------------------------

  test "settles without reacting once a model turn has landed, API errors or not" do
    transcript(user_line, api_error_line, model_turn_line, api_error_line)
    SlackService.expects(:add_reaction).never

    assert_equal :settled, converge
    assert_equal "not_needed", metadata["slack_outage_marker_outcome"]
  end

  test "settles without reacting when the session stopped" do
    %w[archived failed needs_input].each do |status|
      @session.update_columns(status: Session.statuses[status], metadata: SlackOutageMarker.source_metadata(channel_id: CHANNEL, message_ts: ts_ago(10.minutes)))
      transcript(user_line, api_error_line)
      SlackService.expects(:add_reaction).never

      assert_equal :settled, converge, status
      assert_equal "not_needed", metadata["slack_outage_marker_outcome"], status
    end
  end

  test "a session on another runtime is settled and never marked" do
    @session.update_column(:agent_runtime, "codex")
    SlackService.expects(:add_reaction).never

    assert_equal :settled, converge
    assert_equal "unsupported_runtime", metadata["slack_outage_marker_outcome"]
  end

  test "a settled session is left alone" do
    @session.merge_metadata!("slack_outage_marker_settled_at" => @now.iso8601)
    transcript(user_line, api_error_line)
    SlackService.expects(:add_reaction).never
    SlackService.expects(:remove_reaction).never

    assert_equal :settled, converge
  end

  # --- a bot that cannot react ----------------------------------------------------------

  test "a missing scope settles the session, says which scope on the session, and does not raise" do
    transcript(user_line, api_error_line)
    SlackService.expects(:add_reaction).raises(slack_error("missing_scope"))

    assert_equal :settled, converge
    assert_equal "add_failed:missing_scope", metadata["slack_outage_marker_outcome"]
    assert_nil metadata["slack_outage_marker_added_at"]

    log = @session.logs.order(:id).last
    assert_equal "warning", log.level
    assert_includes log.content, "reactions:write"
  end

  test "an unset token settles the session rather than raising" do
    transcript(user_line, api_error_line)
    SlackService.expects(:add_reaction).raises(SlackService::ConfigurationError, "SLACK_BOT_TOKEN is not configured")

    assert_equal :settled, converge
    assert_equal "add_failed:ConfigurationError", metadata["slack_outage_marker_outcome"]
  end

  test "a transient failure to add is retried by the next sweep" do
    transcript(user_line, api_error_line)
    SlackService.expects(:add_reaction).raises(SlackService::TransientError, "Network error communicating with Slack: timeout")

    assert_equal :error, converge
    assert_nil metadata["slack_outage_marker_settled_at"]
    assert_includes metadata["slack_outage_marker_error"], "timeout"

    SlackService.expects(:add_reaction).returns(:added)
    assert_equal :added, converge
    assert_nil metadata["slack_outage_marker_error"]
  end

  # --- removing -------------------------------------------------------------------------

  def mark!
    @session.merge_metadata!("slack_outage_marker_added_at" => (@now - 1.minute).iso8601)
  end

  test "keeps the marker while the session is still stuck" do
    mark!
    transcript(user_line, api_error_line, resume_stub_line, api_error_line)
    SlackService.expects(:remove_reaction).never

    assert_equal :waiting, converge
  end

  test "removes the marker when the agent's first model turn lands" do
    mark!
    transcript(user_line, api_error_line, model_turn_line)
    SlackService.expects(:remove_reaction)
      .with(channel: CHANNEL, timestamp: metadata["slack_message_ts"], name: "hourglass_flowing_sand")
      .returns(:removed)

    assert_equal :removed, converge
    assert_equal "removed", metadata["slack_outage_marker_outcome"]
    assert metadata["slack_outage_marker_settled_at"].present?
  end

  test "removes the marker when the session stops without a model turn" do
    mark!
    @session.update_column(:status, Session.statuses[:failed])
    transcript(user_line, api_error_line)
    SlackService.expects(:remove_reaction).returns(:removed)

    assert_equal :removed, converge
  end

  test "a marker someone already took off counts as removed" do
    mark!
    transcript(user_line, model_turn_line)
    SlackService.expects(:remove_reaction).returns(:absent)

    assert_equal :removed, converge
  end

  test "a message that is gone settles the removal" do
    mark!
    transcript(user_line, model_turn_line)
    SlackService.expects(:remove_reaction).raises(slack_error("message_not_found"))

    assert_equal :settled, converge
    assert_equal "removed:message_not_found", metadata["slack_outage_marker_outcome"]
  end

  test "any other removal failure is retried rather than settled, so the marker is not left behind" do
    mark!
    transcript(user_line, model_turn_line)
    SlackService.expects(:remove_reaction).raises(slack_error("missing_scope"))

    assert_equal :error, converge
    assert_nil metadata["slack_outage_marker_settled_at"]
    assert_includes metadata["slack_outage_marker_error"], "missing_scope"
  end

  # --- candidates -----------------------------------------------------------------------

  test "candidates are young, unsettled sessions spawned for a Slack message" do
    young = @session
    young.update_column(:created_at, @now - 1.hour)

    old = sessions(:waiting)
    old.update_columns(metadata: young.metadata, created_at: @now - 2.days)

    settled = sessions(:needs_input)
    settled.update_columns(metadata: young.metadata.merge("slack_outage_marker_settled_at" => @now.iso8601), created_at: @now - 1.hour)

    candidate_ids = SlackOutageMarker.candidates(now: @now).pluck(:id)
    assert_includes candidate_ids, young.id
    refute_includes candidate_ids, old.id
    refute_includes candidate_ids, settled.id
    refute_includes candidate_ids, sessions(:archived).id
  end
end
