# frozen_string_literal: true

require "test_helper"

class SessionHierarchyTest < ActiveSupport::TestCase
  def create_session(parent: nil, router_metadata: nil, title: nil, agent_root: nil)
    session = Session.create!(
      agent_runtime: "claude_code",
      prompt: "work",
      git_root: "https://github.com/test/repo.git",
      branch: "main",
      title: title,
      parent_session_id: parent&.id
    )
    session.update!(custom_metadata: { "router_session_id" => router_metadata.id }) if router_metadata
    session.update!(metadata: (session.metadata || {}).merge("agent_root_key" => agent_root)) if agent_root
    session
  end

  test "a session with no edges is alone in its tree" do
    session = create_session
    hierarchy = SessionHierarchy.new(session)

    assert hierarchy.solitary?
    assert_equal 1, hierarchy.size
    assert_equal session.id, hierarchy.origin.id
    assert hierarchy.nodes.first.current?
  end

  test "the origin is the highest ancestor" do
    root = create_session
    middle = create_session(parent: root)
    leaf = create_session(parent: middle)

    assert_equal root.id, SessionHierarchy.new(leaf).origin.id
    assert_equal [ middle.id, root.id ], SessionHierarchy.new(leaf).ancestors.map(&:id)
  end

  # The edge is derived, not backfilled: sessions spawned before
  # parent_session_id was wired recorded it in custom_metadata.
  test "an edge recorded only in custom_metadata is derived" do
    router = create_session
    worker = create_session(router_metadata: router)

    assert_equal router.id, worker.reload.lineage_parent_id
    assert_equal router.id, SessionHierarchy.new(worker).origin.id
  end

  test "the parent_session_id column wins over the metadata fallback" do
    column_parent = create_session
    metadata_parent = create_session
    child = create_session(parent: column_parent, router_metadata: metadata_parent)

    assert_equal column_parent.id, child.reload.lineage_parent_id
  end

  test "a non-numeric router_session_id is ignored rather than raising" do
    session = create_session
    session.update!(custom_metadata: { "router_session_id" => "not-an-id" })

    assert_nil session.reload.lineage_parent_id
  end

  # The tree goes DOWN as well as up — this is what a per-session ancestor walk
  # could not do.
  test "the tree includes descendants and siblings, not just ancestors" do
    router = create_session(title: "Router")
    worker_a = create_session(parent: router, title: "Worker A")
    worker_b = create_session(router_metadata: router, title: "Worker B")
    helper = create_session(parent: worker_a, title: "Helper")

    hierarchy = SessionHierarchy.new(worker_b)
    ids = hierarchy.session_ids

    assert_equal [ router.id, worker_a.id, worker_b.id, helper.id ].sort, ids.sort
    assert_equal router.id, hierarchy.origin.id
    refute hierarchy.solitary?
    assert hierarchy.nodes.find { |n| n.id == worker_b.id }.current?
    refute hierarchy.nodes.find { |n| n.id == worker_a.id }.current?
  end

  test "children resolves both edge representations" do
    router = create_session
    by_column = create_session(parent: router)
    by_metadata = create_session(router_metadata: router)

    assert_equal [ by_column.id, by_metadata.id ].sort,
                 SessionHierarchy.new(router).children.map(&:id).sort
  end

  test "nodes carry depth relative to the origin" do
    root = create_session
    middle = create_session(parent: root)
    leaf = create_session(parent: middle)

    depths = SessionHierarchy.new(leaf).nodes.to_h { |n| [ n.id, n.depth ] }

    assert_equal 0, depths[root.id]
    assert_equal 1, depths[middle.id]
    assert_equal 2, depths[leaf.id]
  end

  test "nodes carry the title and agent root a reader identifies a session by" do
    session = create_session(title: "Fix the login bug", agent_root: "zimmer")

    node = SessionHierarchy.new(session).nodes.first

    assert_equal "Fix the login bug", node.label
    assert_equal "zimmer", node.agent_root_label
  end

  test "an untitled session falls back to its id rather than rendering blank" do
    session = create_session
    session.update_column(:title, nil)

    node = SessionHierarchy.new(session.reload).nodes.first

    assert_equal "Session ##{session.id}", node.label
    assert_equal "—", node.agent_root_label
  end

  test "a parent cycle does not loop forever" do
    a = create_session
    b = create_session(parent: a)
    a.update_column(:parent_session_id, b.id)

    hierarchy = SessionHierarchy.new(b)

    assert_includes hierarchy.session_ids, b.id
    assert_operator hierarchy.size, :<=, SessionHierarchy::MAX_NODES
  end

  test "the walk upward is depth-bounded" do
    session = create_session
    oldest = session
    (SessionHierarchy::MAX_DEPTH + 3).times { session = create_session(parent: session) }

    refute_equal oldest.id, SessionHierarchy.new(session).origin.id
  end

  # A truncated tree says so rather than quietly showing a slice.
  test "a tree deeper than the bound is reported as truncated" do
    root = create_session
    node = root
    (SessionHierarchy::MAX_DEPTH + 2).times { node = create_session(parent: node) }

    hierarchy = SessionHierarchy.new(root)

    assert hierarchy.truncated?
    assert_match(/larger/, hierarchy.truncation_reason)
  end

  test "the requested session is always visible even when the tree is truncated" do
    root = create_session
    node = root
    (SessionHierarchy::MAX_DEPTH + 2).times { node = create_session(parent: node) }

    hierarchy = SessionHierarchy.new(root)

    assert_includes hierarchy.session_ids, root.id
    assert hierarchy.nodes.any?(&:current?)
  end

  test "the outline marks the current session and indents by depth" do
    router = create_session(title: "Router", agent_root: "zimmer-router")
    worker = create_session(parent: router, title: "Worker", agent_root: "zimmer")

    outline = SessionHierarchy.new(worker).to_outline

    assert_match(/\A- ##{router.id} \[zimmer-router\] Router\n/, outline)
    assert_match(/^  - ##{worker.id} \[zimmer\] Worker ← this session$/, outline)
  end
end
