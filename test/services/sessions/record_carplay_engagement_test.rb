# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"

# CarPlay engagement: a session a person starts, follows up or acts on from
# CarPlay is marked `carplay_ok` with source `carplay`, a mark that does not go
# stale and is demoted only by a later `laptop_only` judgement. Covers the entry
# paths (create, follow-up, queued message, MCP action, REST write), the
# stickiness, demotion and re-promotion, and what the classifier is told.
class Sessions::RecordCarplayEngagementTest < ActiveSupport::TestCase
  setup do
    Session.any_instance.stubs(:broadcast_status_change)
    Session.any_instance.stubs(:broadcast_update_to_sessions_index)
    Session.any_instance.stubs(:broadcast_create_to_sessions_index)
    Log.any_instance.stubs(:broadcast_append_to_timeline)
  end

  CARPLAY = TurnSource.new(surface: "carplay", modality: "live_voice", live_conversation_id: 12)
  PHONE = TurnSource.new(surface: "ios", modality: "voice_dictation")

  def make_session(**attrs)
    Session.create!({
      agent_runtime: "claude_code",
      status: :needs_input,
      prompt: "p",
      git_root: "https://github.com/test/repo.git",
      branch: "main",
      transcript: lines(10)
    }.merge(attrs))
  end

  def lines(n)
    n.times.map { |i| JSON.generate({ "type" => "user", "message" => { "role" => "user", "content" => "m#{i}" } }) }.join("\n") + "\n"
  end

  def auto(session, fit, reason, line_count:)
    StatusSummaryAnswer.apply_carplay_fit(session.reload, "Blurb.\ncarplay-fit: #{fit}; reason: #{reason}", line_count: line_count)
    session.reload
  end

  # --- Entry paths -----------------------------------------------------------

  test "a session created with a CarPlay turn source starts marked carplay_ok by carplay" do
    session = make_session(source_context: CARPLAY.to_h)

    session.reload
    assert session.carplay_engaged?
    assert_equal "carplay_ok", session.carplay_fit
    assert_equal "carplay", session.carplay_fit_source
    assert session.carplay_fit_current?
    assert_includes session.carplay_fit_summary, "engaged from CarPlay"
  end

  test "a session created from any other surface is not engaged" do
    session = make_session(source_context: PHONE.to_h)

    session.reload
    assert_not session.carplay_engaged?
    assert_nil session.carplay_fit
  end

  test "a CarPlay follow-up marks the session on the delivery path" do
    session = make_session
    AgentSessionJob.stubs(:enqueue_with_prompt).returns(stub(job_id: "j1"))

    session.deliver_follow_up!("go on", source: CARPLAY)

    session.reload
    assert session.carplay_engaged?
    assert_equal "carplay", session.carplay_fit_source
  end

  test "tag_turn leaves the caller's unsaved attributes alone" do
    session = make_session
    session.title = "unsaved"

    session.tag_turn("hi", CARPLAY)

    assert_equal "carplay", session.carplay_fit_source, "the caller's object sees the new mark"
    assert_not session.carplay_fit_source_changed?
    assert session.title_changed?, "the caller's own pending change was not saved for it"
    assert_not_equal "unsaved", Session.find(session.id).title
  end

  test "the initial prompt's delivery does not re-record engagement" do
    session = make_session(source_context: CARPLAY.to_h)
    Sessions::RecordCarplayEngagement.expects(:call).never

    session.initial_prompt_for_delivery
  end

  test "a message queued from CarPlay marks the session when it is queued" do
    session = make_session(status: :running)

    EnqueuedMessage.create!(session: session, content: "next", position: 1, source_context: CARPLAY.to_h)

    assert_equal "carplay", session.reload.carplay_fit_source
  end

  test "an action_session write from a CarPlay Live conversation marks the session; a read-only or explicit mark does not" do
    session = make_session
    tool = Mcp::Tools::ActionSession.new(context: Mcp::Context.new(tool_groups: "sessions", turn_source: CARPLAY))

    tool.call({ "action" => "update_notes", "session_id" => session.id.to_s, "session_notes" => "from the car" })
    assert_equal "carplay", session.reload.carplay_fit_source

    other = make_session
    tool.call({ "action" => "set_carplay_fit", "session_id" => other.id.to_s, "carplay_fit" => "laptop_only", "carplay_fit_reason" => "credential" })
    other.reload
    assert_equal "laptop_only", other.carplay_fit
    assert_equal "assistant", other.carplay_fit_source
    assert_not other.carplay_engaged?
  end

  test "an action_session write from another surface records nothing" do
    session = make_session
    tool = Mcp::Tools::ActionSession.new(context: Mcp::Context.new(tool_groups: "sessions", turn_source: PHONE))

    tool.call({ "action" => "update_notes", "session_id" => session.id.to_s, "session_notes" => "x" })

    assert_not session.reload.carplay_engaged?
  end

  test "hiding a card from CarPlay is not engagement" do
    session = make_session
    tool = Mcp::Tools::ActionSession.new(context: Mcp::Context.new(tool_groups: "sessions", turn_source: CARPLAY))

    tool.call({ "action" => "set_visibility", "session_id" => session.id.to_s, "visibility" => "hidden" })

    assert_not session.reload.carplay_engaged?
  end

  test "a row Zimmer puts back in the queue does not re-record engagement" do
    session = make_session(status: :running)
    Sessions::RecordCarplayEngagement.expects(:call).never

    session.enqueued_messages.create!(**EnqueuedMessage.attributes_for_prompt(CARPLAY.annotate("again")), position: 1)
  end

  test "the queue drain does not record engagement; the enqueue already did" do
    session = make_session
    message = EnqueuedMessage.new(session: session, content: "x", position: 1, source_context: CARPLAY.to_h)
    Sessions::RecordCarplayEngagement.expects(:from_source).never

    session.tag_turn(message.content, message.turn_source, record_engagement: false)
  end

  # --- Stickiness ------------------------------------------------------------

  test "the carplay mark does not go stale as the session moves, and every filter agrees" do
    session = make_session(source_context: CARPLAY.to_h)
    session.reload.update!(transcript: lines(40))

    assert session.carplay_fit_current?
    assert_equal "carplay_ok", session.effective_carplay_fit
    assert_equal 0, session.carplay_fit_messages_since
    assert_includes Session.carplay_fit_filter("carplay_ok"), session
    assert_includes Session.carplay_fit_filter("not_laptop_only"), session
    assert_not_includes Session.carplay_fit_filter("untagged"), session
  end

  test "a carplay source cannot carry laptop_only" do
    session = make_session

    assert_raises(Sessions::SetCarplayFit::Error) do
      Sessions::SetCarplayFit.call(session: session, fit: "laptop_only", source: "carplay")
    end
    assert_not session.tap { |s| s.assign_attributes(carplay_fit: "laptop_only", carplay_fit_source: "carplay") }.valid?
  end

  test "an automatic carplay_ok keeps the sticky mark and fills in its reason" do
    session = make_session(source_context: CARPLAY.to_h)
    set_at = session.reload.carplay_fit_set_at
    session.update!(transcript: lines(20))

    session = auto(session, "carplay_ok", "decision", line_count: 20)

    assert_equal "carplay", session.carplay_fit_source
    assert_equal "decision", session.carplay_fit_reason
    assert_equal set_at.to_i, session.carplay_fit_set_at.to_i
  end

  test "an automatic laptop_only at the engagement's own position does not demote" do
    session = make_session(source_context: CARPLAY.to_h)

    session = auto(session, "laptop_only", "credential", line_count: 10)

    assert_equal "carplay", session.carplay_fit_source
  end

  # --- Demotion and re-promotion ---------------------------------------------

  test "a later laptop_only judgement demotes the sticky mark and says so on the timeline" do
    session = make_session(source_context: CARPLAY.to_h)
    session.reload.update!(transcript: lines(20))

    session = auto(session, "laptop_only", "credential", line_count: 20)

    assert_equal "laptop_only", session.carplay_fit
    assert_equal "auto", session.carplay_fit_source
    assert_equal "credential", session.carplay_fit_reason
    assert session.carplay_engaged?
    assert session.logs.where("content LIKE ?", "CarPlay fit demoted%").exists?
  end

  test "a human laptop_only demotes the sticky mark, and engagement at the same position does not undo it" do
    session = make_session(source_context: CARPLAY.to_h)
    Sessions::SetCarplayFit.call(session: session.reload, fit: "laptop_only", reason: "manual_steps", source: "human")

    result = Sessions::RecordCarplayEngagement.call(session.reload)

    assert_equal :kept_laptop_only, result.outcome
    assert_equal "human", session.reload.carplay_fit_source
    assert_equal "laptop_only", session.carplay_fit
  end

  test "re-engaging keeps a current laptop_only, and the next rest's carplay_ok restores the sticky mark" do
    session = make_session(source_context: CARPLAY.to_h)
    session.reload.update!(transcript: lines(20))
    session = auto(session, "laptop_only", "credential", line_count: 20)

    assert_equal :kept_laptop_only, Sessions::RecordCarplayEngagement.call(session).outcome
    assert_equal "laptop_only", session.reload.carplay_fit

    session.update!(transcript: lines(30))
    session = auto(session, "carplay_ok", "decision", line_count: 30)

    assert_equal "carplay_ok", session.carplay_fit
    assert_equal "carplay", session.carplay_fit_source
    assert session.carplay_fit_sticky?
  end

  test "re-engaging a session whose laptop_only has gone stale promotes it at once" do
    session = make_session
    Sessions::SetCarplayFit.call(session: session, fit: "laptop_only", reason: "credential", source: "auto")
    session.reload.update!(transcript: lines(15))

    assert_equal :marked, Sessions::RecordCarplayEngagement.call(session).outcome
    assert_equal "carplay", session.reload.carplay_fit_source
  end

  test "engagement keeps the reason of a current carplay_ok it replaces" do
    session = make_session
    Sessions::SetCarplayFit.call(session: session, fit: "carplay_ok", reason: "decision", source: "auto")

    Sessions::RecordCarplayEngagement.call(session.reload)

    session.reload
    assert_equal "carplay", session.carplay_fit_source
    assert_equal "decision", session.carplay_fit_reason
  end

  test "an automatic carplay_ok on a session never engaged from CarPlay stays an ordinary auto mark" do
    session = make_session

    session = auto(session, "carplay_ok", "decision", line_count: 10)

    assert_equal "auto", session.carplay_fit_source
  end

  test "restoring the sticky mark ranks as automatic: it never overwrites an assistant's mark at the same line" do
    session = make_session(source_context: CARPLAY.to_h)
    session.reload.update!(transcript: lines(20))
    Sessions::SetCarplayFit.call(session: session, fit: "laptop_only", reason: "credential", source: "assistant")

    session = auto(session, "carplay_ok", "decision", line_count: 20)

    assert_equal "laptop_only", session.carplay_fit
    assert_equal "assistant", session.carplay_fit_source
  end

  test "a marked row with no source is stale in SQL and in Ruby alike" do
    session = make_session
    session.update_columns(carplay_fit: "laptop_only", carplay_fit_source: nil, carplay_fit_line_count: 3)

    assert_not session.reload.carplay_fit_current?
    assert_includes Session.carplay_fit_filter("untagged"), session
    assert_includes Session.carplay_fit_filter("not_laptop_only"), session
  end

  # --- What the classifier is told -------------------------------------------

  test "the summary prompt carries the bias rule only for an engaged session" do
    engaged = make_session(source_context: CARPLAY.to_h).reload
    plain = make_session

    assert_includes SessionStatusSummaryGenerator.carplay_fit_rules_for(engaged), "engaged from CarPlay"
    assert_not_includes SessionStatusSummaryGenerator.carplay_fit_rules_for(plain), "engaged from CarPlay"
  end

  test "an engagement failure never raises into the caller" do
    session = make_session
    Sessions::SetCarplayFit.stubs(:call).raises(StandardError, "boom")

    result = Sessions::RecordCarplayEngagement.call(session)

    assert_equal :failed, result.outcome
  end
end
