# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"

# Sessions::SetCarplayFit is the single writer behind every surface. Two
# properties matter most: the precedence rule between writers is enforced here
# and nowhere else, and writing the mark touches nothing else on the session.
class Sessions::SetCarplayFitTest < ActiveSupport::TestCase
  setup do
    Session.any_instance.stubs(:broadcast_status_change)
    Session.any_instance.stubs(:broadcast_update_to_sessions_index)
    Session.any_instance.stubs(:broadcast_create_to_sessions_index)
    Log.any_instance.stubs(:broadcast_append_to_timeline)
  end

  def make_session(**attrs)
    Session.create!({
      agent_runtime: "claude_code",
      status: :needs_input,
      prompt: "p",
      git_root: "https://github.com/test/repo.git",
      branch: "main",
      transcript: lines(10),
      precedence: 7
    }.merge(attrs))
  end

  # `transcript_line_count` is derived from the transcript, so a session that is
  # "at line N" needs N lines of one.
  def lines(n)
    n.times.map { |i| JSON.generate({ "type" => "user", "message" => { "role" => "user", "content" => "m#{i}" } }) }.join("\n") + "\n"
  end

  test "writes the five columns and nothing else" do
    session = make_session

    result = Sessions::SetCarplayFit.call(session: session, fit: "laptop_only", reason: "credential", source: "human")

    assert result.applied?
    session.reload
    assert_equal "laptop_only", session.carplay_fit
    assert_equal "credential", session.carplay_fit_reason
    assert_equal "human", session.carplay_fit_source
    assert_equal 10, session.carplay_fit_line_count
    assert_not_nil session.carplay_fit_set_at
    assert_equal "needs_input", session.status
    assert_equal 7, session.precedence
  end

  test "stamps the line count the caller judged against, not the session's current one" do
    session = make_session

    Sessions::SetCarplayFit.call(session: session, fit: "carplay_ok", source: "auto", line_count: 8)

    assert_equal 8, session.reload.carplay_fit_line_count
    assert_not session.carplay_fit_current?
  end

  test "a human mark outranks an automatic one at the same position, and is reported rather than raised" do
    session = make_session
    Sessions::SetCarplayFit.call(session: session, fit: "laptop_only", source: "human")

    result = Sessions::SetCarplayFit.call(session: session, fit: "carplay_ok", source: "auto")

    assert_not result.applied?
    assert_match(/Kept the standing human mark/, result.message)
    assert_equal "laptop_only", session.reload.carplay_fit
  end

  test "an assistant mark outranks an automatic one and is outranked by a human one" do
    session = make_session
    Sessions::SetCarplayFit.call(session: session, fit: "laptop_only", source: "auto")

    assert Sessions::SetCarplayFit.call(session: session, fit: "carplay_ok", source: "assistant").applied?
    assert_equal "carplay_ok", session.reload.carplay_fit

    assert_not Sessions::SetCarplayFit.call(session: session, fit: "laptop_only", source: "auto").applied?
    assert Sessions::SetCarplayFit.call(session: session, fit: "laptop_only", source: "human").applied?
    assert_equal "laptop_only", session.reload.carplay_fit
  end

  test "a mark against a later transcript position replaces any earlier one, whoever wrote it" do
    session = make_session
    Sessions::SetCarplayFit.call(session: session, fit: "laptop_only", source: "human")
    session.update!(transcript: lines(15))

    result = Sessions::SetCarplayFit.call(session: session, fit: "carplay_ok", source: "auto")

    assert result.applied?
    assert_equal "carplay_ok", session.reload.carplay_fit
    assert_equal "auto", session.carplay_fit_source
    assert_equal 15, session.carplay_fit_line_count
  end

  test "equal rank overwrites" do
    session = make_session
    Sessions::SetCarplayFit.call(session: session, fit: "laptop_only", source: "human")

    assert Sessions::SetCarplayFit.call(session: session, fit: "carplay_ok", source: "human").applied?
    assert_equal "carplay_ok", session.reload.carplay_fit
  end

  test "clear removes the whole mark" do
    session = make_session
    Sessions::SetCarplayFit.call(session: session, fit: "laptop_only", reason: "credential", source: "human")

    result = Sessions::SetCarplayFit.call(session: session, fit: "clear", source: "human")

    assert result.applied?
    session.reload
    assert_nil session.carplay_fit
    assert_nil session.carplay_fit_reason
    assert_nil session.carplay_fit_source
    assert_nil session.carplay_fit_set_at
    assert_nil session.carplay_fit_line_count
  end

  test "values off the lists are refused with the valid ones named" do
    session = make_session

    error = assert_raises(Sessions::SetCarplayFit::Error) { Sessions::SetCarplayFit.call(session: session, fit: "maybe", source: "human") }
    assert_match(/carplay_ok, laptop_only/, error.message)
    assert_raises(Sessions::SetCarplayFit::Error) { Sessions::SetCarplayFit.call(session: session, fit: "carplay_ok", source: "robot") }
    assert_raises(Sessions::SetCarplayFit::Error) { Sessions::SetCarplayFit.call(session: session, fit: "carplay_ok", reason: "vibes", source: "human") }
  end

  test "a person's or an agent's write is noted on the timeline; the automatic one is not" do
    session = make_session

    Sessions::SetCarplayFit.call(session: session, fit: "laptop_only", reason: "credential", source: "human")
    assert_equal 1, session.logs.where("content LIKE ?", "CarPlay fit set to Laptop only%").count

    session.update!(transcript: lines(20))
    Sessions::SetCarplayFit.call(session: session, fit: "carplay_ok", source: "auto")
    assert_equal 1, session.logs.where("content LIKE ?", "CarPlay fit%").count
  end
end
