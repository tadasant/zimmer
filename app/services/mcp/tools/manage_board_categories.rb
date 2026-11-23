# frozen_string_literal: true

module Mcp
  module Tools
    # Your board's categories over MCP: everything the board lets a person do
    # to a category, and the drag that puts a session in one.
    #
    # Manual by construction. This tool moves a session into a category only
    # because the caller named both; there is no "suggest" or "auto" action, and
    # nothing in Zimmer calls it on its own. An agent uses it because a person
    # asked ("put the infra sessions in Infra"), the same way the person would
    # have dragged them.
    class ManageBoardCategories < Tool
      tool_name "manage_board_categories"

      ACTIONS = %w[list create rename delete reorder set_collapsed set_visibility assign].freeze

      description <<~DESC
        Manage the categories on the Zimmer dashboard's **Your board** (`/?view=board_v2`) — flat groups the human makes and drags sessions into by hand. Inside each category the board shows the most recently touched session first.

        **Actions** (`action`):
        - `list` — every category in board order, with its id, collapsed state, visibility and how many unarchived sessions it holds.
        - `create` — `name`. Added at the bottom.
        - `rename` — `category_id`, `name`.
        - `delete` — `category_id`. Its sessions move to Uncategorized; no session is touched otherwise.
        - `reorder` — `category_ids`, top first. Categories you leave out keep their order, below the listed ones.
        - `set_collapsed` — `category_id`, `collapsed` (boolean). Collapsed shows the header only.
        - `set_visibility` — `category_id`, `visibility`: `snoozed` (with `snoozed_until` as a naive local datetime like "2026-09-05T09:00:00" plus an IANA `timezone`), `backlogged`, or `visible` to put it back. The category and every session in it leave Your board until then. **Presentation only:** no session's own visibility, status or scheduling changes, and the original Your board is unaffected.
        - `assign` — `session_id` and `category_id` (omit or null for Uncategorized). Only when a human asked for it: categories are deliberately manual, so never sort sessions into categories on your own initiative.
      DESC

      input_schema({
        type: "object",
        properties: {
          action: { type: "string", enum: ACTIONS, description: "What to do. See the tool description." },
          category_id: { type: [ "number", "null" ], description: "The category. For `assign`, null or omitted means Uncategorized." },
          category_ids: { type: "array", items: { type: "number" }, description: "For `reorder`: category ids, top first." },
          name: { type: "string", maxLength: BoardCategory::NAME_MAX_LENGTH, description: "For `create` and `rename`." },
          collapsed: { type: "boolean", description: "For `set_collapsed`." },
          visibility: { type: "string", enum: BoardCategory::VISIBILITIES, description: "For `set_visibility`." },
          snoozed_until: { type: "string", description: "For `set_visibility` with `snoozed`: naive local datetime, e.g. \"2026-09-05T09:00:00\"." },
          timezone: { type: "string", description: "IANA zone `snoozed_until` is expressed in. Defaults to UTC." },
          session_id: { type: [ "number", "string" ], description: "For `assign`: the session id." }
        },
        required: [ "action" ]
      })

      def call(args)
        action = require_arg(args, "action").to_s
        raise ToolError, "Unknown action \"#{action}\". Valid: #{ACTIONS.join(', ')}." unless ACTIONS.include?(action)

        send("do_#{action}", args)
      rescue ActiveRecord::RecordInvalid => e
        raise ToolError, e.record.errors.full_messages.to_sentence
      rescue BoardCategories::Reorder::Error, BoardCategories::Assign::Error, Sessions::SetVisibility::Error => e
        raise ToolError, e.message
      end

      private

      def do_list(_args)
        categories = BoardCategory.ordered.to_a
        return "No board categories yet. Every session is in Uncategorized." if categories.empty?

        # The sessions the tab can show: trashed sessions keep their category,
        # and status-summary forks are never on a board.
        counts = Session.excluding_status_summary_forks.where.not(status: :archived)
          .where(board_category_id: categories.map(&:id)).group(:board_category_id).count
        lines = [ "## Your board categories (top first)", "" ]
        categories.each_with_index do |category, index|
          state = [ ("collapsed" if category.collapsed), category.visibility_summary ].compact
          lines << "#{index + 1}. **#{category.name}** (id #{category.id}) — #{counts.fetch(category.id, 0)} unarchived session(s)" \
                   "#{state.any? ? " · #{state.join(' · ')}" : ''}"
        end
        lines.join("\n")
      end

      def do_create(args)
        category = BoardCategory.create!(name: require_arg(args, "name"))
        "Created category **#{category.name}** (id #{category.id}), at the bottom of Your board."
      end

      def do_rename(args)
        category = find_category(args)
        old_name = category.name
        category.update!(name: require_arg(args, "name"))
        "Renamed **#{old_name}** to **#{category.name}** (id #{category.id})."
      end

      def do_delete(args)
        category = find_category(args)
        category.destroy!
        "Deleted category **#{category.name}** (id #{category.id}). Its sessions are in Uncategorized."
      end

      def do_reorder(args)
        ids = require_arg(args, "category_ids")
        raise ToolError, 'The "category_ids" parameter must be an array.' unless ids.is_a?(Array)

        ordered = BoardCategories::Reorder.call(ids: ids)
        "Categories now read, top first: #{ordered.map { |c| "#{c.name} (#{c.id})" }.join(', ')}."
      end

      def do_set_collapsed(args)
        category = find_category(args)
        raise ToolError, 'The "collapsed" parameter must be true or false.' unless [ true, false ].include?(args["collapsed"])

        category.update!(collapsed: args["collapsed"])
        "**#{category.name}** is now #{category.collapsed ? 'collapsed' : 'expanded'}."
      end

      def do_set_visibility(args)
        category = find_category(args)
        BoardCategories::SetVisibility.call(
          category: category,
          visibility: require_arg(args, "visibility"),
          snoozed_until: args["snoozed_until"],
          timezone: args["timezone"].presence || "UTC"
        )
        summary = category.visibility_summary || "Back on Your board"
        "**#{category.name}**: #{summary}. Nothing about when its sessions run has changed."
      end

      def do_assign(args)
        session = find_session(args["session_id"])
        category = BoardCategories::Assign.call(session: session, category_id: args["category_id"])
        "Session #{session.id} is now in #{category ? "**#{category.name}**" : 'Uncategorized'}."
      end

      def find_category(args)
        id = require_arg(args, "category_id")
        BoardCategory.find_by(id: id) || raise(ToolError, "No board category with id #{id}.")
      end
    end
  end
end
