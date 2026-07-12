# frozen_string_literal: true

module Mcp
  module Tools
    # Mirrors /api/v1/categories (index/create/update/destroy/reorder) plus
    # SessionsController#set_category, which is the "set_session_category"
    # action. Normalization, uniqueness and the Uncategorized sentinel all live
    # in the Category model, so every write path stays canonical.
    class ManageCategories < Tool
      ACTIONS = %w[list create update delete reorder set_session_category].freeze

      tool_name "manage_categories"

      description <<~DESC
        Manage categories used to organize sessions on the Zimmer dashboard.

        Categories are the named sections sessions are grouped under. Sessions not assigned to a category fall under the built-in "Uncategorized" section.

        **Actions:**
        - **list**: List all categories ordered by position, with session counts.
        - **create**: Create a new category (requires "name"; optional "description"). Names are unique case-insensitively (max 100 chars); description max 1000 chars.
        - **update**: Rename, re-describe, or freeze/unfreeze a category (requires "category_id"; any subset of "name", "description", "is_frozen"). Omitted fields are left unchanged.
        - **delete**: Delete a category (requires "category_id"). Sessions in it fall back to Uncategorized.
        - **reorder**: Set the top-to-bottom order of categories (requires "ids" — an array of category IDs). Categories omitted keep their existing position. Include the string "uncategorized" to position the Uncategorized section.
        - **set_session_category**: Assign a session to a category (requires "session_id"; "category_id" to assign, or omit/null to clear to Uncategorized).

        **Note:** All freeze state uses "is_frozen".
      DESC

      input_schema({
        type: "object",
        properties: {
          action: {
            type: "string",
            enum: ACTIONS,
            description: "The category management action to perform."
          },
          category_id: {
            type: [ "number", "null" ],
            description: 'Category ID. Required for "update" and "delete". For "set_session_category", the target category to assign (omit or null to clear to Uncategorized).'
          },
          name: {
            type: "string",
            description: 'Category name. Required for "create"; optional for "update". Unique case-insensitively, max 100 chars.'
          },
          description: {
            type: "string",
            description: 'Category description. Optional for "create" and "update". Max 1000 chars; blank clears it.'
          },
          is_frozen: {
            type: "boolean",
            description: 'Freeze (true) or unfreeze (false) the category. Optional for "update".'
          },
          ids: {
            type: "array",
            items: { oneOf: [ { type: "number" }, { type: "string", enum: [ "uncategorized" ] } ] },
            description: 'Required for "reorder". New top-to-bottom order of category IDs. Categories omitted keep their position. Use the string "uncategorized" to position the Uncategorized section.'
          },
          session_id: {
            oneOf: [ { type: "string" }, { type: "number" } ],
            description: 'Session ID (numeric) or slug (string). Required for "set_session_category".'
          }
        },
        required: [ "action" ]
      })

      def call(args)
        action = require_arg(args, :action).to_s

        case action
        when "list" then list
        when "create" then create(args)
        when "update" then update(args)
        when "delete" then destroy(args)
        when "reorder" then reorder(args)
        when "set_session_category" then set_session_category(args)
        else
          raise ToolError, "Unknown action \"#{action}\". Valid actions: #{ACTIONS.join(', ')}"
        end
      end

      private

      def list
        categories = Category.ordered.to_a
        return "## Categories\n\nNo categories found." if categories.empty?

        counts = session_counts
        blocks = categories.map { |category| format_category(category, counts[category.id] || 0) }
        ([ "## Categories (#{categories.size})", "" ] + blocks).join("\n\n")
      end

      def create(args)
        name = args["name"]
        raise ToolError, '"name" is required for the "create" action.' if name.blank?

        category = Category.new(name: name, description: args["description"])
        raise ToolError, "Validation failed: #{category.errors.full_messages.join(', ')}" unless category.save

        [ "## Category Created", "", format_category(category, 0) ].join("\n")
      end

      def update(args)
        category = find_category(args, "update")

        attrs = {}
        attrs[:name] = args["name"] if args.key?("name")
        attrs[:description] = args["description"] if args.key?("description")
        attrs[:is_frozen] = args["is_frozen"] if args.key?("is_frozen")

        if attrs.empty?
          raise ToolError, 'provide at least one of "name", "description", or "is_frozen" for the "update" action.'
        end

        raise ToolError, "Validation failed: #{category.errors.full_messages.join(', ')}" unless category.update(attrs)

        [ "## Category Updated", "", format_category(category, category.sessions.count) ].join("\n")
      end

      def destroy(args)
        category = find_category(args, "delete")
        category_id = category.id
        category.destroy!

        "## Category Deleted\n\nCategory #{category_id} has been deleted. Its sessions fall back to Uncategorized."
      end

      def reorder(args)
        ids = args["ids"]
        unless ids.is_a?(Array) && ids.any?
          raise ToolError, '"ids" (a non-empty array) is required for the "reorder" action.'
        end

        Category.reorder!(ids)

        counts = session_counts
        blocks = Category.ordered.map { |category| format_category(category, counts[category.id] || 0) }
        ([ "## Categories Reordered", "" ] + blocks).join("\n\n")
      end

      def set_session_category(args)
        raise ToolError, '"session_id" is required for the "set_session_category" action.' if args["session_id"].blank?
        session = find_session(args["session_id"])

        category_id = args["category_id"].presence
        if category_id
          category = Category.find_by(id: category_id)
          raise ToolError, "Category ##{category_id} not found" unless category
          session.update!(category_id: category.id)
        else
          session.update!(category_id: nil)
        end

        [
          "## Session Category Updated",
          "",
          "- **Session ID:** #{session.id}",
          "- **Category:** #{session.category&.name || 'Uncategorized'}",
          "- **Result:** #{session.category_id ? 'Session assigned to category' : 'Session moved to Uncategorized'}"
        ].join("\n")
      end

      def find_category(args, action)
        category_id = args["category_id"]
        raise ToolError, "\"category_id\" is required for the \"#{action}\" action." if category_id.nil?

        category = Category.find_by(id: category_id)
        raise ToolError, "Category ##{category_id} not found" unless category
        category
      end

      def session_counts
        Session.where.not(category_id: nil).group(:category_id).count
      end

      def format_category(category, session_count)
        lines = [
          "### #{category.name} (ID: #{category.id})",
          "- **Position:** #{category.position}",
          "- **Frozen:** #{category.is_frozen}"
        ]
        lines << "- **Description:** #{category.description}" if category.description.present?
        lines << "- **Sessions:** #{session_count}"
        lines.join("\n")
      end
    end
  end
end
