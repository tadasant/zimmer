# frozen_string_literal: true

module Mcp
  module Tools
    # Mirrors POST/PATCH/DELETE /api/v1/triggers, POST /api/v1/triggers/:id/toggle
    # and POST /api/v1/triggers/:id/invoke.
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
      ACTIONS = %w[create update delete toggle invoke].freeze
      # `ao_event` is creatable here, and it has to be: the /triggers form has
      # always offered it, so leaving it out made the web UI strictly more capable
      # than the MCP surface — a human could wire a Zimmer event to a trigger and an
      # agent session could not. The wake-up tools
      # (wake_me_up_when_session_changes_state) remain the right way to create a
      # SESSION-scoped one-shot wake; what this opens up is the broadcast form, and
      # the account events, which no wake tool covers.
      TRIGGER_TYPES = %w[slack schedule ao_event github_label github_issue system_event].freeze

      # The cap applied to a BROADCAST SESSION ao_event trigger created here when the
      # caller names none.
      #
      # A broadcast session event fires on every autonomous session's transition, so
      # an uncapped one spawns a session per transition indefinitely. Loop prevention
      # stops a trigger firing on its OWN sessions, but it is per-trigger: two such
      # triggers — one on needs_input, one on archived — feed each other with nothing
      # bounding either. Opening ao_event creation to agents is what makes that
      # reachable, so the default closes it. A caller who wants no cap can still send
      # max_sessions_per_minute explicitly.
      #
      # Deliberately NOT applied to account events: `account_needs_reauth` is already
      # bounded at source (one event per account per ClaudeAccount::REAUTH_ALERT_THROTTLE),
      # and a burst cap there could only drop alerts during the mass-failure it exists
      # to report.
      BROADCAST_SESSION_AO_EVENT_BURST_CAP = 5

      # Derived from the model, not re-declared, so the tool cannot drift behind
      # it. `failed` is subtracted because it is Zimmer's to set — ScheduleTriggerJob
      # and AoEventTriggerJob park a one-shot trigger there when its fire raises,
      # alongside the failed_at and last_error the UI renders. A caller that could name it here would
      # fabricate a failure with neither, and the trigger page would show a "fire
      # failed" panel for a fire that never happened. search_triggers carries the
      # full list, because filtering on `failed` is exactly the point there.
      STATUSES = (Trigger::STATUSES - %w[failed]).freeze

      tool_name "action_trigger"

      description <<~DESC
        Create, update, delete, toggle, or invoke automation triggers.

        **Actions:**
        - **create**: Create a new trigger (requires name, trigger_type, agent_root_name, prompt_template)
        - **update**: Update an existing trigger (requires "id")
        - **delete**: Delete a trigger (requires "id")
        - **toggle**: Enable/disable a trigger (requires "id"). A trigger in the `failed` status —
          parked there because a one-shot fire raised — toggles back to enabled, which clears the
          failure and re-arms it. A one-time schedule then fires within a minute. A session-scoped
          `ao_event` wake is weaker: it only fires when the session it watches transitions AGAIN,
          so if that session has already finished, re-arming delivers nothing and the session
          waiting on it must be resumed directly.
        - **invoke**: Fire a trigger NOW (requires "id"), without waiting for a condition to match —
          the same thing the Invoke button on the trigger page does. The session is linked to the
          trigger and counts toward its fire counter, and a reuse trigger follows up its target
          session rather than spawning a new one. Pass `variables` to fill in the template's
          `{{...}}` placeholders. Status is not consulted: a `disabled` trigger can still be
          invoked, which is how you test one before enabling it. The trigger's burst cap still
          applies — over it, the fire produces a burst-notice session or nothing at all, and the
          result says which.

        **Conditions (OR semantics):** a trigger fires when ANY of its conditions matches.
        Two ways to say so:
        - **One condition:** send `trigger_type` + `configuration` at the top level, as always.
        - **Several conditions:** send `conditions` — an array of `{trigger_type, configuration}`
          objects. Use this for a trigger that must fire on more than one thing, e.g. a Slack
          passive listener carrying both `passive_listen_thread` and `passive_listen_channel`.
          `conditions` and the flat `trigger_type`/`configuration` pair are mutually exclusive.

        On **update**, `conditions` is an upsert, not a replacement:
        - An element with an `id` updates that condition. Omit `configuration` to leave it
          untouched. Sending one REPLACES the condition's user-facing keys, so send every key
          you want to keep — notably `event_type`, which defaults to `new_message` (fire on
          everything) if you drop it. Keys a POLLER owns survive an update that omits them: the
          Slack cursors (plus `allowed_user_ids`), and the GitHub ones (`seen_items`,
          `seen_missing_counts`, `last_issue_at`, `seen_issue_keys`). The GitHub keys are the
          one exception with a condition attached — an edit that changes `repos`, `labels` or
          `target` deliberately DROPS them to re-baseline the condition, since widening what is
          watched would otherwise stampede a session for everything already matching.
        - An element without an `id` adds a new condition.
        - An existing condition the array does not mention is **left alone**. To delete one,
          send `{"id": 123, "remove": true}`.
        Use search_triggers to read a trigger's existing condition ids.

        **Trigger types:**
        - **slack**: Triggered by Slack events (requires configuration with channel_id)
        - **schedule**: Triggered on a recurring or one-time schedule
        - **ao_event**: Triggered by an internal Zimmer event (requires configuration with event_name)
        - **github_label**: Triggered when a watched label is ADDED to a PR/issue in a watched repo
        - **github_issue**: Triggered when a new issue is opened in a watched repo
        - **system_event**: Triggered when the DEPLOYMENT changes state, not a session. Broadcast and recurring, and every event is edge-fired — it fires on the deployment ENTERING the state, never once per check while it stays there. Two events: `{"event_name": "quota_available"}`, the account pool going from serving nothing to serving something, which is what wakes quota-parked spot sessions (there is normally exactly one such trigger and it is seeded by a migration — create another only deliberately); and `{"event_name": "no_sessions_in_progress"}`, the deployment having had nothing to do for 5 continuous minutes — nothing `running`, nothing spot-classified `waiting`, nothing parked on an auth outage, and an account pool that can serve. Use it for work that should fill a fleet that has run out of things to do; it deliberately stays quiet while the spot queue has anything in it or the pool is empty, so it means "there is nobody left to run", not "the gate is holding things". It fires at most once per quiet stretch AND at most once an hour, because the session it spawns would otherwise re-qualify it by running. Pair it with `skip_if_pending_session` so a session it already spawned answers the next quiet stretch.

        **Pending-session dedup:**
        - **skip_if_pending_session**: when true, the trigger creates NOTHING while a session it
          already spawned is still `waiting` or `running` — the fire is treated as already covered
          by that session. `needs_input`, `archived` and `failed` predecessors do not block a fire.
          Default false. Use it for a trigger whose every session carries the same intent (a fleet
          wake, a "process the backlog" sweep), where a second session is duplicated work rather
          than more of it. This bounds the BACKLOG; max_sessions_per_minute bounds the RATE, and
          neither substitutes for the other.

        **Burst control:**
        - **max_sessions_per_minute**: caps how many sessions the trigger may spawn per minute.
          Omit (or send null) for no limit — that is the default and how every trigger behaved
          before this setting existed. When the cap is exceeded, the trigger spawns a single
          burst-notice session linking the sessions it already spawned, then stops spawning
          until the burst subsides. Events that arrive during the burst are dropped.

        **Scheduling class:**
        - **scheduling_class**: `priority` (sessions start whenever they are ready) or `spot` (they
          start only while a Claude Code account is under both quota targets and a session slot is
          free, and otherwise wait and start later — deferred, never cancelled). Omit (or send null) to take
          the default for the trigger's condition type: slack is priority, and github_issue,
          github_label, schedule and ao_event are spot. Setting it applies to sessions the trigger
          spawns from now on; ones it already spawned keep the class they started with.
        - **precedence**: where the sessions this trigger spawns sit in the spot queue. Higher is
          handled sooner, on an ABSOLUTE scale — 100000 comes before 50 — not a 1..N rank, and
          nothing renumbers it. Omit (or send null) to predefine nothing. Like the class, it
          applies to sessions spawned from now on.

        **Schedule configuration:**
        - **Recurring**: `{"interval": 2, "unit": "hours", "timezone": "UTC"}` — fires every N units
        - **One-time**: `{"scheduled_at": "2026-04-15T14:30:00", "timezone": "America/New_York"}` — fires once at the specified datetime (ISO 8601), then auto-disables

        **Zimmer event configuration:**
        - `{"event_name": "session_needs_input"}` — also `session_failed`, `session_archived`. These are
          BROADCAST: they fire for every autonomous session that transitions, so the trigger they hang
          off spawns a session each time. Add `{"watched_session_id": 1234}` to narrow one to a single
          session — but to wake yourself on a session you are waiting for, use
          wake_me_up_when_session_changes_state instead, which creates the one-shot wake AND puts this
          session to sleep.
        - `{"event_name": "account_needs_reauth"}` — fires when a runtime account in the pool can no
          longer refresh its OAuth token and drops out of rotation until a human re-authenticates it.
          Its subject is an ACCOUNT, not a session, so `watched_session_id` is rejected. Suppressed to
          at most one fire per account per 12 hours (ClaudeAccount::REAUTH_ALERT_THROTTLE), released
          when a human completes a login for that account.

        **GitHub configuration:**
        - **github_label**: `{"repos": ["owner/a", "owner/b"], "target": "pull_request", "labels": ["ready to merge"]}`
          — `target` is `pull_request` (default) or `issue`; any ONE of `labels` firing is enough.
        - **github_issue**: `{"repos": ["owner/a"], "exclude_labels": ["hold issue work gate"]}`
          — `exclude_labels` is optional: an issue opened carrying ANY of those labels does not fire
          the condition. It is an author-side opt-out, and it is applied by the search, so the label
          must be on the issue when GitHub indexes it — in practice, at creation
          (`gh issue create --label "hold issue work gate"`). The poll runs every minute, so a label
          added after the fact can lose the race and the issue fires anyway.

        GitHub triggers fire on the label being *added*, not on it merely being present: an item
        that already carries the label when the trigger is created is absorbed into a baseline on
        the first poll and does NOT fire retroactively. Removing and re-adding the label fires again.
        Editing `repos`/`labels`/`target` re-baselines the condition, so widening the watch does not
        stampede sessions for everything already labelled. Editing `exclude_labels` does NOT
        re-baseline — an exclusion only narrows the search, so it keeps the condition's live cursor.
        Omitting `exclude_labels` from an update of a condition that HAS one is rejected rather than
        silently obeyed, since it would re-arm the gate; send `[]` to clear it deliberately.

        Triggered sessions receive the repo, number, URL, title, author, body and labels — via the
        `{{repo}}`, `{{number}}`, `{{link}}`, `{{title}}`, `{{author}}`, `{{text}}`, `{{labels}}` and
        `{{event}}` template variables, or appended as a context block if the template names none.

        Use search_triggers first to see available triggers and Slack channels.
      DESC

      input_schema({
        type: "object",
        properties: {
          action: { type: "string", enum: ACTIONS, description: "Action to perform." },
          id: { type: "number", description: "Trigger ID. Required for update, delete, toggle, invoke." },
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
          skip_if_pending_session: {
            type: "boolean",
            description: "When true, the trigger spawns nothing while a session it already created is still " \
                         "waiting or running. Default false. Bounds the backlog of duplicate-intent sessions; " \
                         "needs_input/archived/failed predecessors never block a fire."
          },
          max_sessions_per_minute: {
            type: [ "number", "null" ],
            minimum: 1,
            description: "Cap on sessions this trigger may spawn per minute. Null (default) means no limit. " \
                         "Exceeding it spawns one burst-notice session and suppresses further spawns for the burst."
          },
          scheduling_class: {
            type: [ "string", "null" ],
            enum: SessionGenesis::CLASSES + [ nil ],
            description: "Spot/priority class for sessions this trigger spawns. Null (default) derives it " \
                         "from the trigger's condition type."
          },
          precedence: {
            type: [ "integer", "null" ],
            description: PrecedenceDocs::ACTION_TRIGGER
          },
          mcp_servers: {
            type: "array",
            items: { type: "string" },
            description: "MCP servers for triggered sessions."
          },
          variables: {
            type: "object",
            description: "For the \"invoke\" action: values for the prompt template's placeholders. " \
                         "Recognized keys are #{Trigger::USER_INPUT_VARIABLES.join(', ')} — anything else is " \
                         "ignored, and a placeholder the template names but this omits interpolates as an " \
                         "empty string. {{time}} and {{date}} fill themselves in."
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
        when "invoke" then invoke(args)
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
          skip_if_pending_session: args.fetch("skip_if_pending_session", false),
          max_sessions_per_minute: max_sessions_per_minute_for(args),
          scheduling_class: args["scheduling_class"].presence,
          precedence: trigger_precedence(args),
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
          - **Skip While Pending:** #{trigger.skip_if_pending_session ? 'yes' : 'no'}
          - **Max Sessions/Minute:** #{trigger.max_sessions_per_minute || '(no limit)'}
          - **Scheduling Class:** #{scheduling_class_summary(trigger)}
          - **Precedence:** #{precedence_summary(trigger)}

          #{condition_detail(trigger)}
        TEXT
      end

      # An explicit value always wins, including an explicit null for "no cap".
      def max_sessions_per_minute_for(args)
        explicit = args["max_sessions_per_minute"].presence
        return explicit if explicit
        return nil unless args.key?("conditions") || args["trigger_type"] == "ao_event"

        broadcast = created_condition_attributes(args).any? do |attrs|
          next false unless attrs[:condition_type] == "ao_event"

          config = attrs[:configuration] || {}
          TriggerCondition::SESSION_AO_EVENT_NAMES.include?(config["event_name"]) &&
            config["watched_session_id"].blank?
        end

        broadcast ? BROADCAST_SESSION_AO_EVENT_BURST_CAP : nil
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
        attributes[:skip_if_pending_session] = args["skip_if_pending_session"] if args.key?("skip_if_pending_session")
        # An explicit null clears the cap (back to unbounded); an omitted key means "no opinion".
        attributes[:max_sessions_per_minute] = args["max_sessions_per_minute"].presence if args.key?("max_sessions_per_minute")
        # Same omitted-vs-null rule: an explicit null returns the trigger to the
        # class its conditions derive, an omitted key leaves the choice alone.
        attributes[:scheduling_class] = args["scheduling_class"].presence if args.key?("scheduling_class")
        # And again for the predefined rank: null clears it, an omitted key leaves it.
        attributes[:precedence] = trigger_precedence(args) if args.key?("precedence")
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
          - **Skip While Pending:** #{trigger.skip_if_pending_session ? 'yes' : 'no'}
          - **Max Sessions/Minute:** #{trigger.max_sessions_per_minute || '(no limit)'}
          - **Scheduling Class:** #{scheduling_class_summary(trigger)}
          - **Precedence:** #{precedence_summary(trigger)}

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

      # Fire the trigger now. Triggers::ManualFire is the same service the Invoke
      # button calls, so the session is linked to the trigger, counts toward its
      # fire counter and honours the burst cap identically — the genesis is the
      # only thing that differs, and it differs because the caller does.
      def invoke(args)
        trigger = find_trigger(args["id"], "invoke")
        enforce_allowed_root!(trigger.agent_root_name)

        variables = args["variables"].is_a?(Hash) ? args["variables"] : {}
        result = Triggers::ManualFire.call(trigger: trigger, genesis: SessionGenesis::API, variables: variables)

        session = result.session

        # `not_reusable` can still hand back the target session it declined to
        # reuse, so "did a session come back" is the wrong question here — "did
        # anything fire" is.
        unless result.fired? || result.outcome == :burst_notice
          lines = [ "## Trigger Not Fired", "", result.message ]
          lines << "\nTarget session: #{session.id} — #{session_url(session)}" if session
          return lines.join("\n")
        end

        <<~TEXT.strip
          #{result.fired? ? '## Trigger Invoked' : '## Trigger Invoked — Burst Notice'}

          - **Trigger:** #{trigger.id} — #{trigger.name}
          - **Session:** #{session.id}#{" (#{session.slug})" if session.slug.present?}
          - **Session Status:** #{session.status}
          - **Session URL:** #{session_url(session)}
          - **Sessions Created (lifetime):** #{trigger.reload.sessions_created_count}

          #{result.message}
        TEXT
      rescue AgentRootsConfig::AgentRootNotFoundError => e
        # Every other failure mode of this tool reaches the caller as a readable
        # tool error it can act on; an unresolvable agent root must too, rather
        # than escaping as a protocol-level error the model never sees.
        raise ToolError, "Invalid agent_root: #{e.message}"
      end

      # The flat pair and the array describe the same thing two different ways, so
      # accepting both would mean guessing which one the caller meant.
      def reject_conflicting_condition_args!(args)
        if args["conditions"].is_a?(Array) && args["conditions"].empty?
          raise ToolError, '"conditions" was sent empty. Send at least one condition, or omit the key ' \
                           "to leave the trigger's conditions alone."
        end

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
          reject_unknown_type!(type, index)

          if condition["id"].present? || condition["remove"].present?
            raise ToolError, "conditions[#{index}] uses \"id\"/\"remove\", which only apply when " \
                             "updating an existing trigger."
          end

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
        existing = trigger.trigger_conditions.to_a
        existing_ids = existing.map(&:id)
        reject_duplicate_ids!(conditions)

        conditions.map.with_index do |condition, index|
          id = condition["id"].presence&.to_i
          target = existing.find { |c| c.id == id } if id

          if id && target.nil?
            raise ToolError, "conditions[#{index}] references condition #{id}, which does not belong " \
                             "to trigger #{trigger.id} (its conditions are: #{existing_ids.join(', ')})."
          end

          if ActiveModel::Type::Boolean.new.cast(condition["remove"])
            raise ToolError, "conditions[#{index}] sets \"remove\" without an \"id\"." if id.nil?
            next { id: id, _destroy: true }
          end

          type = condition["trigger_type"].presence
          if id.nil? && type.nil?
            raise ToolError, "conditions[#{index}] is missing \"trigger_type\" — it is required when " \
                             "adding a condition (send an \"id\" to update an existing one)."
          end
          reject_unknown_type!(type, index) if type

          if id.nil?
            reject_duplicate_condition!(trigger, existing, type, condition["configuration"], index)
            if condition["configuration"].blank?
              raise ToolError, "conditions[#{index}] is missing \"configuration\" — adding a condition " \
                               "needs one (omitting it is only meaningful when updating by \"id\")."
            end
          end

          reject_widening_configuration!(target, condition, index) if target && condition.key?("configuration")

          attributes = {}
          attributes[:id] = id if id
          attributes[:condition_type] = type if type
          attributes[:configuration] = condition["configuration"] if condition.key?("configuration")
          attributes
        end
      end

      # Two elements naming the same condition is always a mistake, and a silent one:
      # accepts_nested_attributes_for assigns the row twice and keeps the LAST
      # assignment, so the first element's configuration vanishes — and a `remove`
      # paired with an edit destroys the row (cursors included) whichever order they
      # arrive in, because marking for destruction is never undone.
      def reject_duplicate_ids!(conditions)
        ids = conditions.filter_map { |condition| condition["id"].presence&.to_i }
        duplicated = ids.tally.select { |_id, count| count > 1 }.keys
        return if duplicated.empty?

        raise ToolError, "\"conditions\" names condition #{duplicated.join(', ')} more than once. " \
                         "Send one element per condition."
      end

      def reject_unknown_type!(type, index)
        return if TRIGGER_TYPES.include?(type)

        raise ToolError, "conditions[#{index}] has an unknown trigger_type \"#{type}\". " \
                         "Valid types: #{TRIGGER_TYPES.join(', ')}."
      end

      # An element with no id ADDS a condition, so a caller that reads a trigger and
      # sends back what it believes is the desired final state — without echoing the
      # ids — would append duplicates of the conditions that are already there rather
      # than editing them. The trigger would then match the same message twice and
      # spawn two sessions for it, and the duplicates would be un-baselined while the
      # originals kept the poller's cursors. That is the single most likely way to
      # misuse an upsert, so it is refused rather than obeyed.
      def reject_duplicate_condition!(trigger, existing, type, configuration, index)
        clash = existing.find { |c| condition_identity(c.condition_type, c.configuration) == condition_identity(type, configuration) }
        return if clash.nil?

        raise ToolError, "conditions[#{index}] would add a second #{type} condition identical to " \
                         "condition #{clash.id} on trigger #{trigger.id} (#{clash.description}). " \
                         "Send \"id\": #{clash.id} to edit that one, or \"remove\": true first."
      end

      # What a condition listens to, ignoring bookkeeping and display-only fields. A
      # Slack condition is identified by the trio that decides which messages reach
      # it; anything else by its configuration minus the keys its poller owns.
      def condition_identity(condition_type, configuration)
        config = configuration || {}

        if condition_type == "slack"
          [ condition_type, config["event_type"].presence || "new_message",
            config["channel_id"].presence, config["thread_ts"].presence ]
        else
          [ condition_type, config.except(*TriggerCondition::GITHUB_POLL_STATE_KEYS) ]
        end
      end

      # `configuration` replaces the user-facing keys, so a key the caller forgot is a
      # key the condition loses. For most keys that is a visible edit; for these two it
      # is a silent WIDENING — the condition quietly starts firing on more than it did,
      # with nothing in the response to say so. Poller state is merged back by
      # preserve_slack_poll_state / preserve_github_poll_state, but neither of these is
      # poller state, so nothing else catches it.
      def reject_widening_configuration!(target, condition, index)
        incoming = condition["configuration"]
        return unless incoming.is_a?(Hash)

        case target.condition_type
        when "slack" then reject_widening_slack_configuration!(target, incoming, index)
        when "ao_event" then reject_widening_ao_event_configuration!(target, incoming, index)
        when "github_issue" then reject_widening_github_issue_configuration!(target, incoming, index)
        end
      end

      # Dropping `watched_session_id` turns a one-shot wake on ONE session into a
      # broadcast that spawns a session on every autonomous session's transition —
      # the widest silent widening available here, and reachable now that ao_event
      # is creatable through this tool. It is also how the wake_me_up_when_session_
      # changes_state tool's own rows are shaped, so an ordinary-looking edit to one
      # of those would do it.
      def reject_widening_ao_event_configuration!(target, incoming, index)
        return unless target.session_scoped_ao_event?
        return if incoming["watched_session_id"].present?

        raise ToolError, "conditions[#{index}] omits \"watched_session_id\" from the configuration of " \
                         "condition #{target.id}, which currently watches session " \
                         "##{target.watched_session_id}. configuration replaces the condition's " \
                         "user-facing keys, so this would widen a one-shot wake into a broadcast that " \
                         "spawns a session on EVERY autonomous session transition. Send " \
                         "watched_session_id to keep it, or delete the condition and add a new one if " \
                         "a broadcast is really what you want."
      end

      # Dropping `event_type` is not a small mistake: the reader defaults to
      # "new_message", so a passive or @mention condition would silently start firing on
      # EVERY message in its channel.
      def reject_widening_slack_configuration!(target, incoming, index)
        return if target.event_type == "new_message"
        return if incoming["event_type"].present?

        raise ToolError, "conditions[#{index}] omits \"event_type\" from the configuration of " \
                         "condition #{target.id}, which is currently \"#{target.event_type}\". " \
                         "configuration replaces the condition's user-facing keys, so this would " \
                         "reset it to \"new_message\" and fire on every message. Re-send event_type."
      end

      # Dropping `exclude_labels` re-arms the gate for every issue that was opting out of
      # it. Keyed on the KEY's absence rather than its emptiness, so a caller that means
      # to remove the exclusion still can — by sending an explicit empty array.
      def reject_widening_github_issue_configuration!(target, incoming, index)
        return if target.github_exclude_labels.empty?
        return if incoming.key?("exclude_labels")

        excluded = target.github_exclude_labels.join(", ")
        raise ToolError, "conditions[#{index}] omits \"exclude_labels\" from the configuration of " \
                         "condition #{target.id}, which currently excludes: #{excluded}. " \
                         "configuration replaces the condition's user-facing keys, so this would " \
                         "drop the exclusion and fire on every new issue again. Re-send " \
                         "exclude_labels, or send it as [] to clear it deliberately."
      end

      # Resolve which existing condition the flat trigger_type/configuration pair
      # is meant to modify: the one of the requested type, or the sole condition
      # when no type was given. Without an id the nested-attributes writer would
      # append a second condition rather than edit the one the caller means.
      def updated_condition_attributes(trigger, args)
        existing = trigger.trigger_conditions.to_a
        target = if args["trigger_type"].present?
          matching = existing.select { |c| c.condition_type == args["trigger_type"] }
          # The flat contract names a TYPE, which stopped being unique the moment a
          # trigger could carry two conditions of one type (two Slack passive
          # listeners, say). Picking the first would rewrite whichever row the
          # database happened to return.
          if matching.size > 1
            raise ToolError, "Trigger #{trigger.id} has #{matching.size} #{args['trigger_type']} conditions " \
                             "(ids: #{matching.map(&:id).join(', ')}), so \"trigger_type\" does not identify " \
                             "one. Use the \"conditions\" array and name the condition by id."
          end
          matching.first
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

      # The predefined rank, or nil when the caller cleared it / said nothing.
      def trigger_precedence(args)
        value = args["precedence"]
        return nil if value.nil?

        unless value.is_a?(Integer) || value.to_s.match?(/\A-?\d+\z/)
          raise ToolError, "precedence must be an integer (got #{value.inspect})"
        end

        value = value.to_i
        unless value.between?(SessionPrecedence::MIN, SessionPrecedence::MAX)
          raise ToolError, "precedence must be between #{SessionPrecedence::MIN} and #{SessionPrecedence::MAX}"
        end

        value
      end

      def precedence_summary(trigger)
        return "(none predefined)" if trigger.precedence.nil?

        trigger.precedence.to_s
      end

      # "spot" / "priority", and whether that came from the trigger or from the
      # class its condition type derives — the same two facts the trigger page
      # shows, so an agent reading this and a human reading the web UI see the
      # same thing.
      def scheduling_class_summary(trigger)
        source = trigger.scheduling_class.present? ? "set on this trigger" : "default for its conditions"
        "#{trigger.effective_scheduling_class} (#{source})"
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
