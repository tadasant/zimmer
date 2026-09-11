# frozen_string_literal: true

module Sessions
  # The single remover of uncle edges, and the mirror of Sessions::RecordUncleEdge.
  #
  # An uncle edge is written as a *side effect* of a routine queue or interrupt,
  # from a self-declared `acting_session_id` nothing verifies (see
  # `docs/src/content/docs/limitations.md`). A typo'd or stale id therefore
  # attaches one session as another's senior on the strength of one wrong
  # character — and because the hierarchy is the scope human messages are
  # gathered over, that widens what context BOTH sessions carry from then on.
  # Until #299 the only way back was `SessionUncleLink.find_by(...).destroy` in a
  # console on the production box, which is precisely the shape of ops step the
  # deployment is supposed not to have.
  #
  # ## What it removes, and what it deliberately does not
  #
  # Exactly one edge: `uncle → junior`, the row
  # `(session_id: junior.id, uncle_session_id: uncle.id)`. Direction is the whole
  # content of an uncle edge, so removal is directional too.
  #
  # That matters because `RecordUncleEdge` can INVERT an edge: when the junior of
  # an existing edge turns round and queues its senior, `B → A` is deleted and
  # `A → B` written in its place. So for any pair of sessions the surviving edge
  # may point either way, and a remover that deleted "whichever edge joins these
  # two" would silently delete the opposite claim from the one the caller named.
  # A caller who names the wrong direction gets `NotFound` — with the direction
  # that DOES exist spelled out in the message, so the next call is the right
  # one rather than a guess.
  #
  # ## Removal is not a repair of the graph
  #
  # Nothing else changes. `parent_session_id` is untouched, no other edge is
  # rewritten, and no attempt is made to re-derive a hierarchy that "should" have
  # existed. Removing an edge can only ever narrow the graph — an acyclic graph
  # minus an edge is still acyclic — so none of `RecordUncleEdge`'s reachability
  # machinery has an analogue here.
  #
  # ## Why this raises where RecordUncleEdge swallows
  #
  # Recording is a note ABOUT a delivery, so a failure there must not fail the
  # delivery. Removal is the caller's whole request: a miss that returned quietly
  # would leave an operator believing an edge is gone while it still widens two
  # sessions' context. Every failure raises, and every surface renders it.
  class RemoveUncleEdge
    Error = Class.new(StandardError)

    # The edge the caller named does not exist. Distinct from Error so a surface
    # can answer 404 rather than 422 — "there is no such edge" and "you asked for
    # something malformed" are different answers to the operator.
    NotFound = Class.new(Error)

    Outcome = Struct.new(:junior_id, :uncle_id, :edge_source, :recorded_at, keyword_init: true)

    # @param junior [Session] the session the edge makes junior — the one whose
    #   hierarchy grew when the edge was written
    # @param uncle_session_id [Integer, String] id or slug of the senior to detach
    # @param actor [String] who is removing it, as a phrase for the timeline
    #   ("a human in the web UI", "session #12 via the MCP API"). Self-declared on
    #   the agent surfaces for the same reason the write path's actor is.
    # @param source [String] the entry point, for the log line
    # @raise [Error, NotFound]
    def self.call(junior:, uncle_session_id:, actor:, source:)
      new(junior: junior, uncle_session_id: uncle_session_id, actor: actor, source: source).call
    end

    def initialize(junior:, uncle_session_id:, actor:, source:)
      @junior = junior
      @uncle_session_id = uncle_session_id
      @actor = actor
      @source = source
    end

    def call
      raise Error, "uncle_session_id is required." if @uncle_session_id.to_s.strip.blank?

      uncle = Session.locate(@uncle_session_id)
      if uncle.nil?
        raise NotFound, "No session #{@uncle_session_id.to_s.strip.inspect}, so it cannot be " \
                        "an additional senior of session ##{junior.id}."
      end

      link = SessionUncleLink.find_by(session_id: junior.id, uncle_session_id: uncle.id)
      raise NotFound, missing_edge_message(uncle) if link.nil?

      outcome = Outcome.new(
        junior_id: junior.id,
        uncle_id: uncle.id,
        edge_source: link.source,
        recorded_at: link.created_at
      )

      # Destroyed rather than deleted: the model's `after_destroy_commit` is what
      # repaints the hierarchy panel for every session in the graph, at both ends.
      link.destroy!

      log_removal(uncle, outcome)
      outcome
    end

    private

    attr_reader :junior, :actor, :source

    # Naming the inverted edge is the point of this message. The pair is joined
    # either way round, so an operator who reads "no such edge" and stops has been
    # told the opposite of what is true about the pair.
    def missing_edge_message(uncle)
      base = "No uncle edge ##{uncle.id} → ##{junior.id}: session ##{uncle.id} is not recorded as an " \
             "additional senior of session ##{junior.id}."

      return base unless SessionUncleLink.exists?(session_id: uncle.id, uncle_session_id: junior.id)

      "#{base} The edge between them points the other way — ##{junior.id} is senior to ##{uncle.id}. " \
        "Remove that one by naming ##{uncle.id} as the session and ##{junior.id} as the uncle."
    end

    # Written into BOTH sessions' logs, naming both ids, for the same reason the
    # write path is: an edge changes whose human messages each session's prompt
    # carries, so each end owes its own reader a record of the change. The one
    # line is phrased without "this session" because both ends read it.
    #
    # A failure to log must not undo a removal that has already happened — the
    # edge is gone, and raising here would report otherwise.
    def log_removal(uncle, outcome)
      recorded = outcome.recorded_at ? outcome.recorded_at.utc.iso8601 : "an unknown time"
      content = "Uncle edge removed: ##{uncle.id} is no longer linked as an additional senior of " \
                "##{junior.id}. The edge ##{uncle.id} → ##{junior.id} was recorded at #{recorded} " \
                "by #{outcome.edge_source.presence || 'an unrecorded entry point'} and detached by " \
                "#{actor} (#{source})."

      [ junior, uncle ].each do |session|
        session.logs.create!(content: content, level: "info")
      rescue StandardError => e
        Rails.logger.warn "[Sessions::RemoveUncleEdge] Could not log removal for session #{session.id}: #{e.message}"
      end
    end
  end
end
