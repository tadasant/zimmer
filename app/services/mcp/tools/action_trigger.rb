# frozen_string_literal: true

module Mcp
  module Tools
    # Mirrors POST/PATCH/DELETE /api/v1/triggers and POST /api/v1/triggers/:id/toggle.
    #
    # The REST endpoint only accepts conditions in the nested
    # `trigger_conditions_attributes` shape; this tool keeps the flatter
    # `trigger_type` + `configuration` contract the model-facing schema has always
    # exposed and folds it into a single condition. On update the existing
    # condition's id is resolved first so `accepts_nested_attributes_for` modifies
    # it in place instead of appending a duplicate.
    class ActionTrigger < Tool
      ACTIONS = %w[create update delete toggle].freeze
      TRIGGER_TYPES = %w[slack schedule].freeze
      STATUSES = %w[enabled disabled].freeze

      tool_name "action_trigger"

      description <<~DESC
        Create, update, delete, or toggle automation triggers.

        **Actions:**
        - **create**: Create a new trigger (requires name, trigger_type, agent_root_name, prompt_template)
        - **update**: Update an existing trigger (requires "id")
        - **delete**: Delete a trigger (requires "id")
        - **toggle**: Enable/disable a trigger (requires "id")

        **Trigger types:**
        - **slack**: Triggered by Slack events (requires configuration with channel_id)
        - **schedule**: Triggered on a recurring or one-time schedule

        **Schedule configuration:**
        - **Recurring**: `{"interval": 2, "unit": "hours", "timezone": "UTC"}` — fires every N units
        - **One-time**: `{"scheduled_at": "2026-04-15T14:30:00", "timezone": "America/New_York"}` — fires once at the specified datetime (ISO 8601), then auto-disables

        Use search_triggers first to see available triggers and Slack channels.
      DESC

      input_schema({
        type: "object",
        properties: {
          action: { type: "string", enum: ACTIONS, description: "Action to perform." },
          id: { type: "number", description: "Trigger ID. Required for update, delete, toggle." },
          name: { type: "string", description: "Trigger name. Required for create." },
          trigger_type: {
            type: "string",
            enum: TRIGGER_TYPES,
            description: "Trigger type. Required for create."
          },
          agent_root_name: { type: "string", description: "Agent root name. Required for create." },
          prompt_template: { type: "string", description: "Prompt template. Required for create." },
          status: { type: "string", enum: STATUSES, description: "Trigger status." },
          goal: { type: "string", description: "Goal for triggered sessions." },
          reuse_session: { type: "boolean", description: "Whether to reuse existing sessions." },
          mcp_servers: {
            type: "array",
            items: { type: "string" },
            description: "MCP servers for triggered sessions."
          },
          configuration: {
            type: "object",
            description: "Type-specific configuration (schedule, Slack channel, etc.)."
          }
        },
        required: [ "action" ]
      })

      def call(args)
        case require_arg(args, :action)
        when "create" then create(args)
        when "update" then update(args)
        when "delete" then destroy(args)
        when "toggle" then toggle(args)
        else raise ToolError, "Unknown action \"#{args['action']}\""
        end
      end

      private

      def create(args)
        %w[name trigger_type agent_root_name prompt_template].each do |key|
          if args[key].blank?
            raise ToolError, '"name", "trigger_type", "agent_root_name", and "prompt_template" ' \
                             'are required for the "create" action.'
          end
        end

        enforce_allowed_root!(args["agent_root_name"])

        trigger = Trigger.new(
          name: args["name"],
          agent_root_name: args["agent_root_name"],
          prompt_template: args["prompt_template"],
          status: args["status"].presence || "enabled",
          goal: args["goal"],
          reuse_session: args.fetch("reuse_session", false),
          mcp_servers: args["mcp_servers"] || [],
          trigger_conditions_attributes: [
            { condition_type: args["trigger_type"], configuration: args["configuration"] || {} }
          ]
        )
        trigger.save!

        <<~TEXT.strip
          ## Trigger Created

          - **ID:** #{trigger.id}
          - **Name:** #{trigger.name}
          - **Conditions:** #{condition_types_summary(trigger)}
          - **Status:** #{trigger.status}
          - **Agent Root:** #{trigger.agent_root_name}
        TEXT
      end

      def update(args)
        trigger = find_trigger(args["id"], "update")

        # A restricted connection may only touch triggers that already belong to
        # an allowed root, and may only move one to another allowed root.
        enforce_allowed_root!(trigger.agent_root_name)
        enforce_allowed_root!(args["agent_root_name"]) if args["agent_root_name"].present?

        attributes = {}
        attributes[:name] = args["name"] if args["name"].present?
        attributes[:agent_root_name] = args["agent_root_name"] if args["agent_root_name"].present?
        attributes[:prompt_template] = args["prompt_template"] if args["prompt_template"].present?
        attributes[:status] = args["status"] if args["status"].present?
        attributes[:goal] = args["goal"] if args.key?("goal")
        attributes[:reuse_session] = args["reuse_session"] if args.key?("reuse_session")
        # Only assign artifact lists the caller actually sent: an omitted key means
        # "no opinion", never "clear the trigger's servers".
        attributes[:mcp_servers] = args["mcp_servers"] if args["mcp_servers"].is_a?(Array)

        if args["trigger_type"].present? || args["configuration"].present?
          attributes[:trigger_conditions_attributes] = updated_condition_attributes(trigger, args)
        end

        trigger.update!(attributes)

        <<~TEXT.strip
          ## Trigger Updated

          - **ID:** #{trigger.id}
          - **Name:** #{trigger.name}
          - **Status:** #{trigger.status}
        TEXT
      end

      def destroy(args)
        trigger = find_trigger(args["id"], "delete")
        enforce_allowed_root!(trigger.agent_root_name)

        id = trigger.id
        trigger.destroy!

        "## Trigger Deleted\n\nTrigger #{id} has been deleted."
      end

      def toggle(args)
        trigger = find_trigger(args["id"], "toggle")
        enforce_allowed_root!(trigger.agent_root_name)

        trigger.toggle!

        <<~TEXT.strip
          ## Trigger Toggled

          - **ID:** #{trigger.id}
          - **Name:** #{trigger.name}
          - **New Status:** #{trigger.status}
        TEXT
      end

      # Resolve which existing condition the flat trigger_type/configuration pair
      # is meant to modify: the one of the requested type, or the sole condition
      # when no type was given. Without an id the nested-attributes writer would
      # append a second condition rather than edit the one the caller means.
      def updated_condition_attributes(trigger, args)
        existing = trigger.trigger_conditions.to_a
        target = if args["trigger_type"].present?
          existing.find { |c| c.condition_type == args["trigger_type"] }
        elsif existing.size == 1
          existing.first
        end

        condition_type = args["trigger_type"].presence || target&.condition_type
        if condition_type.nil?
          raise ToolError, "Cannot update trigger configuration without a trigger_type when the " \
                           "trigger has zero or multiple conditions."
        end

        attributes = {
          condition_type: condition_type,
          configuration: args["configuration"] || target&.configuration || {}
        }
        attributes[:id] = target.id if target

        # Changing a trigger's condition *type* replaces the condition rather than
        # adding one. Conditions are OR'd, so an appended condition would leave the
        # trigger still firing on the type the caller believes it just replaced.
        return [ attributes ] if target || existing.empty?

        if existing.size > 1
          raise ToolError, "Trigger #{trigger.id} has #{existing.size} conditions " \
                           "(#{existing.map(&:condition_type).join(', ')}) and none is a #{condition_type} condition. " \
                           "Delete and recreate the trigger rather than changing its condition type here."
        end

        [ attributes, { id: existing.first.id, _destroy: true } ]
      end

      def find_trigger(id, action)
        raise ToolError, "\"id\" is required for the \"#{action}\" action." if id.blank?

        trigger = Trigger.includes(:trigger_conditions).find_by(id: id.to_i)
        raise ToolError, "Trigger not found: #{id}" unless trigger
        trigger
      end

      def condition_types_summary(trigger)
        types = trigger.trigger_conditions.map(&:condition_type).uniq
        types.any? ? types.join(", ") : "(none)"
      end
    end
  end
end
