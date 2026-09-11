# frozen_string_literal: true

module OutcomeAnalyses
  # Spawn the agent session that analyzes ONE archived transcript and saves the
  # result back through `save_outcome_analysis`.
  #
  # This is the only thing in Zimmer that starts an analysis, and it runs only
  # from an explicit request — a human's Analyze / Analyze All click, or an
  # `action_outcome_analysis` MCP call on a connection that opted into the
  # `outcome_analyses` tool group — never from a callback, a poller, or a state
  # transition. The analysis is expensive; nothing gets to trigger it implicitly.
  #
  # The spawned session is `spot`-classed. It is batch work nobody is waiting on,
  # so it yields to anything a human is watching when the Claude Code quota gets
  # tight — which is the difference between "Analyze All over 400 transcripts"
  # being a background sweep and being an outage.
  class SpawnAnalysisSession
    class Error < StandardError; end
    class AgentCapExceeded < Error; end

    # Metadata an analysis session carries when it was asked for over MCP rather
    # than from the web UI: that it was, and which session's connection asked.
    # The first is what the single-analysis agent cap counts.
    REQUESTED_VIA_KEY = "outcome_analysis_requested_via"
    REQUESTED_BY_KEY = "outcome_analysis_requested_by_session_id"

    def self.call(session:, batch: nil, requested_via: nil, requested_by: nil)
      new(session: session, batch: batch, requested_via: requested_via, requested_by: requested_by).call
    end

    # The live analysis session working on `target`, if there is one — the newest,
    # should a web-UI click and an MCP call ever have both started one.
    def self.in_flight_for(target)
      live_analysis_sessions
        .where("metadata->>? = ?", Session::OUTCOME_ANALYSIS_MARKER, target.id.to_s)
        .order(id: :desc)
        .first
    end

    # How many analyses requested one at a time over MCP are still in flight.
    # Batch items do not count: a batch has its own ceiling and its own Stop.
    def self.live_mcp_single_count
      live_analysis_sessions
        .where("metadata->>? = ?", REQUESTED_VIA_KEY, OutcomeAnalysisBatch::STARTED_VIA_MCP)
        .where("metadata->>'outcome_analysis_batch_id' IS NULL")
        .count
    end

    # Waiting, running, or parked in needs_input: anything that may yet save.
    def self.live_analysis_sessions
      Session.outcome_analysis_sessions.where(status: Session::NON_REAPABLE_STATUSES)
    end

    # @param batch [OutcomeAnalysisBatch, nil] the batch this item belongs to. A
    #   batch item takes its provenance from the batch, not from the arguments.
    # @param requested_via [String, nil] OutcomeAnalysisBatch::STARTED_VIA_*, for
    #   a single analysis. Nil means the web UI.
    # @param requested_by [Session, nil] the session whose MCP connection asked.
    def initialize(session:, batch: nil, requested_via: nil, requested_by: nil)
      @session = session
      @batch = batch
      @requested_via = batch ? batch.started_via : (requested_via || OutcomeAnalysisBatch::STARTED_VIA_WEB_UI)
      @requested_by = batch ? batch.started_by_session : requested_by
    end

    def call
      raise Error, "Session #{@session.id} is not archived" unless @session.archived?
      enforce_agent_limits! if via_mcp? && @batch.nil?

      # Created with the job held back so the title is on the row before the
      # agent starts: an Analyze All of 400 transcripts that all appear on the
      # dashboard as untitled for their first few seconds is a needless way to
      # make a batch unreadable.
      session = Session.create_from_agent_root!(
        agent_root_name: Config.agent_root,
        prompt: prompt,
        catalog_skills: skills,
        mcp_servers: [ Config.mcp_server_name ],
        goal: goal,
        skip_enqueue: true,
        genesis: genesis,
        scheduling_class: SessionGenesis::SPOT,
        metadata: {
          Session::OUTCOME_ANALYSIS_MARKER => @session.id.to_s,
          "outcome_analysis_batch_id" => @batch&.id&.to_s
        }.merge(provenance_metadata).compact
      )

      session.update!(title: title)
      AgentSessionJob.enqueue_new_session(session.id)
      session
    end

    private

    def via_mcp? = @requested_via == OutcomeAnalysisBatch::STARTED_VIA_MCP

    # Where the line of work came from, per SessionGenesis. A click in the web
    # app is `web_ui` — a human pressed a button, and the fact that a batch pump
    # made the actual call is a detail of how, not of where from. An MCP request
    # belongs to the line of work of the session that made it, the same way a
    # parented spawn inherits its parent's genesis; with no calling session to
    # inherit from it is `api`, like any other parentless API spawn.
    def genesis
      return SessionGenesis::WEB_UI unless via_mcp?

      @requested_by&.genesis.presence || SessionGenesis::API
    end

    def provenance_metadata
      return {} unless via_mcp?

      { REQUESTED_VIA_KEY => @requested_via, REQUESTED_BY_KEY => @requested_by&.id&.to_s }
    end

    # One analysis at a time is how the MCP tool is meant to be used for a
    # handful of transcripts; past AGENT_MAX_CONCURRENCY in flight, the caller
    # is building a batch by hand, and a hand-built batch has no Stop button.
    # A check rather than a lock: two calls in the same instant can both pass,
    # which costs one extra spot session, not a runaway.
    def enforce_agent_limits!
      in_flight = self.class.in_flight_for(@session)
      if in_flight
        raise AgentCapExceeded, "Session ##{@session.id} is already being analyzed by session ##{in_flight.id}. " \
                                "Its result replaces the current analysis when it saves; starting a second one would only race it."
      end

      cap = OutcomeAnalysisBatch::AGENT_MAX_CONCURRENCY
      return if self.class.live_mcp_single_count < cap

      raise AgentCapExceeded, "#{cap} analyses requested one at a time over MCP are already in flight, which is the most " \
                              "an agent may have. Wait for one to finish, or use the analyze_all action, which queues the " \
                              "rest as a batch that can be watched and stopped."
    end

    def title
      subject = @session.title.presence || "session ##{@session.id}"
      "Outcome analysis: #{subject}".truncate(120)
    end

    # The skill is authored in the AIR catalog, not here, and Session rejects a
    # skill id the catalog does not know. Rather than fail every Analyze click
    # while the catalog entry is in flight, spawn without it — the prompt below
    # carries the whole contract, so the session can still do the job, just
    # without the skill's guidance. The ledger shows a banner saying so.
    #
    # Returns nil rather than [] when the skill is missing: `create_from_agent_root!`
    # reads both as "take the root's defaults" (it tests `.presence`), so returning
    # [] would only look like a request for none while behaving as nil. Saying nil
    # outright is the honest spelling of what actually happens.
    def skills
      Config.skill_available? ? [ Config.skill_id ] : nil
    end

    def goal
      "Save exactly one outcome analysis for Zimmer session ##{@session.id} via the save_outcome_analysis MCP tool, then archive yourself."
    end

    def prompt
      <<~PROMPT
        Analyze the transcript of Zimmer session ##{@session.id} and save the result.

        **Target session:** ##{@session.id}#{@session.title.present? ? " — #{@session.title}" : ""}
        Read it with the `get_session` MCP tool (`include_transcript: true`). It is archived, so
        the transcript is complete and will not change under you.

        #{skill_line}

        ## What to produce

        Decompose the transcript into its tree of **Transcript Segments**. A Segment is one
        coherent unit of agent work, described by a `Trigger → Goal → Outcome` triplet, and
        Segments nest: the whole transcript is the root Segment, `S0`.

        Classify each Segment's Outcome as **Success** or **Failure** against ITS OWN Goal.
        Outcome is local: a Failure Segment under a Success parent is normal and is the most
        interesting thing this analysis produces. Do NOT propagate a failure up to its parent,
        and do not soften a failed Segment because the transcript later recovered.

        Ids are depth-first positional and deterministic: root is `S0`, its children are `S0.0`,
        `S0.1`, then `S0.1.0`, and so on. Zimmer validates them, so they are not yours to choose.

        `trigger.kind` is `New` or `Correction`; a `Correction` means the PRIOR SIBLING Segment
        failed to deliver its own Goal, so the first child of any parent is never a Correction.
        `trigger.source` is `user`, `agent`, or `subagent`. `goal.kind` is `Plan` (figuring
        something out) or `Action` (doing something / changing state).

        `outcome.explanation` is REQUIRED and non-empty on Success as well as Failure, and is
        capped at #{SegmentTree::EXPLANATION_MAX} characters — it renders as a hover tooltip in
        Zimmer's Outcomes view, so write one short clause, not a paragraph.

        Out of scope, deliberately: skill recommendations, MCP recommendations, efficiency
        analysis, and every other cross-transcript analyzer. Do not produce them.

        ## How to save it

        Call `save_outcome_analysis` exactly once:

        ```
        save_outcome_analysis({
          session_id:          #{@session.id},
          analyzer_session_id: <your own session id>,
          schema_version:      "1",
          root:                <the root Segment>,
          notes:               <one line, or null>
        })
        ```

        ```
        Segment {
          id:      string,
          trigger: { kind: "New" | "Correction", source: "user" | "agent" | "subagent" },
          goal:    { text: string, kind: "Plan" | "Action" },
          outcome: { kind: "Success" | "Failure", explanation: string },
          meta:    { event_range: [string, string] | null, wall_clock_s: number | null,
                     tokens_in: number | null, tokens_out: number | null, model: string | null },
          children: Segment[]
        }
        ```

        Zimmer validates the whole tree and rejects a malformed one with the reason. If the save
        is rejected, fix what it names and call the tool again.

        When the analysis is saved, archive yourself. Do not open a PR, do not edit any file in
        the clone, and do not park in needs_input — this is unattended batch work and there is
        nothing for a human to do with it.
      PROMPT
    end

    def skill_line
      if Config.skill_available?
        "Follow the `#{Config.skill_id}` skill for how to segment a transcript; the contract below is what Zimmer will accept."
      else
        "(The `#{Config.skill_id}` skill is not in this deployment's catalog yet, so work from the contract below directly.)"
      end
    end
  end
end
