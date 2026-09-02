# frozen_string_literal: true

module Mcp
  module Tools
    # The gate's append: one cleared issue onto the work backlog.
    #
    # THIS TOOL IS IN ITS OWN OPT-IN GROUP, AND THAT IS DELIBERATE. `work_backlog`
    # is separate from `sessions` and outside BASE_GROUPS, for the reason
    # `gate_decisions` is: the queue is read by a job that spawns sessions from
    # it with no human in the loop, so it is a high-value target, and a queue
    # every session has a pen for is not one. A connection has to name
    # `work_backlog` to get this; `work_backlog_readonly` gets the read and not
    # this. A scoping boundary rather than an authorization one — see
    # Mcp::Registry for what that does and does not buy.
    #
    # THREE THINGS THIS TOOL WILL NOT LET A CALLER DO.
    #
    # It will not let a caller name its own author: `writing_session_id` is taken
    # from the MCP connection, never from an argument, and `added_by` is derived
    # from that session's agent root.
    #
    # It will not mint an issueless item. `issue_url` is required. An item with no
    # issue is spawned straight from its `prompt` with no issue to re-check and no
    # gate verdict behind it, which is exactly the shape ungated work would take
    # to reach the fleet — so only a human (through the REST surface) or the
    # one-time migration may create one. `prompt` is refused here outright.
    #
    # And it will not place the item by hand. There is no `precedence` and no
    # `pinned` argument: the band rules decide, and pinning is a human's.
    class AppendWorkBacklogItem < Tool
      tool_name "append_work_backlog_item"

      # Arguments this tool refuses even though the row has a home for them.
      REFUSED_ARGS = %w[prompt precedence pinned added_by added_via writing_session_id status].freeze

      description <<~DESC
        Append one issue the issue work gate has just cleared to the **work backlog** — the ranked queue the 04:00 groomer starts work from. Call this on the auto-proceed path instead of editing `WORK_BACKLOG.json` and opening a PR.

        **Idempotent on `key`.** If a *queued* item with this key already exists, nothing is written and that item comes back with `result: "already_queued"` and its current `position` — a second gate session on the same issue must not double-queue it. A key that only exists as history (started or removed earlier) does not block: the issue was cleared again and it queues again.

        **Placement is the server's.** The item lands in the band its `estimated_cost` implies — small #{WorkBacklog::Ranking.describe_band("small")}, medium #{WorkBacklog::Ranking.describe_band("medium")}, large #{WorkBacklog::Ranking.describe_band("large")} — #{WorkBacklog::Ranking::GAP} below the lowest unpinned peer of the same cost (first-in, first-out within a band; the cheapest work floats). A band at its floor is re-spaced first (`band_respaced: true`). There is no `precedence` or `pinned` argument: pinning and hand-placing are a human's and have no agent path. Do not invent a second size estimate — pass the cost you rated.

        **Never an item the gate did not clear**, and **never an item with no issue**: `issue_url` is required and `prompt` is refused. An idea with no issue behind it belongs in a GitHub issue, where it gets rated. A production incident that is currently firing does not go here either — that still spawns a `priority` session immediately.

        **Who appended is stamped, not stated.** `writing_session_id` and `added_by` come from this MCP connection's session and its agent root. There is no parameter for either.

        **Keep the item thin.** The issue is the durable record: the verdict, the reasoning and the spec live there. `ratings` (your five axes, verbatim), `gate_verdict`, `gate_session`, `decided_at` and a one-line `notes` are what belongs here. Any other key you pass is kept in `payload` for later.

        **Returns** JSON: `result` ("appended" / "already_queued"), the item's `position` (1-based, whole queue), its `precedence`, `band_respaced`, and the item.
      DESC

      input_schema({
        type: "object",
        properties: {
          key: { type: "string", description: 'The item\'s identity: "<repo-short>#<issue>", e.g. "zimmer#498".' },
          issue_url: { type: "string", description: "The GitHub issue URL. Required — the backlog holds no issueless items from agents." },
          repo: { type: "string", description: '"owner/name" — what a session gets checked out for, e.g. "tadasant/zimmer".' },
          surface: { type: "string", description: 'The gate surface you rated on: "zimmer", "strad", "motet", "tadasant-internal", "strad-production", "artifacts", … Use the ledger\'s spelling.' },
          title: { type: "string", description: "The issue title." },
          kind: { type: "string", description: 'Your Step 6 kind: "bug", "tech-debt", "docs", "dep-bump", …' },
          scope_direction: { type: "string", enum: WorkBacklogItem::SCOPE_DIRECTIONS },
          estimated_cost: { type: "string", enum: WorkBacklogItem::COSTS, description: "THE ranking input, from your rating. small / medium / large." },
          ratings: {
            type: "object",
            description: "Your five axes, verbatim: requirement_complexity, requirement_impact, solution_complexity, implementation_risk, estimated_cost."
          },
          gate_verdict: { type: "string", description: 'Your verdict, e.g. "auto-proceed".' },
          gate_session: { type: "string", description: "The Zimmer session URL of the gate session that rated it." },
          decided_at: { type: "string", description: "ISO date the gate rated it, e.g. \"2026-08-29\". Defaults to today if omitted." },
          notes: { type: "string", description: "One line, optional. Not a copy of the issue." }
        },
        required: %w[key issue_url repo surface title kind scope_direction estimated_cost]
      })

      def call(args)
        refused = args.keys & REFUSED_ARGS
        if refused.any?
          raise ToolError, "#{refused.join(', ')} cannot be set from this tool: placement is the server's, " \
                           "authorship is stamped from the connection, and an issueless item may only come from a human."
        end
        raise ToolError, "issue_url is required: the backlog holds no issueless items from agents" if args["issue_url"].blank?

        attributes = args.merge("decided_at" => args["decided_at"].presence || Date.current.iso8601)
        result = WorkBacklog::Append.call(
          attributes,
          added_via: WorkBacklogItem::MCP,
          # Server-side, from the connection. There is deliberately no argument
          # that could set this.
          writing_session: connection_session
        )

        {
          result: result.created? ? "appended" : "already_queued",
          position: result.position,
          precedence: result.item.precedence,
          band_respaced: result.respaced,
          queued_total: WorkBacklogItem.queued.count,
          item: result.item.as_api_json
        }
      rescue WorkBacklog::Append::InvalidItem => e
        raise ToolError, "The item was rejected and nothing was written: #{e.message}"
      end

      private

      # The session this MCP connection was written for, or nil — a human driving
      # this tool from an MCP client is not a session, and that is fine.
      def connection_session
        return nil unless context.self_session_id

        Session.find_by(id: context.self_session_id)
      end
    end
  end
end
