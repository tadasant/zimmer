# frozen_string_literal: true

module Mcp
  module Tools
    # The write half of the User view: "this is the order, top to bottom."
    #
    # Reordering the board one session at a time through `action_session` →
    # `change_precedence` does not work, and not only because it is a call per row.
    # An absolute rank computed against a board that has moved since it was read
    # lands in the wrong place, and a partially-applied sequence of them leaves the
    # board in an order nobody chose. This takes the whole ordering as one
    # argument and writes it in one transaction, so the board is either the order
    # the caller named or the order it already had.
    class ReorderUserView < Tool
      tool_name "reorder_user_view"

      description <<~DESC
        Rewrite the order of the Zimmer dashboard's **User view** — the human's decision board — in one call.

        Pass `session_ids` as the order you want, **top first**. Every listed session is given a precedence spaced #{Sessions::ApplyUserViewOrder::GAP} apart, descending from the top, so the board reads in exactly that sequence and there is room to drag a row between any two afterwards.

        **Precedence is a real scheduling signal, not a display preference.** It is the order Zimmer starts `spot` sessions in when quota room appears, so putting something at the top of this board also means it gets worked sooner. That is intended: the board and the queue are the same ranking.

        **What this does NOT change:** a session's scheduling class. The board draws every `priority` session above every `spot` one, so a spot session cannot be ranked above a priority one by precedence alone — if something genuinely belongs at the very top of the human's attention, promote it with `action_session` → `change_scheduling_class` as well. Rank within each class is entirely yours.

        **Read the board with `get_user_view` first.** Ordering ids you have not read is how a ranking ends up wrong.

        **Partial orders are fine.** Sessions you do not list are left alone, below the listed ones. That is what makes this usable on a large board: rank the rows the decision actually turns on and leave the tail.

        Up to #{Sessions::ApplyUserViewOrder::MAX_IDS} ids per call.
      DESC

      input_schema({
        type: "object",
        properties: {
          session_ids: {
            type: "array",
            items: { type: "number" },
            minItems: 1,
            maxItems: Sessions::ApplyUserViewOrder::MAX_IDS,
            description: "Session ids in the order they should appear on the board, TOP FIRST. Duplicates are rejected; an id that names no session is rejected, naming the id, and nothing is written."
          },
          reason: {
            type: "string",
            maxLength: 500,
            description: "One line on why this is the order. Written to each reordered session's log, so the human can see what moved their board and why."
          }
        },
        required: [ "session_ids" ]
      })

      def call(args)
        ids = require_arg(args, "session_ids")
        raise ToolError, 'The "session_ids" parameter must be an array of session ids.' unless ids.is_a?(Array)

        result = Sessions::ApplyUserViewOrder.call(
          session_ids: ids.map { |id| id.to_i },
          reason: args["reason"].to_s.strip.presence,
          actor: "an agent via the reorder_user_view MCP tool"
        )

        lines = [
          "## Board reordered",
          "",
          "#{result.ordered.size} session(s) placed, top first. #{result.changed_count} row(s) actually moved.",
          ""
        ]
        result.ordered.each_with_index do |(id, precedence), index|
          lines << "#{index + 1}. Session #{id} → precedence #{precedence}"
        end
        lines << ""
        lines << "*Sessions not listed keep their own rank, below these. The human can still drag any row to override this.*"
        lines.join("\n")
      rescue Sessions::ApplyUserViewOrder::Error => e
        raise ToolError, e.message
      end
    end
  end
end
