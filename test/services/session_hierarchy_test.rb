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

  # Both representations are kept, not just the winning one: SessionHierarchy has
  # to know which of them REACHED a session, and the column can win the
  # precedence contest while pointing outside the level being drawn.
  test "both recorded spawner ids are exposed, in precedence order" do
    column_parent = create_session
    metadata_parent = create_session
    child = create_session(parent: column_parent, router_metadata: metadata_parent)

    assert_equal [ column_parent.id, metadata_parent.id ], child.reload.lineage_parent_candidate_ids
    assert_equal column_parent.id, child.lineage_parent_id
    assert_equal [], create_session.lineage_parent_candidate_ids
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

    # Each node also carries {genesis · class} — see SessionGenesis.
    assert_match(/\A- ##{router.id} \[zimmer-router\] \{unknown · priority\} Router\n/, outline)
    assert_match(/^  - ##{worker.id} \[zimmer\] \{unknown · priority\} Worker ← this session$/, outline)
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

  # Regression: the downward walk used the same flag the UPWARD walk sets, so a
  # truncated upward walk ended the downward one after a single level. The graph
  # silently shrank — and with it the scope human messages are gathered over,
  # which is the one thing this feature exists to widen.
  test "an upward walk cut by the depth bound does not also cut the downward walk" do
    # Nine seniors above, so the upward walk is truncated...
    chain = Array.new(SessionHierarchy::MAX_DEPTH + 1) { create_session }
    chain.each_cons(2) { |junior, senior| SessionUncleLink.create!(session: junior, uncle_session: senior) }
    # ...and three spawn levels below the session we ask from.
    child = create_session(parent: chain.first)
    grandchild = create_session(parent: child)
    great_grandchild = create_session(parent: grandchild)

    ids = SessionHierarchy.new(chain.first).session_ids

    assert_includes ids, child.id
    assert_includes ids, grandchild.id, "the second level below must survive a truncated upward walk"
    assert_includes ids, great_grandchild.id, "and so must the third"
  end

  test "a spawn parent recorded in metadata that no longer exists is not reported as truncation" do
    ghost = create_session
    orphan = create_session(router_metadata: ghost)
    ghost.destroy!

    hierarchy = SessionHierarchy.new(orphan.reload)

    # The pointer is dead, not merely unwalked — `topmost` and `origin` both
    # treat it as "nothing above here", so this must agree with them.
    refute hierarchy.truncated?
    assert_equal orphan.id, hierarchy.origin.id
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

  # --- Which parent a node is DRAWN under (#571) ------------------------------
  #
  # Every surface — the outline, the detail page, both provenance MCP tools —
  # draws this graph with indentation and nothing else, so the ORDER of `nodes`
  # is the parent-child claim a reader actually gets. The walk discovers a whole
  # level at once and used to emit it in id order, which made every child of the
  # level read as a child of whichever sibling sorted last. The rows were right
  # and the picture was wrong.

  # Reads the outline the way a reader does: indentation, and nothing else.
  # Returns { session_id => the id of the line it is nested under }.
  def outline_parents(hierarchy)
    stack = {}
    hierarchy.to_outline.each_line.with_object({}) do |line, parents|
      indent = line[/\A */].length / 2
      id = line[/- #(\d+)/, 1].to_i
      parents[id] = stack[indent - 1]
      stack[indent] = id
    end
  end

  # The shape from every reported occurrence: one trigger creates a batch of
  # sibling routers in the same second, several of them spawn exactly one child
  # each with its own explicit parent_session_id, and the children all collapse
  # onto the last sibling. A test with one parent and one child passes
  # throughout this bug's life, which is why this one has eight and four.
  test "each of a batch of siblings keeps its own spawn child" do
    trigger = create_session(title: "Backlog top-up")
    routers = Array.new(8) { |i| create_session(parent: trigger, title: "Router #{i}") }
    spawners = routers.values_at(0, 1, 2, 3)
    children = spawners.map { |router| create_session(parent: router, title: "Child of ##{router.id}") }

    hierarchy = SessionHierarchy.new(routers.last)
    drawn = outline_parents(hierarchy)

    spawners.zip(children).each do |router, child|
      assert_equal router.id, child.reload.parent_session_id, "precondition: the row itself is correct"
      assert_equal router.id, drawn[child.id],
                   "##{child.id} is drawn under ##{drawn[child.id]}, but ##{router.id} spawned it"
    end

    (routers - spawners).each do |childless|
      refute_includes drawn.values, childless.id,
                      "##{childless.id} spawned nothing and must be drawn with no children"
    end
  end

  # Node#render_parent_id is the same claim without going through the text.
  test "a node names the parent it is drawn under" do
    trigger = create_session
    first = create_session(parent: trigger)
    second = create_session(parent: trigger)
    child_of_first = create_session(parent: first)

    nodes = SessionHierarchy.new(second).nodes.index_by(&:id)

    assert_equal first.id, nodes[child_of_first.id].render_parent_id
    assert_equal first.id, nodes[child_of_first.id].parent_id
    assert nodes[child_of_first.id].spawn_edge?
    assert_nil nodes[trigger.id].render_parent_id, "a root hangs from nothing"
  end

  # The original #6709 report: the child was drawn under a sibling created after
  # it. Ids are monotonic, so an id higher than the child's is impossible for a
  # spawn parent — but that tell only exists because this batch sorted that way,
  # which is why the test above does not rely on it.
  test "a child is never drawn under a sibling created after it" do
    origin = create_session(title: "Origin")
    real_parent = create_session(parent: origin, title: "Real parent")
    child = create_session(parent: real_parent, title: "Child")
    later_sibling = create_session(parent: origin, title: "Created after the child")

    drawn = outline_parents(SessionHierarchy.new(later_sibling))

    assert_equal real_parent.id, drawn[child.id]
    refute_equal later_sibling.id, drawn[child.id],
                 "a session cannot have been spawned by one that did not yet exist"
    assert_operator drawn[child.id], :<, child.id
  end

  # The metadata representation is a spawn edge too, so it has to hang from the
  # same place the column does.
  test "a batch recorded in custom_metadata is attributed the same way" do
    trigger = create_session
    routers = Array.new(4) { create_session(parent: trigger) }
    children = routers.map { |router| create_session(router_metadata: router) }

    drawn = outline_parents(SessionHierarchy.new(routers.last))

    routers.zip(children).each { |router, child| assert_equal router.id, drawn[child.id] }
  end

  # Depth is what the breadth-first walk decided; only the order moves. A node
  # reachable by two paths still renders once, at the shallower depth.
  test "reordering preserves the depth of every node" do
    trigger = create_session
    routers = Array.new(3) { create_session(parent: trigger) }
    children = routers.map { |router| create_session(parent: router) }
    grandchild = create_session(parent: children.first)

    depths = SessionHierarchy.new(routers.last).nodes.to_h { |n| [ n.id, n.depth ] }

    assert_equal 0, depths[trigger.id]
    routers.each { |router| assert_equal 1, depths[router.id] }
    children.each { |child| assert_equal 2, depths[child.id] }
    assert_equal 3, depths[grandchild.id]
  end

  # Reordering must never change the node SET: that set is the scope the
  # human-message record is gathered over, so a node gained here is a human
  # message a session may read that it could not before.
  test "reordering changes the order and not the set" do
    trigger = create_session
    routers = Array.new(5) { create_session(parent: trigger) }
    children = routers.map { |router| create_session(parent: router) }
    expected = ([ trigger ] + routers + children).map(&:id)

    hierarchy = SessionHierarchy.new(routers.first)

    assert_equal expected.sort, hierarchy.session_ids.sort
    assert_equal expected.size, hierarchy.size
    assert_equal hierarchy.session_ids.uniq, hierarchy.session_ids
  end

  # A subtree is contiguous: a reader scanning down from a node sees that node's
  # descendants before the next sibling, which is what indentation promises.
  test "a subtree is emitted contiguously" do
    trigger = create_session
    first = create_session(parent: trigger)
    second = create_session(parent: trigger)
    first_child = create_session(parent: first)
    first_grandchild = create_session(parent: first_child)
    second_child = create_session(parent: second)

    ids = SessionHierarchy.new(trigger).session_ids

    assert_equal [ trigger.id, first.id, first_child.id, first_grandchild.id, second.id, second_child.id ], ids
  end

  # Indentation is documented as the spawn edge on all three surfaces, so a node
  # the walk could only reach through an uncle has to say that is what it is.
  test "a node drawn under an uncle says so rather than implying a spawn edge" do
    # The uncle sits at depth 0 while the junior's own spawn parent sits a level
    # deeper, so the downward walk reaches the junior through the uncle first and
    # renders it there — at its shallowest depth, which is the DAG rule. The row
    # still records the spawn parent; it is the indentation that cannot show it.
    origin = create_session(title: "Origin")
    spawn_parent = create_session(parent: origin, title: "Spawn parent")
    junior = create_session(parent: spawn_parent, title: "Junior")
    senior = create_session(title: "Senior")
    link(junior, senior)

    hierarchy = SessionHierarchy.new(junior)
    node = hierarchy.nodes.find { |n| n.id == junior.id }

    assert_equal senior.id, node.render_parent_id
    assert_equal spawn_parent.id, node.parent_id, "the spawn edge is still recorded on the node"
    refute node.spawn_edge?
    assert_includes hierarchy.to_outline, "shown under uncle ##{senior.id}"
  end

  test "a spawn parent in the level above beats an uncle in the same level" do
    origin = create_session
    spawn_parent = create_session(parent: origin)
    uncle = create_session(parent: origin)
    child = create_session(parent: spawn_parent)
    link(child, uncle)

    node = SessionHierarchy.new(origin).nodes.find { |n| n.id == child.id }

    assert_equal spawn_parent.id, node.render_parent_id
    assert node.spawn_edge?
    assert_equal [ uncle.id ], node.uncles, "the uncle is still named, just not drawn under"
  end

  # The column wins the precedence contest but points OUTSIDE the level being
  # drawn, while the metadata key points into it. Resolving the attachment with
  # `lineage_parent_id` alone would leave this child unattachable — and an
  # unattachable child is emitted after the whole tree at its old depth, which
  # is the same wrong picture in a new shape.
  test "a child is drawn under whichever recorded spawner actually reached it" do
    outsider = create_session(title: "Outside this level")
    trigger = create_session(title: "Trigger")
    router = create_session(parent: trigger, title: "Router")
    child = create_session(parent: outsider, router_metadata: router, title: "Child")

    hierarchy = SessionHierarchy.new(router)
    node = hierarchy.nodes.find { |n| n.id == child.id }

    assert_equal router.id, outline_parents(hierarchy)[child.id]
    assert_equal router.id, node.render_parent_id
    assert node.spawn_edge?, "the metadata key is a spawn claim too"
  end

  # A junior with no spawn parent at all: indentation puts it under its uncle,
  # and there is no spawn parent for the marker to call it "not".
  test "a parentless junior drawn under an uncle is not said to have a spawn parent" do
    senior = create_session(title: "Senior")
    junior = create_session(title: "Started from the web UI")
    link(junior, senior)
    # Asked from the senior, so the junior is reached DOWNWARD through the uncle
    # edge rather than being a root in its own right.
    outline = SessionHierarchy.new(senior).to_outline

    assert_includes outline, "it has no spawn parent"
    refute_includes outline, "not its spawn parent"
  end

  # The one node no edge places: the requested session, appended so the reader
  # can see it after the ceiling cut the branch it lives on. It is drawn indented
  # under whatever came last, so it must not claim that as a spawn edge.
  test "a session the node ceiling forced into view does not claim a spawn edge" do
    root = create_session(title: "Prolific router")
    children = Array.new(SessionHierarchy::MAX_NODES + 5) { create_session(parent: root) }
    stranded = children.last

    hierarchy = SessionHierarchy.new(stranded)
    node = hierarchy.nodes.find { |n| n.id == stranded.id }

    assert hierarchy.truncated?
    assert_equal 1, hierarchy.nodes.count(&:current?)
    assert node.ceiling_placed
    refute node.spawn_edge?, "no edge put this node where it is drawn"
    assert_operator node.depth, :>, 0, "never drawn as a sibling of the origin"
    assert hierarchy.redrawn_edges?
    assert_includes hierarchy.to_outline, "the node ceiling cut its branch"
  end

  # Even at the ceiling, the set is the set: nothing is invented to make the
  # tree drawable, because the set is what human messages are gathered over.
  test "the node ceiling still bounds the graph once the fallback has run" do
    root = create_session
    children = Array.new(SessionHierarchy::MAX_NODES + 5) { create_session(parent: root) }

    hierarchy = SessionHierarchy.new(children.last)

    assert_operator hierarchy.size, :<=, SessionHierarchy::MAX_NODES + 1
    assert_equal hierarchy.session_ids.uniq, hierarchy.session_ids
  end
end
