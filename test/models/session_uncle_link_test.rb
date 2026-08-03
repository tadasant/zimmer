# frozen_string_literal: true

require "test_helper"

class SessionUncleLinkTest < ActiveSupport::TestCase
  def create_session
    Session.create!(
      agent_runtime: "claude_code",
      prompt: "work",
      git_root: "https://github.com/test/repo.git",
      branch: "main"
    )
  end

  test "an edge joins two sessions in one direction" do
    junior = create_session
    senior = create_session

    link = SessionUncleLink.create!(session: junior, uncle_session: senior)

    assert_equal [ senior.id ], junior.reload.uncle_sessions.map(&:id)
    assert_equal [ junior.id ], senior.reload.junior_sessions.map(&:id)
    assert_nil link.source
  end

  test "a self edge is rejected" do
    session = create_session

    link = SessionUncleLink.new(session: session, uncle_session: session)

    refute link.valid?
    assert_includes link.errors[:uncle_session_id], "cannot be the session itself"
  end

  test "the same pair cannot be recorded twice" do
    junior = create_session
    senior = create_session
    SessionUncleLink.create!(session: junior, uncle_session: senior)

    duplicate = SessionUncleLink.new(session: junior, uncle_session: senior)
    refute duplicate.valid?
  end

  test "the reverse pair is a different edge" do
    a = create_session
    b = create_session
    SessionUncleLink.create!(session: a, uncle_session: b)

    assert SessionUncleLink.new(session: b, uncle_session: a).valid?
  end

  test "creating an uncle edge broadcasts refreshed provenance panels across the joined hierarchy" do
    junior = create_session
    senior = create_session
    broadcasts = []
    Turbo::StreamsChannel.stubs(:broadcast_replace_to).with do |stream, **options|
      broadcasts << [ stream, options ]
      true
    end

    SessionUncleLink.create!(session: junior, uncle_session: senior)

    junior_broadcast = broadcasts.find do |stream, options|
      stream == "session_#{junior.id}_status" &&
        options[:target] == "session_#{junior.id}_provenance"
    end
    senior_broadcast = broadcasts.find do |stream, options|
      stream == "session_#{senior.id}_status" &&
        options[:target] == "session_#{senior.id}_provenance"
    end

    assert junior_broadcast, "Expected junior provenance panel to refresh when an uncle edge is recorded"
    assert senior_broadcast, "Expected senior provenance panel to refresh when an uncle edge is recorded"
    assert_includes junior_broadcast.last[:html], "also senior:"
    assert_includes junior_broadcast.last[:html], "##{senior.id}"
  end

  # Unlike parent_session_id (SET NULL), an edge with one end missing asserts
  # nothing — so it goes away with either session, by row-level delete too.
  test "a row level delete of either session removes the edge" do
    junior = create_session
    senior = create_session
    SessionUncleLink.create!(session: junior, uncle_session: senior)

    Session.where(id: senior.id).delete_all
    assert_equal 0, SessionUncleLink.count

    other = create_session
    SessionUncleLink.create!(session: junior, uncle_session: other)
    Session.where(id: junior.id).delete_all
    assert_equal 0, SessionUncleLink.count
  end

  test "destroying a session removes edges in both directions" do
    middle = create_session
    above = create_session
    below = create_session
    SessionUncleLink.create!(session: middle, uncle_session: above)
    SessionUncleLink.create!(session: below, uncle_session: middle)

    middle.destroy!

    assert_equal 0, SessionUncleLink.count
  end
end
