# frozen_string_literal: true

module Sessions
  # The single writer of uncle edges, and the place the rules live.
  #
  # Called when one session queues or interrupts another. The premise (from the
  # request this implements): a session that inspected another session and
  # decided to redirect it has meaningful additional information, and is
  # therefore senior — an additional parent, sibling to the spawn parent, hence
  # "uncle".
  #
  # ## Who is the actor
  #
  # There is no ambient caller identity to read. Zimmer's API key is shared by
  # the whole fleet — it establishes a caller, not a session — and the MCP
  # endpoint's scoping (`tool_groups`, `allowed_agent_roots`) is per-connection,
  # not per-session; the self-session server injected into every session is
  # byte-identical across all of them. So the acting session is SELF-DECLARED, by
  # an explicit `acting_session_id` on the request. That is a real limitation,
  # not a detail: see `docs/src/content/docs/limitations.md`. No declaration
  # means no edge, and a declaration that does not resolve to a session is
  # ignored rather than raised on — recording lineage must never be the reason a
  # follow-up fails to deliver.
  #
  # ## The rules
  #
  # Writing `uncle → junior` when session A acts on session B:
  #
  #   1. **Self** — A == B records nothing. A session messaging itself says
  #      nothing about lineage.
  #   2. **Already senior** — if A can already reach B going down (A is B's spawn
  #      ancestor, or an A → B uncle edge exists), record nothing. The graph
  #      already asserts what the edge would assert.
  #   3. **Inversion** — if A is currently B's junior, the seniority claim has
  #      reversed. What happens depends on which kind of edge made A the junior:
  #      * a direct **uncle edge B → A** is REPLACED by A → B. An uncle edge is a
  #        claim about who currently holds the better information, and the newer
  #        act of inspection supersedes the older one. Replacement, not addition:
  #        keeping both would assert a two-cycle, in which each session is senior
  #        to the other, which is not a fact about anything.
  #      * the **spawn edge** (B spawned A, directly or transitively) records
  #        nothing, and `parent_session_id` is never touched. B did spawn A; that
  #        is history, and a graph that rewrites it lies about something that
  #        actually happened. Nothing is lost by declining: A and B are already in
  #        one hierarchy, so the rendered tree and the human-message scope — the
  #        only two consumers of this graph — already show everything the inverted
  #        edge could add.
  #      * any other shape that would close a cycle (B is senior to A two or more
  #        hops away) is refused. Only the direct uncle edge inverts; unwinding a
  #        longer chain would mean deleting an edge neither session is party to.
  #   4. **Otherwise** — insert A → B.
  #
  # Rules 2 and 3 together are the acyclicity invariant: an edge A → B is written
  # only when B cannot already reach A, so no sequence of calls can construct a
  # cycle. `SessionHierarchy` still carries its own `seen` guards — a bound that
  # depends on every writer having been correct is not a bound — but they are a
  # backstop here rather than the primary defense.
  class RecordUncleEdge
    # How far to search for an existing seniority relationship before giving up
    # and refusing the edge. Matched to SessionHierarchy::MAX_DEPTH so the
    # reachability question this asks is the same one the renderer will answer.
    MAX_SEARCH_DEPTH = SessionHierarchy::MAX_DEPTH

    Outcome = Struct.new(:action, :link, keyword_init: true) do
      # An edge was created — either fresh, or replacing an inverted one.
      def recorded? = %i[created inverted].include?(action)
      def inverted? = action == :inverted
    end

    # @param junior [Session] the session being queued or interrupted
    # @param acting_session_id [Integer, String, nil] the self-declared caller
    # @param source [String] the entry point, recorded on the edge for reading
    def self.call(junior:, acting_session_id:, source:)
      new(junior: junior, acting_session_id: acting_session_id, source: source).call
    end

    def initialize(junior:, acting_session_id:, source:)
      @junior = junior
      @acting_session_id = acting_session_id
      @source = source
    end

    def call
      return skip(:no_actor_declared) if uncle.nil?
      return skip(:self) if uncle.id == junior.id
      return skip(:already_senior) if senior_already?

      inverted = SessionUncleLink.find_by(session_id: uncle.id, uncle_session_id: junior.id)
      return invert(inverted) if inverted
      return skip(:would_create_cycle) if junior_of_actor?

      create_edge
    rescue StandardError => e
      # Lineage is a record ABOUT the delivery, never a precondition of it. A
      # failure here — a racing duplicate, a session destroyed mid-call — must not
      # turn a successful interrupt into an error the caller sees.
      Rails.logger.warn "[Sessions::RecordUncleEdge] Could not record #{@acting_session_id.inspect} → #{junior.id}: #{e.class}: #{e.message}"
      skip(:error)
    end

    private

    attr_reader :junior, :source

    # The declared actor, or nil. A blank, unparseable, or unknown id is "no
    # actor" rather than an error — see the class comment.
    def uncle
      return @uncle if defined?(@uncle)

      id = Integer(@acting_session_id.to_s, exception: false)
      @uncle = id && Session.find_by(id: id)
    end

    # Can the actor already reach the junior going down? True when the actor is
    # the junior's spawn ancestor or already carries an uncle edge to it.
    def senior_already?
      reachable_downward?(from: uncle.id, target: junior.id)
    end

    # The mirror question: is the actor currently BELOW the junior? Answering it
    # after the direct-uncle-edge check means this only catches the spawn-edge and
    # multi-hop cases, both of which decline rather than invert.
    def junior_of_actor?
      reachable_downward?(from: junior.id, target: uncle.id)
    end

    # Breadth-first over BOTH edge kinds, from `from` toward `target`, bounded by
    # MAX_SEARCH_DEPTH. Cycle-safe via `seen` even though the invariant says there
    # are none — the guard is what makes that safe to assume.
    def reachable_downward?(from:, target:)
      seen = Set.new([ from ])
      frontier = [ from ]

      MAX_SEARCH_DEPTH.times do
        next_ids = SessionHierarchy.child_ids_of(frontier) - seen.to_a
        return false if next_ids.empty?
        return true if next_ids.include?(target)

        seen.merge(next_ids)
        frontier = next_ids
      end

      false
    end

    def invert(existing)
      link = nil
      ActiveRecord::Base.transaction do
        existing.destroy!
        link = SessionUncleLink.create!(session_id: junior.id, uncle_session_id: uncle.id, source: source)
      end

      log("Seniority inverted: ##{uncle.id} was junior to this session and has now queued or interrupted it, " \
          "so the uncle edge ##{junior.id} → ##{uncle.id} was replaced by ##{uncle.id} → ##{junior.id} (#{source})")
      Outcome.new(action: :inverted, link: link)
    end

    def create_edge
      link = SessionUncleLink.create!(session_id: junior.id, uncle_session_id: uncle.id, source: source)
      log("Uncle edge recorded: session ##{uncle.id} queued or interrupted this session and is now linked as a senior (#{source})")
      Outcome.new(action: :created, link: link)
    end

    # A lineage edge changes whose human messages this session's prompt carries,
    # so it is written into the session's own log where a reader can see it
    # happen rather than inferring it from the graph.
    def log(content)
      junior.logs.create!(content: content, level: "info")
    rescue StandardError => e
      Rails.logger.warn "[Sessions::RecordUncleEdge] Could not log edge for session #{junior.id}: #{e.message}"
    end

    def skip(reason)
      Outcome.new(action: reason, link: nil)
    end
  end
end
