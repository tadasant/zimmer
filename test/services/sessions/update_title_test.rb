require "test_helper"
require "mocha/minitest"

# Sessions::UpdateTitle is the single writer behind all three rename surfaces
# (the web UI's editable title, a `title` in PATCH /api/v1/sessions/:id, and the
# `update_title` MCP action). What matters here is that a rename drops the
# auto-title flag — so SessionTitleJob cannot overwrite it — and that a refused
# rename leaves both the title and the flag alone.
class Sessions::UpdateTitleTest < ActiveSupport::TestCase
  def setup
    Session.any_instance.stubs(:broadcast_status_change)
    Session.any_instance.stubs(:broadcast_update_to_sessions_index)
    Session.any_instance.stubs(:broadcast_create_to_sessions_index)
  end

  # No title given, so the session gets the "Session <id>" placeholder and the
  # auto_generated_title flag — the state a rename has to move it out of.
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

  test "stores the stripped title, drops the auto-title flag, and logs the rename" do
    session = make_session
    assert_equal true, session.reload.metadata["auto_generated_title"]

    returned = nil
    assert_difference -> { session.logs.count }, 1 do
      returned = Sessions::UpdateTitle.call(session: session, title: "  Fix the flaky test  ")
    end

    assert_same session, returned
    session.reload
    assert_equal "Fix the flaky test", session.title
    assert_not session.metadata.key?("auto_generated_title")
    assert_equal "Session title updated to: Fix the flaky test", session.logs.order(:id).last.content
  end

  test "a renamed session is no longer one SessionTitleJob will re-title" do
    session = make_session
    Sessions::UpdateTitle.call(session: session, title: "Hand-picked")

    assert_no_enqueued_jobs(only: SessionTitleJob) { session.reload.enqueue_session_inference }
  end

  test "accepts a title exactly at the cap" do
    session = make_session
    Sessions::UpdateTitle.call(session: session, title: "a" * Session::TITLE_MAX_LENGTH)
    assert_equal "a" * Session::TITLE_MAX_LENGTH, session.reload.title
  end

  test "measures the cap after stripping" do
    session = make_session
    Sessions::UpdateTitle.call(session: session, title: " #{'a' * Session::TITLE_MAX_LENGTH} ")
    assert_equal "a" * Session::TITLE_MAX_LENGTH, session.reload.title
  end

  test "refuses a title past the cap and leaves the title, the flag and the log alone" do
    session = make_session
    original = session.reload.title

    error = assert_no_difference -> { session.logs.count } do
      assert_raises(Sessions::UpdateTitle::Error) do
        Sessions::UpdateTitle.call(session: session, title: "a" * (Session::TITLE_MAX_LENGTH + 1))
      end
    end

    assert_equal "Title is too long (maximum 100 characters)", error.message
    session.reload
    assert_equal original, session.title
    assert_equal true, session.metadata["auto_generated_title"]
  end

  test "refuses a blank title" do
    session = make_session
    [ nil, "", "   " ].each do |blank|
      error = assert_raises(Sessions::UpdateTitle::Error) { Sessions::UpdateTitle.call(session: session, title: blank) }
      assert_equal "Title cannot be empty", error.message
    end
    assert_equal true, session.reload.metadata["auto_generated_title"]
  end

  test "refuses a value that is not a String rather than coercing it" do
    session = make_session
    [ 123, [ "x" ], { "a" => 1 } ].each do |value|
      error = assert_raises(Sessions::UpdateTitle::Error) { Sessions::UpdateTitle.call(session: session, title: value) }
      assert_equal "Title must be a string", error.message
    end
  end

  test "keeps the other metadata keys" do
    session = make_session
    session.update_columns(metadata: session.reload.metadata.merge("keep_me" => "yes"))

    Sessions::UpdateTitle.call(session: session, title: "Renamed")

    assert_equal "yes", session.reload.metadata["keep_me"]
  end
end
