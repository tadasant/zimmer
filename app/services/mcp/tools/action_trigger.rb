# frozen_string_literal: true

module Mcp
  module Tools
    # Mirrors POST/PATCH/DELETE /api/v1/triggers and POST /api/v1/triggers/:id/toggle.
    #
    # Two ways to express a trigger's conditions, because a Trigger ORs its
    # conditions and the flat contract can only describe one of them:
    #
    # - Flat: `trigger_type` + `configuration`, folded into a single condition. This
    #   is what the schema has always exposed and what live callers send, so it must
    #   keep behaving exactly as it did. On update the existing condition's id is
    #   resolved first so `accepts_nested_attributes_for` modifies it in place
    #   instead of appending a duplicate.
    # - `conditions`: an array, reaching the parity the UI and the REST API already
    #   have. On update it is an UPSERT, never a replace — an element carrying an
    #   `id` edits that row, one without appends, and an existing row the array does
    #   not mention is left alone unless it is explicitly sent with `remove: true`.
    #
    # The upsert semantics are not a stylistic choice. Every Slack condition carries
    # live poller cursors inside its `configuration`
    # (TriggerCondition::SLACK_POLL_STATE_KEYS: channel_timestamps,
    # thread_timestamps, bot_activity_timestamps, participating_threads,
    # dm_timestamps — plus allowed_user_ids), which `preserve_slack_poll_state`
    # keeps only by merging back the keys an incoming configuration OMITS. A replace
    # would destroy the row and take its cursors with it, silently re-baselining a
    # live trigger; an omitted-means-untouched upsert cannot.
    class ActionTrigger < Tool
      ACTIONS = %w[create update delete toggle].freeze
      TRIGGER_TYPES = %w[slack schedule github_label github_issue].freeze
      STATUSES = %w[enabled disabled].freeze

      tool_name "action_trigger"

      description <<~DESC
        Create, update, delete, or toggle automation triggers.

        **Actions:**
        - **create**: Create a new trigger (requires name, trigger_type, agent_root_name, prompt_template)
        - **update**: Update an existing trigger (requires "id")
        - **delete**: Delete a trigger (requires "id")
        - **toggle**: Enable/disable a trigger (requires "id")

        **Conditions (OR semantics):** a trigger fires when ANY of its conditions matches.
        Two ways to say so:
        - **One condition:** send `trigger_type` + `configuration` at the top level, as always.
        - **Several conditions:** send `conditions` — an array of `{trigger_type, configuration}`
          objects. Use this for a trigger that must fire on more than one thing, e.g. a Slack
          passive listener carrying both `passive_listen_thread` and `passive_listen_channel`.
          `conditions` and the flat `trigger_type`/`configuration` pair are mutually exclusive.

        On **update**, `conditions` is an upsert, not a replacement:
        - An element with an `id` updates that condition. Omit `configuration` to leave it
          untouched; send one to replace it (keys the Slack poller owns — cursors and
          `allowed_user_ids` — survive an update that omits them).
        - An element without an `id` adds a new condition.
        - An existing condition the array does not mention is **left alone**. To delete one,
          send `{"id": 123, "remove": true}`.
        Use search_triggers to read a trigger's existing condition ids.

        **Trigger types:**
        - **slack**: Triggered by Slack events (requires configuration with channel_id)
        - **schedule**: Triggered on a recurring or one-time schedule
        - **github_label**: Triggered when a watched label is ADDED to a PR/issue in a watched repo
        - **github_issue**: Triggered when a new issue is opened in a watched repo

        **Burst control:**
        - **max_sessions_per_minute**: caps how many sessions the trigger may spawn per minute.
          Omit (or send null) for no limit — that is the default and how every trigger behaved
          before this setting existed. When the cap is exceeded, the trigger spawns a single
          burst-notice session linking the sessions it already spawned, then stops spawning
          until the burst subsides. Events that arrive during the burst are dropped.

        **Schedule configuration:**
        - **Recurring**: `{"interval": 2, "unit": "hours", "timezone": "UTC"}` — fires every N units
        - **One-time**: `{"scheduled_at": "2026-04-15T14:30:00", "timezone": "America/New_York"}` — fires once at the specified datetime (ISO 8601), then auto-disables

        **GitHub configuration:**
        - **github_label**: `{"repos": ["owner/a", "owner/b"], "target": "pull_request", "labels": ["ready to merge"]}`
          — `target` is `pull_request` (default) or `issue`; any ONE of `labels` firing is enough.
        - **github_issue**: `{"repos": ["owner/a"]}`

        GitHub triggers fire on the label being *added*, not on it merely being present: an item
        that already carries the label when the trigger is created is absorbed into a baseline on
        the first poll and does NOT fire retroactively. Removing and re-adding the label fires again.
        Editing `repos`/`labels`/`target` re-baselines the condition, so widening the watch does not
        stampede sessions for everything already labelled.

        Triggered sessions receive the repo, number, URL, title, author, body and labels — via the
        `{{repo}}`, `{{number}}`, `{{link}}`, `{{title}}`, `{{author}}`, `{{text}}`, `{{labels}}` and
        `{{event}}` template variables, or appended as a context block if the template names none.

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
          max_sessions_per_minute: {
            type: [ "number", "null" ],
            minimum: 1,
            description: "Cap on sessions this trigger may spawn per minute. Null (default) means no limit. " \
                         "Exceeding it spawns one burst-notice session and suppresses further spawns for the burst."
          },
          mcp_servers: {
            type: "array",
            items: { type: "string" },
            description: "MCP servers for triggered sessions."
          },
          configuration: {
            type: "object",
            description: "Type-specific configuration (schedule, Slack channel, etc.). " \
                         "For a single-condition trigger; use \"conditions\" for several."
          },
          conditions: {
            type: "array",
            description: "Conditions for a trigger that fires on more than one thing (OR semantics). " \
                         "Mutually exclusive with the top-level trigger_type/configuration pair. " \
                         "On update this UPSERTS: an element with an id edits that condition, one " \
                         "without adds a condition, and an existing condition missing from the array " \
                         "is left untouched (send remove: true to delete one).",
            items: {
              type: "object",
              properties: {
                id: {
                  type: "number",
                  description: "Existing condition id to update or remove. Omit to add a new condition."
                },
                trigger_type: {
                  type: "string",
                  enum: TRIGGER_TYPES,
                  description: "Condition type. Required when adding a condition."
                },
                configuration: {
                  type: "object",
                  description: "Type-specific configuration. Omit on an update to leave the existing one as is."
                },
                remove: {
                  type: "boolean",
                  description: "Delete this condition. Requires id."
                }
              }
            }
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
        # trigger_type describes the trigger's ONE condition, so it is required only
        # when the caller is using the flat single-condition contract; a conditions
        # array carries a type per element instead.
        required = %w[name agent_root_name prompt_template]
        required << "trigger_type" if args["conditions"].blank?

        required.each do |key|
          if args[key].blank?
            raise ToolError, '"name", "agent_root_name", and "prompt_template" are required for the ' \
                             '"create" action, plus either "trigger_type" or a "conditions" array.'
          end
        end

        enforce_allowed_root!(args["agent_root_name"])
        reject_conflicting_condition_args!(args)

        trigger = Trigger.new(
          name: args["name"],
          agent_root_name: args["agent_root_name"],
          prompt_template: args["prompt_template"],
          status: args["status"].presence || "enabled",
          goal: args["goal"],
          reuse_session: args.fetch("reuse_session", false),
          max_sessions_per_minute: args["max_sessions_per_minute"].presence,
          mcp_servers: args["mcp_servers"] || [],
          trigger_conditions_attributes: created_condition_attributes(args)
        )
        trigger.save!

        <<~TEXT.strip
          ## Trigger Created

          - **ID:** #{trigger.id}
          - **Name:** #{trigger.name}
          - **Conditions:** #{condition_types_summary(trigger)}
          - **Status:** #{trigger.status}
          - **Agent Root:** #{trigger.agent_root_name}
          - **Max Sessions/Minute:** #{trigger.max_sessions_per_minute || '(no limit)'}

          #{condition_detail(trigger)}
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
        # An explicit null clears the cap (back to unbounded); an omitted key means "no opinion".
        attributes[:max_sessions_per_minute] = args["max_sessions_per_minute"].presence if args.key?("max_sessions_per_minute")
        # Only assign artifact lists the caller actually sent: an omitted key means
        # "no opinion", never "clear the trigger's servers".
        attributes[:mcp_servers] = args["mcp_servers"] if args["mcp_servers"].is_a?(Array)

        reject_conflicting_condition_args!(args)

        if args["conditions"].present?
          attributes[:trigger_conditions_attributes] = upserted_condition_attributes(trigger, args["conditions"])
        elsif args["trigger_type"].present? || args["configuration"].present?
          attributes[:trigger_conditions_attributes] = updated_condition_attributes(trigger, args)
        end

        trigger.update!(attributes)
        trigger.trigger_conditions.reload

        <<~TEXT.strip
          ## Trigger Updated

          - **ID:** #{trigger.id}
          - **Name:** #{trigger.name}
          - **Status:** #{trigger.status}
          - **Max Sessions/Minute:** #{trigger.max_sessions_per_minute || '(no limit)'}

          #{condition_detail(trigger)}
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

      # The flat pair and the array describe the same thing two different ways, so
      # accepting both would mean guessing which one the caller meant.
      def reject_conflicting_condition_args!(args)
        return if args["conditions"].blank?
        return if args["trigger_type"].blank? && args["configuration"].blank?

        raise ToolError, '"conditions" cannot be combined with the top-level "trigger_type"/' \
                         '"configuration" pair — send one or the other.'
      end

      def created_condition_attributes(args)
        return [ { condition_type: args["trigger_type"], configuration: args["configuration"] || {} } ] if args["conditions"].blank?

        args["conditions"].map.with_index do |condition, index|
          type = condition["trigger_type"].presence
          raise ToolError, "conditions[#{index}] is missing \"trigger_type\"." if type.nil?

          { condition_type: type, configuration: condition["configuration"] || {} }
        end
      end

      # Fold an incoming conditions array into nested attributes, as an upsert.
      #
      # An element with an id edits that row, an element without one appends, and a
      # row the array never mentions is simply not in the result — so
      # accepts_nested_attributes_for leaves it alone. Removal is explicit
      # (`remove: true`) because omission has to stay safe: these rows hold the Slack
      # poller's only copy of its cursors.
      #
      # `configuration` is likewise assigned only when the caller sent one. Omitting
      # it means "leave this condition's configuration as it is", which keeps the
      # narrowest possible write — the same reason preserve_slack_poll_state merges
      # on absence rather than on a sentinel.
      def upserted_condition_attributes(trigger, conditions)
        existing_ids = trigger.trigger_conditions.map(&:id)

        conditions.map.with_index do |condition, index|
          id = condition["id"].presence&.to_i

          if id && !existing_ids.include?(id)
            raise ToolError, "conditions[#{index}] references condition #{id}, which does not belong " \
                             "to trigger #{trigger.id} (its conditions are: #{existing_ids.join(', ')})."
          end

          if condition["remove"]
            raise ToolError, "conditions[#{index}] sets \"remove\" without an \"id\"." if id.nil?
            next { id: id, _destroy: true }
          end

          type = condition["trigger_type"].presence
          if id.nil? && type.nil?
            raise ToolError, "conditions[#{index}] is missing \"trigger_type\" — it is required when " \
                             "adding a condition (send an \"id\" to update an existing one)."
          end

          attributes = {}
          attributes[:id] = id if id
          attributes[:condition_type] = type if type
          attributes[:configuration] = condition["configuration"] if condition.key?("configuration")
          attributes
        end
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

      # Condition ids and descriptions, so a caller can address a specific condition
      # on its next update without a round trip through search_triggers.
      def condition_detail(trigger)
        conditions = trigger.trigger_conditions.to_a
        return "" if conditions.empty?

        lines = [ "### Conditions" ]
        conditions.each { |condition| lines << "- **[id #{condition.id}] #{condition.condition_type}** — #{condition.description}" }
        lines.join("\n")
      end
    end
  end
end
