# Builds a structured dependency graph of all non-archived sessions,
# capturing parent-child (invocation chain), blocking, and origin relationships.
#
# The graph is intended for the heartbeat agent to get a full picture of
# session topology in a single API call.
#
# Usage:
#   graph = SessionDependencyGraphService.call
#   graph[:nodes]  # Array of session nodes with origin_type
#   graph[:edges]  # Array of relationships between sessions
#   graph[:roots]  # Session IDs that are root nodes (no parent)
#   graph[:summary] # Counts by status and origin_type
class SessionDependencyGraphService
  # Origin types for sessions
  ORIGIN_USER = "user-triggered"
  ORIGIN_HEARTBEAT = "heartbeat-triggered"
  ORIGIN_ROUTER = "router-triggered"
  ORIGIN_AGENT = "agent-triggered"

  # Edge types for relationships
  EDGE_SPAWNED = "spawned"         # parent spawned child
  EDGE_BLOCKED_BY = "blocked_by"   # session is blocked by another

  def self.call(include_archived: false)
    new(include_archived: include_archived).call
  end

  def initialize(include_archived: false)
    @include_archived = include_archived
  end

  def call
    sessions = fetch_sessions
    nodes = build_nodes(sessions)
    edges = build_edges(sessions)
    roots = find_roots(nodes, edges)
    summary = build_summary(nodes)

    {
      nodes: nodes,
      edges: edges,
      roots: roots,
      summary: summary
    }
  end

  private

  def fetch_sessions
    scope = Session.all
    scope = scope.where.not(status: :archived) unless @include_archived
    scope.order(created_at: :asc).to_a
  end

  def build_nodes(sessions)
    sessions.map do |session|
      {
        id: session.id,
        slug: session.slug,
        title: session.title,
        status: session.status,
        is_autonomous: session.is_autonomous,
        origin_type: determine_origin_type(session),
        parent_session_id: determine_parent_session_id(session),
        spawned_by: session.custom_metadata&.dig("spawned_by"),
        created_at: session.created_at.iso8601,
        updated_at: session.updated_at.iso8601
      }
    end
  end

  def build_edges(sessions)
    edges = []
    session_ids = sessions.map(&:id).to_set

    sessions.each do |session|
      # Spawned-by relationship (child -> parent)
      parent_id = determine_parent_session_id(session)
      if parent_id && session_ids.include?(parent_id)
        edges << {
          type: EDGE_SPAWNED,
          from_id: parent_id,
          to_id: session.id,
          label: "spawned"
        }
      end

      # Blocking relationships from prompt/goal references
      blocked_by_ids = detect_blocking_references(session, session_ids)
      blocked_by_ids.each do |blocker_id|
        edges << {
          type: EDGE_BLOCKED_BY,
          from_id: session.id,
          to_id: blocker_id,
          label: "blocked by"
        }
      end
    end

    edges
  end

  def find_roots(nodes, edges)
    child_ids = edges.select { |e| e[:type] == EDGE_SPAWNED }.map { |e| e[:to_id] }.to_set
    nodes.reject { |n| child_ids.include?(n[:id]) }.map { |n| n[:id] }
  end

  def build_summary(nodes)
    {
      total: nodes.size,
      by_status: nodes.group_by { |n| n[:status] }.transform_values(&:size),
      by_origin_type: nodes.group_by { |n| n[:origin_type] }.transform_values(&:size)
    }
  end

  def determine_origin_type(session)
    spawned_by = session.custom_metadata&.dig("spawned_by")

    case spawned_by
    when "ao-heartbeat"
      ORIGIN_HEARTBEAT
    when "ao-router"
      ORIGIN_ROUTER
    when nil, ""
      ORIGIN_USER
    else
      ORIGIN_AGENT
    end
  end

  def determine_parent_session_id(session)
    session.parent_session_id
  end

  # Detect references to other session IDs in prompt or goal text.
  # Looks for patterns like "session #123", "session 123", "#123" preceded by "session".
  def detect_blocking_references(session, valid_session_ids)
    text = [ session.prompt, session.goal ].compact.join(" ")
    return [] if text.blank?

    # Match patterns like "session #123", "session 123", "blocked on #123", "waiting for session #123"
    referenced_ids = text.scan(/(?:session|blocked\s+on|waiting\s+for)\s*#?(\d+)/i)
                        .flatten
                        .map(&:to_i)
                        .select { |id| valid_session_ids.include?(id) }
                        .reject { |id| id == session.id }

    referenced_ids.uniq
  end
end
