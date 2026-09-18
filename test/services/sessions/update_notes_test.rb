require "test_helper"
require "mocha/minitest"

# Sessions::UpdateNotes is the single writer behind all three surfaces (the web
# notes panel, PATCH /api/v1/sessions/:id/notes, and the `update_notes` MCP
# action). What matters here is that blank clears both columns, that the cap is
# measured against what would be stored, that a non-String is refused rather
# than coerced, and that writing the notes touches nothing else on the session.
class Sessions::UpdateNotesTest < ActiveSupport::TestCase
  def setup
    Session.any_instance.stubs(:broadcast_status_change)
    Session.any_instance.stubs(:broadcast_update_to_sessions_index)
    Session.any_instance.stubs(:broadcast_create_to_sessions_index)
  end

  def make_session(**attrs)
    Session.create!({
      agent_runtime: "claude_code",
      status: :needs_input,
      prompt: "p",
      mcp_servers: [],
      config: {},
      git_root: "https://github.com/test/repo.git",
      branch: "main"
    }.merge(attrs))
  end

  test "stores the notes and stamps them" do
    session = make_session
    freeze_time do
      returned = Sessions::UpdateNotes.call(session: session, notes: "Blocked on review")

      assert_same session, returned
      session.reload
      assert_equal "Blocked on review", session.session_notes
      assert_equal Time.current, session.session_notes_updated_at
    end
  end

  test "stores the notes verbatim, surrounding whitespace included" do
    session = make_session

    Sessions::UpdateNotes.call(session: session, notes: "  line one\nline two\n")

    assert_equal "  line one\nline two\n", session.reload.session_notes
  end

  [ nil, "", "   \n\t" ].each do |blank|
    test "#{blank.inspect} clears the notes and the stamp" do
      session = make_session(session_notes: "Old notes", session_notes_updated_at: 1.hour.ago)

      Sessions::UpdateNotes.call(session: session, notes: blank)

      session.reload
      assert_nil session.session_notes
      assert_nil session.session_notes_updated_at
    end
  end

  test "accepts notes exactly at the cap" do
    session = make_session

    Sessions::UpdateNotes.call(session: session, notes: "a" * Session::NOTES_MAX_LENGTH)

    assert_equal Session::NOTES_MAX_LENGTH, session.reload.session_notes.length
  end

  test "refuses notes one past the cap and leaves the old notes alone" do
    session = make_session(session_notes: "Old notes")

    error = assert_raises(Sessions::UpdateNotes::TooLong) do
      Sessions::UpdateNotes.call(session: session, notes: "a" * (Session::NOTES_MAX_LENGTH + 1))
    end

    assert_equal "Notes are too long (maximum 50,000 characters)", error.message
    assert_equal "Old notes", session.reload.session_notes
  end

  test "TooLong is an Error, so a surface that only cares about refusal catches both" do
    assert Sessions::UpdateNotes::TooLong < Sessions::UpdateNotes::Error
  end

  test "whitespace-only notes past the cap clear rather than being refused" do
    session = make_session(session_notes: "Old notes")

    Sessions::UpdateNotes.call(session: session, notes: " " * (Session::NOTES_MAX_LENGTH + 1))

    assert_nil session.reload.session_notes
  end

  [ 123, [ "a" ], { "a" => 1 }, ActionController::Parameters.new("a" => 1) ].each do |value|
    test "refuses a non-String #{value.class} rather than coercing it" do
      session = make_session(session_notes: "Old notes")

      error = assert_raises(Sessions::UpdateNotes::Error) do
        Sessions::UpdateNotes.call(session: session, notes: value)
      end

      assert_not_kind_of Sessions::UpdateNotes::TooLong, error
      assert_equal "session_notes must be a string.", error.message
      assert_equal "Old notes", session.reload.session_notes
    end
  end

  test "writes only the two notes columns" do
    session = make_session
    before = session.reload.attributes.except("session_notes", "session_notes_updated_at", "updated_at")

    Sessions::UpdateNotes.call(session: session, notes: "Blocked on review")

    assert_equal before, session.reload.attributes.except("session_notes", "session_notes_updated_at", "updated_at")
  end

  test "is safe to retry: a second identical call leaves the same notes" do
    session = make_session

    2.times { Sessions::UpdateNotes.call(session: session, notes: "Same") }

    assert_equal "Same", session.reload.session_notes
  end
end
