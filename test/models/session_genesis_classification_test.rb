# frozen_string_literal: true

require "test_helper"

# How a session gets its genesis, and how that genesis answers spot/priority.
class SessionGenesisClassificationTest < ActiveSupport::TestCase
  def build_session(**attrs)
    Session.create!({ git_root: "https://github.com/test/repo.git", prompt: "Test" }.merge(attrs))
  end

  # --- assignment -------------------------------------------------------------

  test "an explicit genesis is kept" do
    session = build_session(genesis: SessionGenesis::WEB_UI)
    assert_equal SessionGenesis::WEB_UI, session.genesis
  end

  test "a parentless session with no declared genesis falls back to unknown" do
    session = build_session
    assert_equal SessionGenesis::UNKNOWN, session.genesis
    # ...and unknown is priority, so an unaccounted-for path is never throttled.
    assert session.priority?
  end

  test "a spawned session inherits its parent's genesis" do
    parent = build_session(genesis: SessionGenesis::GITHUB_ISSUE)
    child = build_session(parent_session_id: parent.id)

    assert_equal SessionGenesis::GITHUB_ISSUE, child.genesis,
      "an agent spawn belongs to the same line of work as its parent"
    assert child.spot?
  end

  test "inheritance survives a chain of spawns" do
    root = build_session(genesis: SessionGenesis::SLACK)
    mid = build_session(parent_session_id: root.id)
    leaf = build_session(parent_session_id: mid.id)

    assert_equal SessionGenesis::SLACK, leaf.genesis
    assert leaf.priority?
  end

  test "an explicit genesis outranks inheritance" do
    # This is the chat-bubble case: a human types into the web app from a page
    # showing a spot session. The human's message must not inherit spot.
    parent = build_session(genesis: SessionGenesis::GITHUB_ISSUE)
    child = build_session(parent_session_id: parent.id, genesis: SessionGenesis::WEB_UI)

    assert_equal SessionGenesis::WEB_UI, child.genesis
    assert child.priority?
  end

  test "a fork inherits through the fork marker" do
    source = build_session(genesis: SessionGenesis::SLACK)
    fork = build_session(metadata: { "forked_from_session_id" => source.id })

    assert_equal SessionGenesis::SLACK, fork.genesis
  end

  test "a missing parent does not blow up assignment" do
    session = build_session(parent_session_id: 999_999_999)
    assert_equal SessionGenesis::UNKNOWN, session.genesis
  end

  test "an unknown genesis value is rejected" do
    session = Session.new(git_root: "https://github.com/test/repo.git", prompt: "T", genesis: "carrier_pigeon")
    refute session.valid?
    assert session.errors[:genesis].any?
  end

  # --- derived class ----------------------------------------------------------

  test "priority_class derives live, so promoting a genesis moves existing sessions" do
    session = build_session(genesis: SessionGenesis::GITHUB_ISSUE)
    assert session.spot?

    # The promotion is a policy change, not a backfill: the row is untouched.
    overrides = { SessionGenesis::GITHUB_ISSUE => SessionGenesis::PRIORITY }
    assert session.priority?(overrides)
    assert_equal SessionGenesis::GITHUB_ISSUE, session.reload.genesis
  end

  test "genesis_key reads a NULL genesis as unknown" do
    session = build_session(genesis: SessionGenesis::WEB_UI)
    session.update_columns(genesis: nil)

    assert_equal SessionGenesis::UNKNOWN, session.reload.genesis_key
    assert session.priority?
  end

  # --- scopes -----------------------------------------------------------------

  test "spot and priority scopes partition by resolved class" do
    spot_one = build_session(genesis: SessionGenesis::GITHUB_ISSUE)
    priority_one = build_session(genesis: SessionGenesis::WEB_UI)

    assert_includes Session.spot.pluck(:id), spot_one.id
    refute_includes Session.spot.pluck(:id), priority_one.id
    assert_includes Session.priority.pluck(:id), priority_one.id
  end

  test "the priority scope sweeps up NULL genesis rows" do
    session = build_session(genesis: SessionGenesis::WEB_UI)
    session.update_columns(genesis: nil)

    assert_includes Session.priority.pluck(:id), session.id
    refute_includes Session.spot.pluck(:id), session.id
  end

  test "with_genesis filters to one kind" do
    target = build_session(genesis: SessionGenesis::SCHEDULE)
    other = build_session(genesis: SessionGenesis::WEB_UI)

    ids = Session.with_genesis(SessionGenesis::SCHEDULE).pluck(:id)
    assert_includes ids, target.id
    refute_includes ids, other.id
  end

  test "genesis_counts excludes archived sessions" do
    build_session(genesis: SessionGenesis::AO_EVENT)
    archived = build_session(genesis: SessionGenesis::AO_EVENT)
    archived.update_columns(status: Session.statuses[:archived])

    assert_equal 1, Session.genesis_counts[SessionGenesis::AO_EVENT]
  end
end
