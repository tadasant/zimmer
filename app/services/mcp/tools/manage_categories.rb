# frozen_string_literal: true

module Mcp
  module Tools
    # Mirrors /api/v1/categories (index/create/update/destroy/reorder) plus
    # SessionsController#set_category and #reorder, which are the
    # "set_session_category" and "reorder_sessions" actions. Normalization,
    # uniqueness and the Uncategorized sentinel all live in the Category model,
    # and card positions in SessionCardOrder, so every write path stays canonical.
    #
    # The last three actions mirror CategorizationController — the tuning loop
    # from tadasant/zimmer#16. They are here rather than on a tool of their own
    # because the lever an operator reaches for first is a category DESCRIPTION,
    # which this tool already owns: reading the score and sharpening a
    # description are one task, and splitting them across two tools would make an
    # agent hold half the loop.
    class ManageCategories < Tool
      ACTIONS = %w[
        list create update delete reorder set_session_category reorder_sessions
        tuning set_tuning replay
      ].freeze

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
        - **tuning**: Show the categorization tuning state — the guidance preamble, the model, the category descriptions the inference actually sees, the recent corrections and the last replay score.
        - **set_tuning**: Set the guidance preamble ("guidance") and/or the inference model ("inference_model"). Either may be null/"" to clear.
        - **replay**: Re-run categorization against the stored context of the most recent corrections ("limit", default 10, max 50) and record what the CURRENT config answers. Writes no session — it is a dry run, and its verdicts show up under "tuning".
        - **reorder_sessions**: Set the top-to-bottom order of session cards inside one section (requires "session_ids"; "category_id" names the section, omit/null for Uncategorized). The dashboard shows a section 50 cards at a time, so a partial list is fine: the sessions you name are dealt back into the slots they already hold, in your order, and sessions you omit keep their positions. Pass "session_id" to move ONE card instead, as the dashboard's drag does: it is placed immediately above the session after it in "session_ids" (or below the one before it, if it is last), nothing else moves, and if it is in another section it is moved into this one first.

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
            description: 'Session ID (numeric) or slug (string). Required for "set_session_category". Optional for "reorder_sessions": the one card being moved — placed next to its neighbour in "session_ids", and moved into "category_id" first if it is in another section.'
          },
          session_ids: {
            type: "array",
            items: { type: "number" },
            description: 'Required for "reorder_sessions". New top-to-bottom order of numeric session IDs within the section named by "category_id". Sessions omitted keep their positions; IDs not in that section are ignored.'
          },
          guidance: {
            type: [ "string", "null" ],
            description: 'For "set_tuning". Extra guidance placed inside the category task only, delimited and introduced as being about the CATEGORY choice (max 2000 chars). It cannot edit or remove the fixed instruction, the title task, the response format or "when in doubt, prefer NONE". The same model call also writes the title, so keep it about categories. Pass null or "" to clear.'
          },
          inference_model: {
            type: [ "string", "null" ],
            description: 'For "set_tuning". Model id the categorization inference runs on. Must be a Claude Code model id. Pass null or "" to fall back to the default.'
          },
          limit: {
            type: "number",
            description: 'For "replay" and "tuning". How many of the most recent corrections to replay or list (default 10 for replay, capped at 50).'
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
        when "reorder_sessions" then reorder_sessions(args)
        when "tuning" then tuning(args)
        when "set_tuning" then set_tuning(args)
        when "replay" then replay(args)
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
          session.category_change_source = CategoryFeedbackEvent::MCP
          session.update!(category_id: category.id)
        else
          session.category_change_source = CategoryFeedbackEvent::MCP
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

      def reorder_sessions(args)
        ids = args["session_ids"]
        unless ids.is_a?(Array) && ids.any?
          raise ToolError, '"session_ids" (a non-empty array) is required for the "reorder_sessions" action.'
        end

        category_id = args["category_id"].presence
        category = nil
        if category_id && category_id.to_s != Category::UNCATEGORIZED_SENTINEL
          category = Category.find_by(id: category_id)
          raise ToolError, "Category ##{category_id} not found" unless category
        end

        moved = args["session_id"].presence && find_session(args["session_id"]).id
        order = Session.reorder_cards!(
          ids,
          category_id: category&.id,
          moved_session_id: moved,
          source: CategoryFeedbackEvent::MCP
        )

        [
          "## Session Cards Reordered",
          "",
          "- **Section:** #{category&.name || 'Uncategorized'}",
          "- **Order (top to bottom):** #{order.join(', ')}"
        ].join("\n")
      end

      # --- The tuning loop (tadasant/zimmer#16) ---------------------------------

      def tuning(args)
        limit = CategorizationReplayJob.clamp_limit(args["limit"].presence || CategoryFeedbackEvent::DEFAULT_CORPUS_LIMIT)
        service = CategorizationService.new
        corrections = CategoryFeedbackEvent.eval_corpus(limit: limit).without_bodies.to_a
        scorecard = CategoryFeedbackEvent.scorecard(corrections)
        declines = CategoryFeedbackEvent.decline_rate

        lines = [
          "## Categorization Tuning",
          "",
          "- **Model:** #{service.model}#{' (default)' if AppSetting.current.category_inference_model.blank?}",
          "- **Guidance:** #{service.guidance || '(none)'}",
          "- **Corrections recorded (shown):** #{scorecard.total}",
          "- **Replay agrees:** #{scorecard.accuracy_pct ? "#{scorecard.accuracy_pct}% of #{scorecard.replayed} scored" : 'not replayed yet'}",
          "- **Declined to categorize:** #{declines ? "#{declines[:declined]} of the last #{declines[:sampled]} outcomes" : 'no outcomes recorded yet'}"
        ]

        lines += [ "", "### Candidate categories (what the inference sees)", "" ]
        candidates = CategorizationService.candidates
        if candidates.empty?
          lines << "- (none — every category is frozen, or there are none)"
        else
          candidates.each do |category|
            lines << "- **#{category.name}:** #{category.description.presence || '(no description — matched on name alone)'}"
          end
        end

        lines += [ "", "### Recent corrections", "" ]
        if corrections.empty?
          lines << "- (none yet — a correction is recorded when you move a session the categorizer already ruled on)"
        else
          corrections.each do |event|
            verdict = event.replay_correct?
            mark = verdict.nil? ? "not replayed" : (verdict ? "replay agrees" : "replay still says #{event.replay_label}")
            lines << "- Session #{event.session_id || '(deleted)'}: #{event.auto_label} -> #{event.corrected_label} (#{mark})"
          end
        end

        lines.join("\n")
      end

      def set_tuning(args)
        unless args.key?("guidance") || args.key?("inference_model")
          raise ToolError, '"set_tuning" needs at least one of "guidance" or "inference_model".'
        end

        setting = AppSetting.editable
        setting.category_guidance = args["guidance"].to_s.strip.presence if args.key?("guidance")
        setting.category_inference_model = args["inference_model"].to_s.strip.presence if args.key?("inference_model")

        unless setting.save
          raise ToolError, "Could not save: #{setting.errors.full_messages.join(', ')}"
        end

        [
          "## Categorization Tuning Updated",
          "",
          "- **Model:** #{CategorizationService.new.model}",
          "- **Guidance:** #{setting.category_guidance || '(none)'}",
          "",
          'Run the "replay" action to score the change against the recorded corrections.'
        ].join("\n")
      end

      def replay(args)
        limit = CategorizationReplayJob.clamp_limit(args["limit"].presence || CategorizationReplayJob::DEFAULT_LIMIT)
        size = CategoryFeedbackEvent.eval_corpus(limit: limit).pluck(:id).size
        raise ToolError, "No corrections have been recorded yet, so there is nothing to replay." if size.zero?

        unless CategorizationReplayJob.enqueue(limit)
          return [
            "## Categorization Replay Not Queued",
            "",
            "A replay is already queued or running. Read its scores with the \"tuning\" action once it finishes."
          ].join("\n")
        end

        [
          "## Categorization Replay Queued",
          "",
          "- **Corrections queued:** #{size}",
          "- **Writes:** none to any session — only the replay verdict on each correction row",
          "",
          'Read the scores back with the "tuning" action once the job has run.'
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
