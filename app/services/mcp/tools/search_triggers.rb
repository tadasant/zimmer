# frozen_string_literal: true

module Mcp
  module Tools
    # Mirrors GET /api/v1/triggers, GET /api/v1/triggers/:id and
    # GET /api/v1/triggers/channels: one read tool over the trigger catalog.
    #
    # `trigger_type` filters on the *condition* type — a trigger is a template
    # fired by one or more conditions (OR semantics), so a type filter matches
    # triggers with at least one condition of that type.
    class SearchTriggers < Tool
      TRIGGER_TYPES = %w[slack schedule ao_event].freeze
      STATUSES = %w[enabled disabled].freeze

      tool_name "search_triggers"

      description <<~DESC
        Search and list automation triggers.

        **Modes:**
        - **Get by ID**: Provide an id to get trigger details with recent sessions
        - **List**: List triggers with optional filters (trigger_type, status, pagination)
        - **Include channels**: Set include_channels=true to also list available Slack channels (useful when creating Slack triggers)

        **Filterable trigger types:**
        - **slack**: Triggers fired by Slack messages
        - **schedule**: Recurring or one-time scheduled triggers
        - **ao_event**: Triggers fired by internal Zimmer state transitions (e.g., a session entering needs_input or failed). These back the `wake_me_up_when_session_changes_state` tool.

        A trigger may have multiple conditions (OR semantics) — filtering by trigger_type returns triggers that have at least one condition of that type.

        **Use cases:**
        - View configured automations (scheduled tasks, Slack integrations, ao_event waiters)
        - Check trigger status and execution history
        - Discover available Slack channels for new triggers
      DESC

      input_schema({
        type: "object",
        properties: {
          id: {
            type: "number",
            description: "Get a specific trigger by ID. Returns trigger details with recent sessions."
          },
          trigger_type: {
            type: "string",
            enum: TRIGGER_TYPES,
            description: "Filter to triggers having at least one condition of this type. Maps to the API's `condition_type` query parameter."
          },
          status: {
            type: "string",
            enum: STATUSES,
            description: "Filter by status."
          },
          include_channels: {
            type: "boolean",
            description: "Include available Slack channels. Default: false"
          },
          page: { type: "number", minimum: 1, description: "Page number. Default: 1" },
          per_page: {
            type: "number",
            minimum: 1,
            maximum: 100,
            description: "Results per page. Default: 25"
          }
        },
        required: []
      })

      def call(args)
        return show(args["id"]) if args["id"].present?

        list(args)
      end

      private

      def show(id)
        trigger = find_trigger(id)

        lines = [
          "## Trigger: #{trigger.name}",
          "",
          "- **ID:** #{trigger.id}",
          "- **Conditions:** #{condition_types_summary(trigger)}",
          "- **Status:** #{trigger.status}",
          "- **Agent Root:** #{trigger.agent_root_name}",
          "- **Reuse Session:** #{trigger.reuse_session ? 'Yes' : 'No'}",
          "- **MCP Servers:** #{trigger.mcp_servers.presence&.join(', ') || '(none)'}"
        ]
        lines << "- **Goal:** #{trigger.goal}" if trigger.goal.present?
        lines << "- **Sessions Created:** #{trigger.sessions_created_count}"
        lines << "- **Last Triggered:** #{trigger.last_triggered_at.iso8601}" if trigger.last_triggered_at
        lines.push("", "### Prompt Template", "```", trigger.prompt_template, "```")

        conditions = trigger.trigger_conditions.to_a
        if conditions.any?
          lines.push("", "### Conditions")
          conditions.each do |condition|
            lines << "- **#{condition.condition_type}** — #{condition.description}"
            next if condition.configuration.blank?

            lines << "  ```json"
            JSON.pretty_generate(condition.configuration).split("\n").each { |line| lines << "  #{line}" }
            lines << "  ```"
          end
        end

        recent_sessions = recent_sessions_for(trigger)
        if recent_sessions.any?
          lines.push("", "### Recent Sessions")
          recent_sessions.each do |session|
            lines << "- **##{session.id}** #{session.title} (#{session.status})"
          end
        end

        lines.join("\n")
      end

      def list(args)
        page = [ args["page"].to_i, 1 ].max
        per_page = args["per_page"].present? ? [ [ args["per_page"].to_i, 1 ].max, 100 ].min : 25

        scope = Trigger.includes(:trigger_conditions).order(created_at: :desc)
        if args["trigger_type"].present?
          scope = scope
            .joins(:trigger_conditions)
            .where(trigger_conditions: { condition_type: args["trigger_type"] })
            .distinct
        end
        scope = scope.where(status: args["status"]) if args["status"].present?
        # A restricted connection only sees the triggers it could act on — the same
        # roots action_trigger will let it create, update, delete, or toggle.
        scope = scope.where(agent_root_name: context.allowed_agent_roots) if context.restricted?

        total_count = scope.count
        total_pages = (total_count.to_f / per_page).ceil
        triggers = scope.limit(per_page).offset((page - 1) * per_page).to_a

        lines = []
        if triggers.empty?
          lines << "## Triggers\n\nNo triggers found."
        else
          lines.push("## Triggers (#{total_count} total, page #{page} of #{total_pages})", "")
          triggers.each do |trigger|
            lines << "### #{trigger.name} (ID: #{trigger.id})"
            lines << "- **Conditions:** #{condition_types_summary(trigger)} | **Status:** #{trigger.status} | " \
                     "**Sessions:** #{trigger.sessions_created_count}"
            trigger.trigger_conditions.each { |condition| lines << "  - #{condition.description}" }
            lines << ""
          end
        end

        lines.concat(slack_channel_lines) if args["include_channels"]

        lines.join("\n")
      end

      def find_trigger(id)
        trigger = Trigger.includes(:trigger_conditions).find_by(id: id.to_i)
        raise ToolError, "Trigger not found: #{id}" unless trigger
        # A trigger on a root this connection may not use is not its business, and
        # saying "not found" avoids confirming it exists.
        raise ToolError, "Trigger not found: #{id}" if context.restricted? && !context.allowed_agent_roots.include?(trigger.agent_root_name)

        trigger
      end

      # Sessions a trigger has spawned are stamped with its id in metadata.
      def recent_sessions_for(trigger)
        Session
          .where("metadata->>'trigger_id' = ?", trigger.id.to_s)
          .order(created_at: :desc)
          .limit(10)
          .to_a
      end

      def condition_types_summary(trigger)
        types = trigger.trigger_conditions.map(&:condition_type).uniq
        types.any? ? types.join(", ") : "(none)"
      end

      # A Slack outage (or an unconfigured workspace) must not sink the trigger
      # listing the caller actually asked for, so the failure is reported inline
      # as a footnote rather than raised — same contract as the REST endpoint,
      # which answers this with a 503 the caller is expected to tolerate.
      def slack_channel_lines
        raise SlackService::SlackError, "Slack is not configured" unless SlackService.configured?

        channels = SlackService.list_channels
        lines = [ "", "## Available Slack Channels", "" ]
        if channels.empty?
          lines << "No Slack channels available."
        else
          channels.each do |channel|
            lines << "- **##{channel.name}** (#{channel.id}) - #{channel.num_members} members" \
                     "#{channel.is_private ? ' [private]' : ''}"
          end
        end
        lines
      rescue StandardError => e
        [ "", "*Could not fetch Slack channels: #{e.message}*" ]
      end
    end
  end
end
