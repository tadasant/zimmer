# frozen_string_literal: true

module CycleTimes
  # A root session and everything it spawned, as one unit of work.
  #
  # Membership follows SPAWN edges only (`parent_session_id`), transitively.
  # Uncle edges (SessionUncleLink) are deliberately not followed: an uncle is a
  # senior session that sent this one a message, and it belongs to its own
  # hierarchy, which did its own task. Following them would merge two tasks
  # into one row and count the uncle's time twice. Status-summary forks are
  # Zimmer's own bookkeeping, not part of anyone's task, and are excluded.
  class Hierarchy
    # A hierarchy past this size is a runaway, not a task, and its rollup would
    # cost more than the row is worth. Recorded as ineligible (`too_large`).
    MAX_SESSIONS = 300

    # How far up a parent chain the root walk goes before it gives up — a guard
    # against a cycle no validation forbids.
    MAX_DEPTH = 50

    attr_reader :root, :sessions, :depths

    # The root of the hierarchy +session+ belongs to.
    def self.root_for(session)
      current = session
      seen = Set.new
      while current.parent_session_id && seen.size < MAX_DEPTH && seen.add?(current.id)
        parent = Session.find_by(id: current.parent_session_id)
        break if parent.nil?

        current = parent
      end
      current
    end

    def initialize(root)
      @root = root
      @sessions = [ root ]
      @depths = { root.id => 0 }
      collect
    end

    def ids = @sessions.map(&:id)
    def too_large? = @truncated
    def settled? = @sessions.all?(&:archived?)

    private

    def collect
      frontier = [ root.id ]
      depth = 0
      while frontier.any? && depth < MAX_DEPTH
        depth += 1
        children = Session.where(parent_session_id: frontier).where.not(id: @depths.keys).order(:created_at, :id).to_a
        children.reject!(&:status_summary_fork?)
        children.each { |child| @depths[child.id] = depth }
        @sessions.concat(children)
        if @sessions.size > MAX_SESSIONS
          @truncated = true
          break
        end
        frontier = children.map(&:id)
      end
    end
  end
end
