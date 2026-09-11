# frozen_string_literal: true

module Mcp
  module Tools
    # The get_costs a session gets pointed at *itself* (the self_session tool
    # group). Same tool name and the same report body as GetCosts — only the
    # session-scoped form is reachable, so a session can ask what it cost without
    # being handed the whole deployment's bill.
    #
    # GetCosts stays out of `self_session` deliberately: it is a fleet report, and
    # a session has no business reading the fleet's spend from inside the fleet.
    # That is a reason to narrow the tool, not to withhold the question — "what
    # did I cost?" is the session's own business, and it is the input the
    # cost-versus-performance work these tables exist for will want from the
    # session side.
    class SelfSessionGetCosts < GetCosts
      tool_name "get_costs"

      description <<~DESC
        Read what THIS session has spent: its token volumes, priced at current list rates.

        This is the self-scoped view of Zimmer's token-spend ledger. It answers "what did I cost?"
        and nothing wider — there is no fleet total here, and no way to ask about another agent root
        or another session. The fleet-wide report is `get_costs` on the `health` tool group, which is
        a different connection.

        Every API call this session made is stored with its token volumes; dollars are computed on
        read at current list prices, so the same rows re-price themselves when rates change. Returns
        for the requested window:
        - cost, tokens, and API calls for this session
        - the main-thread vs subagent split — the cost side of "should that have been delegated"
        - the token breakdown: fresh input, output, cache read, cache write at each TTL. Usually the
          most informative view, because cache writes bill at up to 2x base input and routinely
          dominate a bill that looks like it should be about output
        - spend by **context-management feature** — the injected goal block, the session hierarchy,
          MCP responses, skill bodies, thinking, tool output — with the share it could not account
          for stated as its own line

        **The feature figures are ESTIMATES, and must be quoted as such.** The API reports one usage
        total per request with no per-feature decomposition, so the split is derived from transcript
        content: characters measured per feature, converted at a fixed ratio, and scaled so the parts
        can never exceed a request's real totals. Whatever is left over is reported as unattributed
        rather than spread across the features — most of it is the harness system prompt and the tool
        schemas, which never appear in a transcript. Do not present an estimated feature cost as a
        measurement.

        **Use cases:**
        - Report what a piece of work cost alongside what it produced
        - Notice that a session's spend is dominated by context re-sent every turn rather than by work
        - Decide whether to delegate the next step, with the subagent split in front of you

        **A caveat worth passing on:** list price is not a bill. Claude Code and Codex spend is
        subscription-billed, so treat those dollars as a comparable unit across models rather than
        money owed; Codex models carry no rate yet and price at zero. Pi spend is metered by
        OpenRouter and IS money owed.

        Spend is swept out of transcripts by a job that runs every ten minutes, so the most recent
        few minutes of a running session are usually not in the ledger yet. A session that has just
        started may legitimately report nothing at all.
      DESC

      input_schema({
        type: "object",
        properties: {
          days: {
            type: "integer",
            description: "Window size in days, counting back from now. Default 7, max 365. " \
                         "Ignored when `from` or `to` is given. A session that ran inside the " \
                         "default window needs none of these.",
            minimum: 1,
            maximum: MAX_DAYS
          },
          from: {
            type: "string",
            description: "Start of an explicit calendar window, as YYYY-MM-DD. Inclusive, from the " \
                         "start of that day in the deployment's time zone. Pairs with `to`; either " \
                         "may be given alone. Spans longer than 365 days are clamped to the most " \
                         "recent 365."
          },
          to: {
            type: "string",
            description: "End of an explicit calendar window, as YYYY-MM-DD. Inclusive, through the " \
                         "END of that day. Defaults to today when only `from` is given."
          },
          session_id: {
            oneOf: [ { type: "string" }, { type: "number" } ],
            description: "Optional: your own session ID. This connection already names the calling " \
                         "session, so leave it out — it is here only for a connection that names no " \
                         "session at all. Any other session's id is refused."
          }
        },
        required: []
      })

      # Always the session-scoped report, never the fleet or agent-root one.
      #
      # The narrowed schema does not advertise `agent_root`, and that is a
      # description rather than an enforcement: no schema here sets
      # `additionalProperties: false`, so a caller can pass the argument anyway.
      # The refusal below is what makes the narrowing real — the same reason
      # SelfSessionActionSession strips `halt` in its own body.
      def call(args)
        refuse_agent_root!(args["agent_root"]) if args["agent_root"].present?

        session = requester_session(args)
        enforce_self_scope!(session)

        window = CostWindow.from_params(days: args["days"], from: args["from"], to: args["to"])
        session_report(session.id, window.analytics, window)
      end

      private

      def refuse_agent_root!(root)
        raise ToolError, "This `get_costs` is scoped to the session making the call and cannot report on " \
                         "agent root `#{root}` — or on the fleet. Spend across an agent root is the " \
                         "deployment's posture rather than one session's business, and it is read through " \
                         "the fleet-wide `get_costs` on the `health` tool group, or the Costs page at " \
                         "#{costs_url}. Drop `agent_root` to get your own session's spend."
      end

      # The connection knows which session it was written for, so an explicit
      # `session_id` naming a different one is a session reading another
      # session's bill through the server injected into it. Refused where the
      # identity is known; a connection that carries none (a human client on
      # `?tool_groups=self_session`) has to name a session and is unchanged.
      def enforce_self_scope!(session)
        return if context.self_session_id.blank?
        return if context.self_session_id == session.id

        raise ToolError, "This `get_costs` reports the spend of the session making the call, and this MCP " \
                         "connection belongs to session ##{context.self_session_id} — it cannot report " \
                         "session ##{session.id}'s spend. Pass \"session_id\": #{context.self_session_id}, " \
                         "your own, or leave it out. Another session's spend is readable through the " \
                         "fleet-wide `get_costs` on the `health` tool group."
      end

      def costs_url = "#{context.base_url.to_s.chomp("/")}/costs"
    end
  end
end
