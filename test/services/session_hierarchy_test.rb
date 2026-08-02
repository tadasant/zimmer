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

    hierarchy = SessionHierarchy.new(leaf)
    assert_equal root.id, hierarchy.origin.id
    refute hierarchy.truncated?
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

  test "the tree resolves both edge representations" do
    router = create_session
    by_column = create_session(parent: router)
    by_metadata = create_session(router_metadata: router)

    assert_equal [ router.id, by_column.id, by_metadata.id ].sort,
                 SessionHierarchy.new(router).session_ids.sort
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

  test "the walk upward is depth-bounded, and says so rather than claiming a false origin" do
    session = create_session
    oldest = session
    (SessionHierarchy::MAX_DEPTH + 3).times { session = create_session(parent: session) }

    hierarchy = SessionHierarchy.new(session)

    refute_equal oldest.id, hierarchy.origin.id
    assert hierarchy.truncated?,
           "a tree rooted at a session that still has a parent is a subtree, and must say so"
    assert_match(/larger/, hierarchy.truncation_reason)
  end

  test "a tree exactly at the depth bound is reported complete" do
    root = create_session
    node = root
    SessionHierarchy::MAX_DEPTH.times { node = create_session(parent: node) }

    hierarchy = SessionHierarchy.new(root)

    refute hierarchy.truncated?
    assert_nil hierarchy.truncation_reason
    assert_equal SessionHierarchy::MAX_DEPTH + 1, hierarchy.size
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
    deepest = node

    # Requested from the DEEPEST session, so the downward walk from the origin
    # genuinely runs out of depth before reaching it — the case the fallback
    # exists for. Asking from the root would put it in `seen` immediately and
    # the branch would never execute.
    hierarchy = SessionHierarchy.new(deepest)

    assert_includes hierarchy.session_ids, deepest.id
    assert_equal 1, hierarchy.nodes.count(&:current?)
    assert hierarchy.truncated?
    # Never drawn as a sibling of the origin.
    assert_operator hierarchy.nodes.find(&:current?).depth, :>, 0
  end

  test "the outline marks the current session and indents by depth" do
    router = create_session(title: "Router", agent_root: "zimmer-router")
    worker = create_session(parent: router, title: "Worker", agent_root: "zimmer")

    outline = SessionHierarchy.new(worker).to_outline

    assert_match(/\A- ##{router.id} \[zimmer-router\] Router\n/, outline)
    assert_match(/^  - ##{worker.id} \[zimmer\] Worker ← this session$/, outline)
  end

  # --- Uncle edges: the graph is a DAG ---------------------------------------

  def link(junior, uncle)
    SessionUncleLink.create!(session: junior, uncle_session: uncle, source: "test")
  end

  test "an uncle edge pulls the senior and its whole tree into the hierarchy" do
    other_root = create_session(title: "Other root")
    senior = create_session(parent: other_root, title: "Senior")
    target = create_session(title: "Target")
    link(target, senior)

    hierarchy = SessionHierarchy.new(target)

    assert_includes hierarchy.session_ids, senior.id
    assert_includes hierarchy.session_ids, other_root.id
    assert_includes hierarchy.session_ids, target.id
    refute hierarchy.solitary?
  end

  test "the origin stays the spawn origin even when an uncle sits in another tree" do
    spawn_root = create_session
    target = create_session(parent: spawn_root)
    other_root = create_session
    senior = create_session(parent: other_root)
    link(target, senior)

    hierarchy = SessionHierarchy.new(target)

    assert_equal spawn_root.id, hierarchy.origin.id, "an uncle edge must not relocate the origin"
    assert_includes hierarchy.root_ids, spawn_root.id
    assert_includes hierarchy.root_ids, other_root.id
    assert_equal spawn_root.id, hierarchy.root_ids.first, "the spawn origin leads"
  end

  test "a session with only an uncle is not solitary and reports both roots" do
    senior = create_session
    target = create_session
    link(target, senior)

    hierarchy = SessionHierarchy.new(target)

    refute hierarchy.solitary?
    assert_equal 2, hierarchy.size
    assert_equal target.id, hierarchy.origin.id, "no spawn parent means the session is its own spawn origin"
    assert_includes hierarchy.root_ids, senior.id
  end

  test "the uncle's own juniors are reachable from the junior's hierarchy" do
    senior = create_session
    target = create_session
    sibling = create_session
    link(target, senior)
    link(sibling, senior)

    assert_includes SessionHierarchy.new(target).session_ids, sibling.id
  end

  test "a session reachable by both a spawn and an uncle path appears once at the shallower depth" do
    root = create_session
    child = create_session(parent: root)
    grandchild = create_session(parent: child)
    # root is now senior to grandchild by two paths: root → child → grandchild,
    # and the direct uncle edge.
    link(grandchild, root)

    nodes = SessionHierarchy.new(grandchild).nodes

    assert_equal 1, nodes.count { |n| n.id == grandchild.id }
    assert_equal 1, nodes.find { |n| n.id == grandchild.id }.depth
  end

  test "a node carries its uncle ids and the outline names them" do
    senior = create_session(title: "Senior", agent_root: "zimmer-router")
    target = create_session(title: "Target", agent_root: "zimmer")
    link(target, senior)

    hierarchy = SessionHierarchy.new(target)
    node = hierarchy.nodes.find { |n| n.id == target.id }

    assert_equal [ senior.id ], node.uncles
    assert node.uncles?
    assert hierarchy.uncle_edges?
    assert_includes hierarchy.to_outline, "(also senior: ##{senior.id})"
  end

  test "a session with no uncle edges reports none" do
    root = create_session
    child = create_session(parent: root)

    hierarchy = SessionHierarchy.new(child)

    refute hierarchy.uncle_edges?
    assert_equal [], hierarchy.nodes.find { |n| n.id == child.id }.uncles
    refute_includes hierarchy.to_outline, "also senior"
  end

  # A node must never name a session the reader cannot see: the uncle ids are
  # filtered to the rendered graph, so every id on a node resolves to a node.
  test "every uncle id named on a node is itself in the graph" do
    senior = create_session
    target = create_session
    juniors = Array.new(5) { create_session }
    link(target, senior)
    juniors.each { |j| link(j, senior) }

    hierarchy = SessionHierarchy.new(target)
    visible = hierarchy.session_ids.to_set

    hierarchy.nodes.each do |node|
      node.uncles.each { |uncle_id| assert_includes visible, uncle_id }
    end
  end

  test "several uncles are all recorded on the node" do
    first = create_session
    second = create_session
    target = create_session
    link(target, first)
    link(target, second)

    node = SessionHierarchy.new(target).nodes.find { |n| n.id == target.id }

    assert_equal [ first.id, second.id ].sort, node.uncles.sort
    assert_includes node.uncle_summary, "##{first.id}"
    assert_includes node.uncle_summary, "##{second.id}"
  end

  # The traversal must survive a cycle even though RecordUncleEdge refuses to
  # create one — a bound that assumes every writer was correct is not a bound.
  test "a two-cycle written directly does not hang the walk" do
    a = create_session
    b = create_session
    SessionUncleLink.create!(session: a, uncle_session: b)
    SessionUncleLink.create!(session: b, uncle_session: a)

    hierarchy = nil
    assert_nothing_raised { hierarchy = SessionHierarchy.new(a) }

    assert_equal 2, hierarchy.size
    assert_equal [ a.id, b.id ].sort, hierarchy.session_ids.sort
  end

  test "a longer cycle written directly does not hang the walk" do
    a = create_session
    b = create_session
    c = create_session
    SessionUncleLink.create!(session: b, uncle_session: a)
    SessionUncleLink.create!(session: c, uncle_session: b)
    SessionUncleLink.create!(session: a, uncle_session: c)

    hierarchy = SessionHierarchy.new(a)

    assert_operator hierarchy.size, :<=, SessionHierarchy::MAX_NODES
    assert_includes hierarchy.session_ids, a.id
  end

  test "an upward chain of uncle edges deeper than MAX_DEPTH is reported truncated" do
    chain = Array.new(SessionHierarchy::MAX_DEPTH + 3) { create_session }
    chain.each_cons(2) { |junior, senior| SessionUncleLink.create!(session: junior, uncle_session: senior) }

    hierarchy = SessionHierarchy.new(chain.first)

    assert hierarchy.truncated?
    assert_includes hierarchy.session_ids, chain.first.id
    assert_operator hierarchy.size, :<=, SessionHierarchy::MAX_NODES
  end

  test "the node ceiling still holds with uncle edges" do
    senior = create_session
    juniors = Array.new(20) { create_session }
    juniors.each { |j| SessionUncleLink.create!(session: j, uncle_session: senior) }

    hierarchy = SessionHierarchy.new(juniors.first)

    assert_operator hierarchy.size, :<=, SessionHierarchy::MAX_NODES
    assert_includes hierarchy.session_ids, juniors.first.id
  end

  test "an uncle edge widens the scope human messages are gathered over" do
    senior = create_session(title: "Senior")
    target = create_session(title: "Target")
    link(target, senior)

    assert_includes SessionHierarchy.new(target).session_ids, senior.id
    assert_includes SessionHierarchy.new(senior).session_ids, target.id
  end
end
