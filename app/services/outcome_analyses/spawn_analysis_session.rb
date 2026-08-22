# frozen_string_literal: true

module OutcomeAnalyses
  # Spawn the agent session that analyzes ONE archived transcript and saves the
  # result back through `save_outcome_analysis`.
  #
  # This is the only thing in Zimmer that starts an analysis, and it runs only
  # from an explicit human click (Analyze / Analyze All) — never from a callback,
  # a poller, or a state transition. The analysis is expensive; nothing gets to
  # trigger it implicitly.
  #
  # The spawned session is `spot`-classed. It is batch work nobody is waiting on,
  # so it yields to anything a human is watching when the Claude Code quota gets
  # tight — which is the difference between "Analyze All over 400 transcripts"
  # being a background sweep and being an outage.
  class SpawnAnalysisSession
    class Error < StandardError; end

    def self.call(session:, batch: nil)
      new(session: session, batch: batch).call
    end

    def initialize(session:, batch: nil)
      @session = session
      @batch = batch
    end

    def call
      raise Error, "Session #{@session.id} is not archived" unless @session.archived?

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
        # A human clicked a button in the Zimmer web app; the fact that a batch
        # pump made the actual call is a detail of how, not of where from.
        genesis: SessionGenesis::WEB_UI,
        scheduling_class: SessionGenesis::SPOT,
        metadata: {
          Session::OUTCOME_ANALYSIS_MARKER => @session.id.to_s,
          "outcome_analysis_batch_id" => @batch&.id&.to_s
        }.compact
      )

      session.update!(title: title)
      AgentSessionJob.enqueue_new_session(session.id)
      session
    end

    private

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
