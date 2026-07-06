require "test_helper"

# Tests for the manual "blocked by" relationship between sessions.
class SessionBlockedByTest < ActiveSupport::TestCase
  def make_session(status: :needs_input, **attrs)
    Session.create!(
      agent_runtime: "claude_code",
      git_root: "https://github.com/test/repo.git",
      branch: "main",
      status: status,
      **attrs
    )
  end

  test "belongs_to blocked_by_session is optional" do
    session = make_session
    assert_nil session.blocked_by_session
    assert session.valid?
  end

  test "can mark a session as blocked by another" do
    blocker = make_session(status: :running)
    blocked = make_session(blocked_by_session: blocker)

    assert_equal blocker.id, blocked.blocked_by_session_id
    assert_includes blocker.blocked_sessions, blocked
  end

  test "effectively_blocked? is true when blocker is not archived" do
    blocker = make_session(status: :running)
    blocked = make_session(blocked_by_session: blocker)

    assert blocked.effectively_blocked?
  end

  test "effectively_blocked? is false when blocker is archived" do
    blocker = make_session(status: :running)
    blocked = make_session(blocked_by_session: blocker)

    blocker.update!(status: :archived)

    assert_not blocked.reload.effectively_blocked?
  end

  test "effectively_blocked? is false when not blocked at all" do
    assert_not make_session.effectively_blocked?
  end

  test "effectively_blocked scope returns only sessions blocked by a non-archived blocker" do
    blocker = make_session(status: :running)
    archived_blocker = make_session(status: :archived)
    blocked = make_session(blocked_by_session: blocker)
    make_session(blocked_by_session: archived_blocker) # stale block, should be excluded
    make_session # unblocked, should be excluded

    result = Session.effectively_blocked.to_a

    # Fixtures carry no blocked_by relationships, so the only effectively-blocked
    # session in the table is the one created here.
    assert_equal [ blocked.id ], result.map(&:id)
  end

  test "not_effectively_blocked scope excludes sessions blocked by a non-archived blocker" do
    blocker = make_session(status: :running)
    archived_blocker = make_session(status: :archived)
    blocked = make_session(blocked_by_session: blocker)
    stale_blocked = make_session(blocked_by_session: archived_blocker)
    unblocked = make_session

    result_ids = Session.not_effectively_blocked.pluck(:id)

    assert_not_includes result_ids, blocked.id
    assert_includes result_ids, stale_blocked.id
    assert_includes result_ids, unblocked.id
  end

  test "blocker archival auto-unblocks dependent sessions in the not_effectively_blocked scope" do
    blocker = make_session(status: :running)
    blocked = make_session(blocked_by_session: blocker)

    assert_not_includes Session.not_effectively_blocked.pluck(:id), blocked.id

    blocker.update!(status: :archived)

    assert_includes Session.not_effectively_blocked.pluck(:id), blocked.id
  end

  test "destroying blocker nullifies blocked_by_session_id" do
    blocker = make_session(status: :running)
    blocked = make_session(blocked_by_session: blocker)

    blocker.destroy!

    assert_nil blocked.reload.blocked_by_session_id
  end
end
