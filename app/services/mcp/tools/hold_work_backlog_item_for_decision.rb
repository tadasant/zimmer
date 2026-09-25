# frozen_string_literal: true

module Mcp
  module Tools
    # The triager's third outcome for a stranded row: "what remains is a human's
    # decision". Records it on the row so the row stops paging while the decision
    # is owed — see WorkBacklogItem::HOLD_DURATION for why that is safe, and
    # WorkBacklog::Hold for what it refuses.
    #
    # In the `work_backlog` group, beside append and pull, and for the same reason
    # they are there: it changes what the fleet is told about the queue. It is
    # NOT a removal and has none of the human-only levers' reach — it moves no row,
    # changes no status, and lapses on its own — which is why an agent may hold it.
    #
    # `held_by` is stamped from the connection, never taken from an argument, the
    # way `append_work_backlog_item` stamps `added_by`.
    class HoldWorkBacklogItemForDecision < Tool
      tool_name "hold_work_backlog_item_for_decision"

      description <<~DESC
        Record that a **stranded** work backlog row is waiting on a **human decision**, so it stops paging while that decision is owed. Use this when you have triaged a stranded row and the right outcome is neither "put it back" (`append_work_backlog_item`) nor "it is finished" (a human closes the issue), but "a person has to choose" — pick between overlapping issues, seed a secret, rule on a declined PR.

        **What it does.** The row moves from `status: "stranded"` to `status: "awaiting_decision"` in `get_work_backlog`, and out of the population whose age pages `#alerts` (`WorkBacklogLivenessSweepJob`). It is listed under "Awaiting your decision" on the Issues page with your `reason`. It does NOT change the row's `status`, remove it, or re-queue it.

        **It lapses after #{WorkBacklogItem::HOLD_DURATION.inspect}.** The row is then stranded again with its original age, and the next sweep pages on the lapse — that page is the reminder that the decision is still owed. A hold cannot be extended while it is active, and cannot be renewed until its lapse has paged. After that you may hold the row again, but read it first: the question is whether the decision is still the one owed.

        **It is void the moment the evidence changes.** The hold records the row's `liveness_state`; if a later sweep reads a different one (the issue closed, a PR opened, moved, stalled or merged), the hold is cleared and the row is triaged afresh. A failed GitHub read (`unknown`) does not void it.

        **Refused** for a row that is not stranded (queued, in flight, parked, or resolved), for a row the sweep has not read yet (no `liveness_state`, or `unknown`), for a row a newer row has superseded, for a row already held, and for a row whose lapsed hold has not paged yet.

        **`reason` is required** and is what a human reads: name the decision owed and who owes it, and link the issue comment that lays it out, e.g. "Tadas to pick one of #79/#141/#217 — see https://github.com/…#issuecomment-…".

        Identify the row by `id` (from `get_work_backlog`), or by `key` when exactly one unresolved row carries it.

        **Returns** JSON: the held `item` (with `held_until`) and `counts` of `stranded` and `awaiting_decision` after the write.
      DESC

      input_schema({
        type: "object",
        properties: {
          id: { type: "integer", description: "The row id, from get_work_backlog. Preferred." },
          key: { type: "string", description: 'The item key, e.g. "zimmer#79". Used only when `id` is absent; must match exactly one unresolved row.' },
          reason: { type: "string", description: "The decision owed, who owes it, and a link to where it is laid out. Required; at most #{WorkBacklogItem::HOLD_REASON_MAX} characters." }
        },
        required: %w[reason]
      })

      def call(args)
        session = connection_session
        item = WorkBacklog::Hold.call(
          item: find_item(args),
          reason: args["reason"],
          by: session&.metadata&.dig("agent_root_key").presence || WorkBacklogItem::MCP,
          session: session
        )

        {
          result: "held",
          item: item.as_api_json,
          counts: {
            stranded: WorkBacklogItem.stranded.count,
            awaiting_decision: WorkBacklogItem.awaiting_decision.count
          }
        }
      rescue WorkBacklog::Hold::Refused => e
        raise ToolError, "Nothing was written: #{e.message}"
      end

      private

      def find_item(args)
        if args["id"].present?
          return WorkBacklogItem.find_by(id: args["id"]) || raise(ToolError, "No work backlog row has id #{args['id']}")
        end

        key = args["key"].to_s.strip
        raise ToolError, "Pass the row's id (preferred) or its key" if key.empty?

        rows = WorkBacklogItem.unresolved.where(key: key).to_a
        raise ToolError, "No unresolved row carries key #{key.inspect}; check get_work_backlog status: \"stranded\"" if rows.empty?
        raise ToolError, "#{rows.size} unresolved rows carry key #{key.inspect} (ids #{rows.map(&:id).join(', ')}); pass `id`" if rows.size > 1

        rows.first
      end

      # The session this MCP connection was written for, or nil.
      def connection_session
        return nil unless context.self_session_id

        Session.find_by(id: context.self_session_id)
      end
    end
  end
end
