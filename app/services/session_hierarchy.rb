# frozen_string_literal: true

# The whole family of sessions a given session belongs to: the origin session at
# the root, and every descendant beneath it — not just the chain of ancestors
# above the session you asked about.
#
# **This is spawn lineage, not message lineage.** An edge means "session A
# spawned session B". It does NOT mean "A most recently talked to B": a session
# routinely gets followed up by a router other than the one that spawned it, and
# reading an edge as "who talked to it last" would be wrong.
#
# Where the edge lives. Going forward it is the first-class `parent_session_id`
# column, which `start_session` (MCP and REST) can now set. Sessions spawned
# before that was wired recorded the same fact in `custom_metadata` as
# `router_session_id`, so the tree is DERIVED from both — the column first, that
# key as a fallback. Deriving rather than migrating is deliberate: it needs no
# backfill, it is reversible, and it never rewrites what a session recorded
# about itself. See Session#lineage_parent_id.
class SessionHierarchy
  # How far up from the requested session to look for the origin, and how deep
  # below it to render.
  #
  # Deep enough for the shapes that actually occur (router → worker → helper,
  # and a gate session spawned off a worker), shallow enough that a cycle or a
  # pathological chain cannot turn a page render into an unbounded walk.
  MAX_DEPTH = 8

  # Hard ceiling on nodes visited. A router that has spawned hundreds of
  # sessions would otherwise make its own detail page render the entire fleet.
  MAX_NODES = 150

  # One session in the tree, with everything a renderer needs and nothing more.
  Node = Struct.new(:id, :title, :agent_root, :status, :depth, :parent_id, :current, keyword_init: true) do
    def current? = current

    def label = title.presence || "Session ##{id}"

    # The agent root a reader identifies a session by, or an honest blank.
    def agent_root_label = agent_root.presence || "—"
  end

  attr_reader :session

  def initialize(session)
    @session = session
  end

  # The origin session: the highest ancestor reachable within MAX_DEPTH.
  # Returns the session itself when it has no recorded parent.
  def origin
    @origin ||= begin
      current = session
      seen = Set.new([ session.id ])

      MAX_DEPTH.times do
        parent_id = current.lineage_parent_id
        break if parent_id.blank? || seen.include?(parent_id)

        parent = Session.find_by(id: parent_id)
        break if parent.nil?

        seen << parent.id
        current = parent
      end

      current
    end
  end

  # Ancestors of the requested session, nearest first. Kept separate from the
  # full tree because "who spawned me" is a question on its own.
  def ancestors
    @ancestors ||= begin
      list = []
      current = session
      seen = Set.new([ session.id ])

      MAX_DEPTH.times do
        parent_id = current.lineage_parent_id
        break if parent_id.blank? || seen.include?(parent_id)

        parent = Session.find_by(id: parent_id)
        break if parent.nil?

        seen << parent.id
        list << parent
        current = parent
      end

      list
    end
  end

  # Direct descendants of the requested session, in creation order.
  def children
    @children ||= self.class.children_of([ session.id ])
  end

  # The whole tree from `origin` down, breadth-first, each node carrying its
  # depth relative to the origin. Always includes the requested session.
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

    "Showing the first #{MAX_NODES} sessions, #{MAX_DEPTH} levels deep. This tree is larger."
  end

  # Every session id in the tree. This is the scope the human-message record is
  # gathered over.
  def session_ids = nodes.map(&:id)

  def size = nodes.size

  # A single session tree is the common case; say so rather than drawing a
  # one-node diagram.
  def solitary? = nodes.size <= 1

  # Compact indented rendering for the agent's prompt and for MCP output.
  #
  # Titles are neutralized, not trusted. A session's title is writable by the
  # session itself (`action_session` → `update_title`), so an agent could
  # otherwise name itself something that closes this block and opens a forged
  # `<human-messages>` entry in a sibling's prompt — manufacturing exactly the
  # human authorization this whole feature exists to make unforgeable.
  def to_outline
    nodes.map do |node|
      marker = node.current? ? " ← this session" : ""
      root = SessionHumanMessages.sanitize_for_prompt(node.agent_root_label)
      label = SessionHumanMessages.sanitize_for_prompt(node.label)
      "#{'  ' * node.depth}- ##{node.id} [#{root}] #{label}#{marker}"
    end.join("\n")
  end

  # Children of a set of sessions, resolving BOTH edge representations in two
  # queries rather than one per parent.
  def self.children_of(parent_ids)
    return [] if parent_ids.empty?

    by_column = Session.where(parent_session_id: parent_ids)
    by_metadata = Session.where(
      "custom_metadata->>'router_session_id' IN (?)", parent_ids.map(&:to_s)
    )

    (by_column.to_a + by_metadata.to_a).uniq(&:id).sort_by(&:id)
  end

  private

  def build_nodes
    @truncated = false
    root = origin
    collected = [ node_for(root, depth: 0) ]
    seen = Set.new([ root.id ])
    frontier = [ root ]
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

      next_frontier.each do |child|
        if collected.size >= MAX_NODES
          @truncated = true
          break
        end

        seen << child.id
        collected << node_for(child, depth: depth)
      end

      break if @truncated

      frontier = next_frontier
    end

    # The requested session must always be visible, even if the ceiling cut the
    # branch it lives on — a detail page that omits the session you are looking
    # at is worse than one that admits it is truncated.
    unless seen.include?(session.id)
      collected << node_for(session, depth: 0)
      @truncated = true
    end

    collected
  end

  def node_for(record, depth:)
    Node.new(
      id: record.id,
      title: record.title,
      agent_root: record.agent_root_key,
      status: record.status,
      depth: depth,
      parent_id: record.lineage_parent_id,
      current: record.id == session.id
    )
  end
end
