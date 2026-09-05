# frozen_string_literal: true

# The whole family of sessions a given session belongs to: the roots at the top,
# and every descendant beneath them — not just the chain of ancestors above the
# session you asked about.
#
# ## Two kinds of edge
#
# **Spawn.** "Session A spawned session B." One per session, immutable, so the
# spawn edges alone form a tree. This does NOT mean "A most recently talked to
# B": a session routinely gets followed up by a router other than the one that
# spawned it, and reading a spawn edge as "who talked to it last" would be wrong.
#
# **Uncle.** "Session A inspected session B and decided to queue or interrupt
# it." The premise is that A therefore holds information B does not, so A is
# senior — an additional parent, sibling to the spawn parent. A session can
# collect several of these over its life, and they can join two sessions with no
# spawn relationship at all, so the combined graph is a DAG rather than a tree.
# Written only by Sessions::RecordUncleEdge, which is where the rules live.
#
# Where each edge lives. Spawn is the first-class `parent_session_id` column,
# which `start_session` (MCP and REST) can set. Sessions spawned before that was
# wired recorded the same fact in `custom_metadata` as `router_session_id`, so
# the tree is DERIVED from both — the column first, that key as a fallback.
# Deriving rather than migrating is deliberate: it needs no backfill, it is
# reversible, and it never rewrites what a session recorded about itself. See
# Session#lineage_parent_id. Uncle edges live in `session_uncle_links`; they are
# new, so there is nothing to derive and no backfill to skip.
#
# ## What a DAG changes
#
# A session can now be reached by more than one path, so the walk is
# breadth-first with a `seen` set and each session is rendered once, at its
# SHALLOWEST depth. The upward walk can also arrive at more than one root — an
# uncle in a hierarchy the session was not spawned into brings that whole
# hierarchy along — so `roots` is plural. `origin` stays singular and stays the
# root of the SPAWN chain: spawning happened once and cannot change, whereas a
# root chosen from uncle edges would move whenever someone interrupted this
# session. A stable answer to "where did this come from" is worth more than a
# maximal one.
class SessionHierarchy
  # How far up from the requested session to look for its roots, and how deep
  # below them to render.
  #
  # Deep enough for the shapes that actually occur (router → worker → helper,
  # and a gate session spawned off a worker), shallow enough that a cycle or a
  # pathological chain cannot turn a page render into an unbounded walk.
  MAX_DEPTH = 8

  # Hard ceiling on nodes visited. A router that has spawned hundreds of
  # sessions would otherwise make its own detail page render the entire fleet.
  # Applies to the upward walk too: uncle edges mean "up" is no longer a single
  # chain and can fan out just as widely as "down".
  MAX_NODES = 150

  # One session in the tree, with everything a renderer needs and nothing more.
  #
  # `parent_id` is the spawn parent and stays exactly what it was.
  # `uncle_ids` is the additional seniors, which a renderer must show separately
  # — indentation can only express one parent, so an uncle edge is invisible in
  # the outline unless it is named.
  #
  # `render_parent_id` is the node this one is drawn UNDER, which is the whole
  # of what indentation asserts. It is normally the spawn parent; it is an uncle
  # only when the walk reached this session through one and its spawn parent was
  # not in the level above. `via_uncle` says which, so a renderer never lets
  # indentation claim a spawn edge that does not exist.
  Node = Struct.new(:id, :title, :agent_root, :status, :depth, :parent_id, :uncle_ids, :current,
                    :genesis, :priority_class, :render_parent_id, :via_uncle, keyword_init: true) do
    def current? = current

    # True when the indentation under this node's rendered parent really is a
    # spawn edge — which is what every surface documents indentation to mean.
    def spawn_edge? = !via_uncle

    def label = title.presence || "Session ##{id}"

    # The agent root a reader identifies a session by, or an honest blank.
    def agent_root_label = agent_root.presence || "—"

    def uncles = Array(uncle_ids)

    def uncles? = uncles.any?

    # "also senior: #4, #9" — the phrasing the UI, the outline, and the MCP
    # markdown all use, so the three surfaces cannot describe the same edge
    # differently.
    def uncle_summary = "also senior: #{uncles.map { |uid| "##{uid}" }.join(', ')}"

    # Where this session's line of work came from, and what that buys it in the
    # scheduler. Shown on every node because genesis is inherited down a lineage:
    # seeing it beside each session is what makes "this whole branch is spot"
    # legible, and what makes an outlier — a web_ui session hanging off a
    # github_issue root — visible at a glance rather than a surprise later.
    def genesis_label = SessionGenesis.label(genesis)

    def spot? = priority_class == SessionGenesis::SPOT

    # "web_ui · priority" — the phrasing shared by the UI panel and the MCP
    # outline, so both surfaces describe a node identically.
    def genesis_summary = "#{genesis.presence || SessionGenesis::DEFAULT_KEY} · #{priority_class}"
  end

  attr_reader :session

  def initialize(session)
    @session = session
  end

  # The origin session: the highest SPAWN ancestor reachable within MAX_DEPTH.
  # Returns the session itself when it has no recorded spawn parent.
  #
  # Deliberately blind to uncle edges. Spawning happened once and is a fact about
  # the past; an origin computed over uncle edges too would change every time
  # some other session interrupted this one, and "where did this session come
  # from" would stop having a stable answer. Uncle edges still widen the rendered
  # tree — see #roots — they just do not get to relocate its origin.
  #
  # Sets @origin_truncated when the walk stopped on the bound rather than on a
  # session with no parent — i.e. this is NOT really the origin. Without that,
  # a chain deeper than MAX_DEPTH would render as a complete tree rooted at a
  # session that has a parent, which is a lie the reader has no way to catch.
  def origin
    return @origin if defined?(@origin)

    current = session
    seen = Set.new([ session.id ])
    @origin_truncated = false

    MAX_DEPTH.times do
      parent_id = current.lineage_parent_id
      break if parent_id.blank? || seen.include?(parent_id)

      parent = Session.find_by(id: parent_id)
      break if parent.nil?

      seen << parent.id
      current = parent
    end

    # One more look: if the session we stopped on still has a reachable parent,
    # we ran out of budget rather than reaching the top.
    if current.lineage_parent_id.present? && !seen.include?(current.lineage_parent_id)
      @origin_truncated = Session.exists?(id: current.lineage_parent_id)
    end

    @origin = current
  end

  # Every session the tree should be rendered from: the spawn origin, plus any
  # other root reached by walking up BOTH edge kinds.
  #
  # An uncle in a hierarchy this session was never spawned into is exactly the
  # case that motivates the whole feature — the senior that interrupted us holds
  # the human context we need — and seeding the downward walk only from the spawn
  # origin would leave that senior, and everything above it, out of the tree
  # entirely.
  #
  # The spawn origin is always first, so the ordinary single-parent case renders
  # exactly as it did before. Sets @upward_truncated when the walk hit a bound
  # with seniors still unvisited.
  def roots
    @roots ||= build_roots
  end

  def root_ids = roots.map(&:id)

  # The whole graph from `roots` down, each node carrying its depth relative to
  # the roots. Always includes the requested session.
  #
  # Breadth-first DISCOVERY is load-bearing now that this is a DAG: a session
  # reachable by two paths is rendered once, at the shallower of the two depths.
  # The ORDER is depth-first over that same set, so each node immediately
  # follows the one it hangs from — see #order_depth_first for why the two
  # cannot be the same thing.
  def nodes
    @nodes ||= build_nodes
  end

  # True when the walk stopped early — the reader is seeing part of a tree.
  # Forces the walk, since that is what decides the answer.
  def truncated?
    nodes
    @truncated
  end

  def truncation_reason
    return nil unless truncated?

    "Showing at most #{MAX_NODES} sessions, #{MAX_DEPTH} levels from the highest ancestor reached. This tree is larger."
  end

  # True when any session in the graph carries an uncle edge — what a renderer
  # asks before spending a legend on explaining them.
  def uncle_edges? = nodes.any?(&:uncles?)

  # Every session id in the tree. This is the scope the human-message record is
  # gathered over.
  def session_ids = nodes.map(&:id)

  def size = nodes.size

  # A single session tree is the common case; say so rather than drawing a
  # one-node diagram.
  def solitary? = nodes.size <= 1

  # Compact indented rendering, for the MCP tools that serve this graph.
  #
  # Titles are neutralized, not trusted. A session's title is writable by the
  # session itself (`action_session` → `update_title`), so an agent could
  # otherwise name itself something that opens a forged row here or a forged
  # human-message entry below it in what `get_session_provenance` returns —
  # manufacturing exactly the human authorization this whole feature exists to
  # make unforgeable.
  # An uncle edge is named rather than drawn: indentation can express one parent
  # and this graph has more than one, so a session's extra seniors are spelled
  # out on its line. Without that they would be silently invisible here while
  # visibly widening which human messages the record carries.
  #
  # A node the walk could only reach through an uncle is drawn under that uncle
  # and says so, since indentation alone would assert a spawn edge that does not
  # exist — the exact failure this outline was fixed for.
  def to_outline
    nodes.map do |node|
      marker = node.current? ? " ← this session" : ""
      root = SessionHumanMessages.sanitize_for_markdown_line(node.agent_root_label)
      label = SessionHumanMessages.sanitize_for_markdown_line(node.label)
      uncles = node.uncles? ? " (#{node.uncle_summary})" : ""
      via = node.spawn_edge? ? "" : " (shown under uncle ##{node.render_parent_id}, not its spawn parent)"
      "#{'  ' * node.depth}- ##{node.id} [#{root}] {#{node.genesis_summary}} #{label}#{uncles}#{via}#{marker}"
    end.join("\n")
  end

  # Juniors of a set of sessions: spawn children plus uncle-edge juniors,
  # resolving all three representations in three queries rather than one per
  # parent.
  def self.children_of(parent_ids)
    return [] if parent_ids.empty?

    by_column = Session.where(parent_session_id: parent_ids)
    by_metadata = Session.where(
      "custom_metadata->>'router_session_id' IN (?)", parent_ids.map(&:to_s)
    )
    by_uncle = Session.where(id: SessionUncleLink.where(uncle_session_id: parent_ids).select(:session_id))

    (by_column.to_a + by_metadata.to_a + by_uncle.to_a).uniq(&:id).sort_by(&:id)
  end

  # The id-only form, for callers asking a reachability question rather than
  # rendering anything (Sessions::RecordUncleEdge's acyclicity check). Same three
  # edge representations, no Session instantiation.
  def self.child_ids_of(parent_ids)
    return [] if parent_ids.empty?

    ids = Session.where(parent_session_id: parent_ids).pluck(:id)
    ids += Session.where("custom_metadata->>'router_session_id' IN (?)", parent_ids.map(&:to_s)).pluck(:id)
    ids += SessionUncleLink.where(uncle_session_id: parent_ids).pluck(:session_id)
    ids.uniq
  end

  # Seniors of a set of sessions: spawn parents plus uncles. The upward mirror of
  # children_of, and the reason `roots` can return more than one session.
  def self.parent_ids_of(child_ids)
    return [] if child_ids.empty?

    # Plucked rather than instantiated: this runs once per upward level on every
    # detail-page render, and building whole Session objects would drag up to
    # PROMPT_MAX_LENGTH of prompt text per row to read one integer off each.
    # Mirrors Session#lineage_parent_id — the column wins, the metadata key is
    # the fallback.
    spawn = Session.where(id: child_ids)
                   .pluck(:parent_session_id, Arel.sql("custom_metadata->>'router_session_id'"))
                   .filter_map { |column, derived| column || (derived.presence && Integer(derived, exception: false)) }
    uncles = SessionUncleLink.where(session_id: child_ids).pluck(:uncle_session_id)

    (spawn + uncles).uniq
  end

  private

  # Walk up over BOTH edge kinds, breadth-first, collecting every session that
  # has no seniors of its own. The spawn origin is computed separately (and
  # first) so it can lead the list and so its own truncation flag is preserved.
  #
  # Bounded the same two ways the downward walk is: MAX_DEPTH levels and
  # MAX_NODES sessions visited. Uncle edges mean "up" fans out rather than
  # forming a chain, so an unbounded upward walk is now as expensive as an
  # unbounded downward one.
  def build_roots
    spawn_origin = origin
    @upward_truncated = @origin_truncated

    seen = Set.new([ session.id ])
    ancestors = []
    frontier = [ session.id ]
    stalled = []
    depth = 0

    while frontier.any?
      senior_ids = self.class.parent_ids_of(frontier) - seen.to_a
      break if senior_ids.empty?

      depth += 1
      if depth > MAX_DEPTH || seen.size + senior_ids.size > MAX_NODES
        # Out of budget with seniors still above. Those sessions anchor the
        # render — dropping the branch would silently lose a whole hierarchy —
        # and the flag says the reader is seeing a subgraph.
        stalled = frontier
        @upward_truncated = true
        break
      end

      seen.merge(senior_ids)
      level = Session.where(id: senior_ids).to_a
      # A senior id that does not resolve is a DEAD POINTER, not a walk that ran
      # out of budget — `custom_metadata["router_session_id"]` is never cleaned
      # up when the router is deleted, unlike the column, which is nullified.
      # `topmost` and `origin` both treat a dangling id as "nothing above here",
      # so flagging truncation on it would make the same fact read as a complete
      # tree in two places and a partial one here.
      ancestors.concat(level)
      frontier = level.map(&:id)
    end

    anchors = topmost(ancestors + [ session ]) + Session.where(id: stalled).to_a

    # The spawn origin leads, so the ordinary single-parent case renders exactly
    # as it did before uncle edges existed. A session with no seniors at all is
    # its own origin and its own root.
    ([ spawn_origin ] + anchors.sort_by(&:id)).uniq(&:id)
  end

  # Of these sessions, the ones with no senior that still exists — a spawn
  # parent pointing at a deleted session is not a parent, it is a dead pointer,
  # and the session below it is the top of what remains.
  def topmost(records)
    ids = records.map(&:id)
    with_uncles = SessionUncleLink.where(session_id: ids).distinct.pluck(:session_id).to_set
    parent_ids = records.filter_map(&:lineage_parent_id).uniq
    live_parents = parent_ids.any? ? Session.where(id: parent_ids).pluck(:id).to_set : Set.new

    records.reject do |record|
      with_uncles.include?(record.id) || live_parents.include?(record.lineage_parent_id)
    end
  end

  def build_nodes
    seeds = roots
    # roots sets @upward_truncated; an incomplete upward walk means the graph we
    # are about to render is a subgraph, whatever the downward walk finds.
    @truncated = @upward_truncated

    # (record, depth) pairs rather than Nodes, so the uncle edges for the whole
    # graph can be fetched in one query at the end instead of one per node.
    collected = seeds.map { |root| [ root, 0 ] }
    seen = Set.new(seeds.map(&:id))
    # child id => the id of the session in the level above it was reached
    # through. Without this the walk knows a level's juniors only as a flat set
    # and the render has nothing to hang them from — see #order_depth_first.
    attached_to = {}
    @via_uncle = Set.new
    frontier = seeds
    depth = 0

    while frontier.any?
      # The depth check comes AFTER discovering the next level, so a tree that
      # happens to be exactly MAX_DEPTH deep is reported complete rather than
      # truncated — we only claim truncation when there is something we did not
      # show.
      next_frontier = self.class.children_of(frontier.map(&:id)).reject { |s| seen.include?(s.id) }
      break if next_frontier.empty?

      depth += 1
      if depth > MAX_DEPTH
        @truncated = true
        break
      end

      # Marked seen as the level is discovered, not as it is appended: in a DAG
      # a session can be a junior of two sessions in the same frontier, and
      # without this it would be collected twice at the same depth.
      #
      # `ceiling_hit` is local rather than the @truncated flag: @truncated may
      # already be true because the UPWARD walk was cut, and reusing it as the
      # loop's exit signal would end the downward walk after a single level —
      # silently shrinking the graph, and with it the scope human messages are
      # gathered over.
      admitted = []
      ceiling_hit = false
      next_frontier.each do |child|
        if collected.size >= MAX_NODES
          ceiling_hit = true
          @truncated = true
          break
        end

        seen << child.id
        collected << [ child, depth ]
        admitted << child
      end

      attached_to.merge!(attachments_for(admitted, frontier.map(&:id)))

      break if ceiling_hit

      frontier = admitted
    end

    ordered = order_depth_first(collected, seeds, attached_to)

    # The requested session must always be visible, even if the ceiling cut the
    # branch it lives on — a detail page that omits the session you are looking
    # at is worse than one that admits it is truncated.
    unless seen.include?(session.id)
      # Rendered one level below the last node we did collect rather than at the
      # root: claiming depth 0 would draw it as a sibling of the origin, which
      # is a worse lie than an approximate depth.
      ordered << [ session, (ordered.last&.last || 0) + 1 ]
      @truncated = true
    end

    uncles = uncle_ids_for(ordered.map { |record, _| record.id })
    ordered.map do |record, node_depth|
      node_for(record, depth: node_depth, uncle_ids: uncles[record.id] || [], render_parent_id: attached_to[record.id])
    end
  end

  # Which session in the level above each newly discovered session hangs from.
  #
  # `children_of` answers "who are the juniors of this whole level" as one flat
  # set, which is all the WALK needs — but every surface draws this graph with
  # indentation alone, so a level appended in id order silently reads as the
  # children of whichever session happened to sort last. That is issue #571: the
  # rows were right and the picture was wrong. Recording the session each junior
  # was actually reached through is what lets the render put it under that one.
  #
  # Spawn beats uncle when both are in the level above, because indentation is
  # documented as the spawn edge on all three surfaces; an uncle is only ever
  # drawn under when there is no spawn edge into this level to draw.
  def attachments_for(children, parent_ids)
    return {} if children.empty?

    above = parent_ids.to_set
    attachments = {}
    unresolved = []

    children.each do |child|
      spawn_parent = child.lineage_parent_candidate_ids.find { |id| above.include?(id) }
      if spawn_parent
        attachments[child.id] = spawn_parent
      else
        unresolved << child.id
      end
    end

    if unresolved.any?
      SessionUncleLink.where(session_id: unresolved, uncle_session_id: parent_ids)
                      .order(:uncle_session_id)
                      .pluck(:session_id, :uncle_session_id)
                      .each do |child_id, uncle_id|
        next if attachments.key?(child_id)

        attachments[child_id] = uncle_id
        @via_uncle << child_id
      end
    end

    attachments
  end

  # The collected graph reordered so that every session immediately follows the
  # one it hangs from, with its whole subtree ahead of the next sibling.
  #
  # Discovery has to stay breadth-first — that is what renders a session
  # reachable by two paths once, at its shallowest depth — but the OUTPUT of a
  # breadth-first walk is grouped by level, and a renderer that indents by depth
  # reads a level as belonging to the last node of the level above it. So the
  # set and every depth come from the breadth-first walk and only the order
  # changes here.
  #
  # Anything collected but unattached — the roots, and the requested session
  # when the ceiling cut its branch — is emitted after the tree rather than
  # dropped. This reorders the node set; it must never change it, since that set
  # is the scope the human-message record is gathered over.
  def order_depth_first(collected, seeds, attached_to)
    by_parent = Hash.new { |hash, key| hash[key] = [] }
    collected.each do |pair|
      parent_id = attached_to[pair.first.id]
      by_parent[parent_id] << pair if parent_id
    end

    seed_ids = seeds.map(&:id).to_set
    stack = collected.select { |record, _| seed_ids.include?(record.id) }.reverse
    ordered = []
    emitted = Set.new

    until stack.empty?
      pair = stack.pop
      record = pair.first
      next unless emitted.add?(record.id)

      ordered << pair
      stack.concat(by_parent[record.id].reverse)
    end

    ordered.concat(collected.reject { |record, _| emitted.include?(record.id) })
  end

  # Uncle edges for every session in the graph, in one query. Only edges whose
  # senior is itself in the graph are kept: naming a session the reader cannot
  # see, and whose messages are not in scope, would be a dangling reference.
  def uncle_ids_for(ids)
    return {} if ids.empty?

    SessionUncleLink.where(session_id: ids, uncle_session_id: ids)
                    .order(:uncle_session_id)
                    .pluck(:session_id, :uncle_session_id)
                    .group_by(&:first)
                    .transform_values { |pairs| pairs.map(&:last) }
  end

  def node_for(record, depth:, uncle_ids: [], render_parent_id: nil)
    Node.new(
      id: record.id,
      title: record.title,
      agent_root: record.agent_root_key,
      status: record.status,
      depth: depth,
      parent_id: record.lineage_parent_id,
      uncle_ids: uncle_ids,
      current: record.id == session.id,
      genesis: record.genesis_key,
      priority_class: record.priority_class(genesis_overrides),
      render_parent_id: render_parent_id,
      via_uncle: @via_uncle.include?(record.id)
    )
  end

  # Read the per-genesis overrides once per hierarchy rather than once per node —
  # a 150-node tree would otherwise hit AppSetting 150 times to answer the same
  # question.
  def genesis_overrides
    @genesis_overrides ||= AppSetting.current.genesis_class_overrides || {}
  end
end
