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
      TRIGGER_TYPES = TriggerCondition::CONDITION_TYPES
      # Referenced, not re-declared: a re-declared copy of a model constant is the
      # drift vector that leaves an agent unable to name a status a human can see.
      # `failed` is Zimmer's to set — a one-shot fire raised and the trigger was
      # parked instead of destroyed. Both wake shapes park there: a one-time
      # schedule (ScheduleTriggerJob) and a session-scoped ao_event
      # (AoEventTriggerJob). Filtering on it is how an agent finds wakes that
      # never happened.
      STATUSES = Trigger::STATUSES

      # The keys inside a condition's `configuration` that belong to a poller rather
      # than to the human who configured the trigger. Referenced from the model, not
      # re-listed: these are the same keys `preserve_slack_poll_state` and
      # `preserve_github_poll_state` restore when an incoming configuration omits
      # them, and that correspondence is what makes omitting them here safe.
      #
      # `allowed_user_ids` is subtracted because it only rides along in
      # SLACK_POLL_STATE_KEYS for a different reason — it is user-facing but the
      # form does not render it — so summarising it would hide a setting a human
      # chose. Every other user-facing list (`repos`, `labels`, `exclude_labels`)
      # is not poller state to begin with and is never touched.
      POLLER_OWNED_KEYS = (
        TriggerCondition::SLACK_POLL_STATE_KEYS + TriggerCondition::GITHUB_POLL_STATE_KEYS -
        %w[allowed_user_ids]
      ).freeze

      # Those maps grow without bound — a long-lived passive listener carries
      # hundreds of thread cursors, rewritten every minute by SlackTriggerPollerJob
      # — so serialising them cost ~15k tokens for a single trigger, which is what
      # made a fleet-wide audit unaffordable (#858).
      #
      # The budget is deliberately generous: an ordinary schedule, ao_event or
      # github_label configuration is a few hundred characters of JSON and is
      # rendered in full. Only a configuration over the budget is summarised, and
      # then only its poller-owned collections that are actually high-cardinality.
      CONFIGURATION_RENDER_BUDGET = 2_000
      COLLECTION_SUMMARY_THRESHOLD = 10

      # A sample entry stands in for a collection whose entries carry no timestamp.
      # It is one line of an agent's context window, not a value to read back.
      MAX_SAMPLE_LENGTH = 80

      # Slack cursors are message timestamps ("1788455710.688659"), on their own or
      # as the tail of a thread key ("C0A6BF8T45R:1788455710.688659"). The newest is
      # the one value a caller reading a cursor map plausibly wants, so name it.
      SLACK_TIMESTAMP_TAIL = /(\d{9,11}\.\d{1,6})\z/

      tool_name "search_triggers"

      description <<~DESC
        Search and list automation triggers.

        **Modes:**
        - **Get by ID**: Provide an id to get trigger details with recent sessions. A condition's
          `configuration` is rendered in full unless it is large, in which case its high-cardinality
          poller state (Slack thread cursors and the like) is left out of the JSON and summarised
          below it as a count plus its most recent entry. Send that JSON back through action_trigger
          as-is and the omitted cursors are preserved; `GET /api/v1/triggers/:id` serves them.
        - **List**: List triggers with optional filters (trigger_type, status, pagination). Each row
          names the trigger's MCP servers, so "which triggers reference server X?" is one call.
        - **Include channels**: Set include_channels=true to also list available Slack channels (useful when creating Slack triggers)

        **Filterable trigger types:**
        - **slack**: Triggers fired by Slack messages
        - **schedule**: Recurring or one-time scheduled triggers
        - **ao_event**: Triggers fired by internal Zimmer state transitions (e.g., a session entering needs_input or failed). These back the `wake_me_up_when_session_changes_state` tool.
        - **github_label**: Triggers fired when a watched label is added to a PR/issue in a watched repo
        - **github_issue**: Triggers fired when a new issue is opened in a watched repo, unless the
          issue carries one of the condition's `exclude_labels`

        A trigger may have multiple conditions (OR semantics) — filtering by trigger_type returns triggers that have at least one condition of that type. Fetching a trigger by id lists each condition with its own id, which is what action_trigger's `conditions` array uses to address one of them.

        **Use cases:**
        - View configured automations (scheduled tasks, Slack integrations, GitHub watchers, ao_event waiters)
        - Check trigger status and execution history
        - Find wakes that never fired: filter status=failed (a fire raised; the trigger was parked, not deleted, and can be re-armed with action_trigger toggle)
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
          "- **Skip While Pending:** #{skip_if_pending_summary(trigger)}",
          "- **Max Sessions/Minute:** #{burst_limit_summary(trigger)}",
          "- **Coalescing Window:** #{coalesce_window_summary(trigger)}",
          "- **MCP Servers:** #{mcp_servers_summary(trigger)}",
          "- **Skills / Hooks / Plugins:** #{catalog_lists_summary(trigger)}"
        ]
        # Only meaningful on a reuse trigger — the model clears both otherwise —
        # and worth reading before changing either, because with enqueue_messages
        # off a fire onto a busy session is dropped without a trace.
        if trigger.reuse_session
          lines << "- **Enqueue Messages:** #{trigger.enqueue_messages ? 'Yes' : 'No — a fire onto a busy session is dropped'}"
          lines << "- **Resuscitate Archived:** #{trigger.resuscitate_archived ? 'Yes' : 'No'}"
        end
        lines << "- **Goal:** #{trigger.goal}" if trigger.goal.present?
        if trigger.failed?
          lines << "- **Failed At:** #{trigger.failed_at&.iso8601 || 'unknown'}"
          lines << "- **Last Error:** #{trigger.last_error.presence || '(not recorded)'}"
          lines << "- **Re-arm:** call action_trigger with action=toggle to clear the failure and put it back in service"
        end
        missed = missed_fires_summary(trigger)
        lines << missed if missed
        lines << "- **Sessions Created:** #{trigger.sessions_created_count}"
        lines << "- **Last Triggered:** #{trigger.last_triggered_at.iso8601}" if trigger.last_triggered_at
        lines.push("", "### Prompt Template", "```", trigger.prompt_template, "```")

        conditions = trigger.trigger_conditions.to_a
        if conditions.any?
          lines.push("", "### Conditions")
          conditions.each do |condition|
            # The id is what action_trigger's `conditions` array addresses when
            # editing one condition of a multi-condition trigger.
            lines << "- **[id #{condition.id}] #{condition.condition_type}** — #{condition.description}"
            next if condition.configuration.blank?

            rendered, summaries = render_configuration(condition.configuration)
            lines << "  ```json"
            rendered.split("\n").each { |line| lines << "  #{line}" }
            lines << "  ```"
            next if summaries.empty?

            lines << "  *Poller state, summarised and left out of the JSON above — a key that is absent " \
                     "is restored intact if this configuration is sent back through action_trigger, " \
                     "where a summary standing in for it would overwrite a live cursor:*"
            summaries.each { |key, summary| lines << "  - `#{key}`: #{summary}" }
            lines << "  *`GET /api/v1/triggers/#{trigger.id}` returns the configuration in full.*"
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
                     "**Sessions:** #{trigger.sessions_created_count} | " \
                     "**Max Sessions/Minute:** #{burst_limit_summary(trigger)} | " \
                     "**Scheduling Class:** #{scheduling_class_summary(trigger)} | " \
                     "**MCP Servers:** #{mcp_servers_summary(trigger)}"
            if trigger.missing_fires?
              lines << "- ⚠️ **#{trigger.missed_fire_count} missed fire(s)** — coalesced into an undelivered " \
                       "prompt the re-used session has not consumed."
            end
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
          .for_trigger(trigger.id)
          .order(created_at: :desc)
          .limit(10)
          .to_a
      end

      # Rendered in BOTH modes. A catalog rename audit asks one question of the
      # whole fleet — which triggers reference MCP server X — and the list is the
      # only view built for scanning many triggers, so leaving this out of it made
      # the answer cost one by-id call per trigger (#858).
      def mcp_servers_summary(trigger)
        trigger.mcp_servers.presence&.join(", ") || "(none)"
      end

      # The by-id view only: what a trigger equips the sessions it spawns with.
      # One line rather than three, because this view is already budgeted (#858).
      # An empty list reads as "(agent root defaults)" and not "(none)" because
      # that is what Session.create_from_agent_root! does with it.
      def catalog_lists_summary(trigger)
        %i[catalog_skills catalog_hooks catalog_plugins].map do |attribute|
          list = trigger.public_send(attribute).presence
          "#{attribute.to_s.delete_prefix('catalog_')}: #{list ? list.join(', ') : '(agent root defaults)'}"
        end.join(" | ")
      end

      # Returns [rendered_json, summaries]. A configuration inside the budget is
      # rendered whole; over it, the poller-owned collections that are actually
      # high-cardinality are LEFT OUT of the JSON and described in `summaries`
      # instead, keyed by the key they replace.
      #
      # Left out rather than replaced in place, because the commonest way to misuse
      # action_trigger is to read a configuration and send back what you believe is
      # the desired final state. A summary sitting under its real key would be
      # written straight over the live cursor map; an absent key is merged back by
      # the model's preserve_*_poll_state instead.
      def render_configuration(configuration)
        summaries = configuration_summaries(configuration)
        return [ JSON.pretty_generate(configuration), summaries ] if summaries.empty?

        [ JSON.pretty_generate(configuration.except(*summaries.keys)), summaries ]
      end

      def configuration_summaries(configuration)
        return {} if configuration.to_json.length <= CONFIGURATION_RENDER_BUDGET

        configuration
          .select { |key, value| summarise_collection?(key, value) }
          .transform_values { |value| collection_summary(value) }
      end

      def summarise_collection?(key, value)
        return false unless POLLER_OWNED_KEYS.include?(key.to_s)

        (value.is_a?(Hash) || value.is_a?(Array)) && value.size > COLLECTION_SUMMARY_THRESHOLD
      end

      # The shape of the thing, not the thing: how many entries it holds and which
      # one is newest. The exact values are poller bookkeeping and are stale the
      # moment they are read; the REST API still serves them in full.
      def collection_summary(value)
        entries = value.is_a?(Hash) ? value.values : value.to_a
        newest = entries.grep(SLACK_TIMESTAMP_TAIL).max_by { |entry| entry[SLACK_TIMESTAMP_TAIL, 1].to_f }
        return "#{value.size} entries, most recent #{newest}" if newest

        sample = value.is_a?(Hash) ? "#{value.keys.first}: #{value.values.first}" : value.first
        "#{value.size} entries, e.g. #{sample.to_s.truncate(MAX_SAMPLE_LENGTH)}"
      end

      def condition_types_summary(trigger)
        types = trigger.trigger_conditions.map(&:condition_type).uniq
        types.any? ? types.join(", ") : "(none)"
      end

      # "spot" / "priority", and whether that came from the trigger or from the
      # class its condition type derives — the same two facts the trigger page
      # shows, so an agent reading this and a human reading the web UI see the
      # same thing.
      def scheduling_class_summary(trigger)
        source = trigger.scheduling_class.present? ? "set on this trigger" : "default for its conditions"
        "#{trigger.effective_scheduling_class} (#{source})"
      end

      # Whether the trigger skips a fire while one of its own sessions is still
      # pending — and, when it is, WHICH session. Same reasoning as the burst
      # marker below: this is a state in which the trigger spawns nothing, so a
      # caller wondering why it looks dead has to be able to see it here.
      def skip_if_pending_summary(trigger)
        return "No" if !trigger.skip_if_pending_session

        # A reuse trigger never reaches the spawn path this setting guards, so
        # saying anything about what "the next fire" will do would be a lie. Say
        # it is inert and name the control that actually applies instead.
        if trigger.skip_if_pending_session_inert?
          return "Yes — but INERT while this trigger has a live session to re-use: a re-use fire never " \
                 "reaches the spawn path this setting guards. It applies again on a fire that has to " \
                 "spawn (no target yet, or the target died). Duplicate prompts into the re-used session " \
                 "are bounded by fire coalescing, which needs no opt-in."
        end

        pending = trigger.pending_intent_session
        return "Yes (nothing pending — the next fire spawns)" if pending.nil?

        "Yes ⚠️ SKIPPING — session #{pending.id} (#{pending.status}) is still pending"
      end

      # The window inside which several Slack messages in one conversation count
      # as one event. Says where the number came from, because an inherited
      # default and a value someone typed read identically otherwise — and a
      # caller asking "why did one alert storm produce one session" needs to know
      # whether anyone chose that.
      def coalesce_window_summary(trigger)
        return "Off — every Slack message spawns its own session" unless trigger.coalesces_messages?

        source = trigger.coalesce_window_seconds.nil? ? "default" : "set on this trigger"
        return "#{trigger.effective_coalesce_window_seconds}s (#{source}) — INERT: no Slack condition on this trigger reads it" if trigger.coalesce_window_inert?

        "#{trigger.effective_coalesce_window_seconds}s (#{source}) — Slack messages in one channel this close " \
          "together are one event: one session, the rest folded into its prompt"
      end

      # Scheduled runs that did not happen. A trigger whose fires are being
      # coalesced looks completely healthy otherwise — `last_triggered_at`
      # advances on a coalesced fire exactly as on a delivered one — so without
      # this line an agent reading the trigger has no way to tell the two apart.
      def missed_fires_summary(trigger)
        return nil unless trigger.missing_fires?

        since = trigger.first_missed_fire_at&.iso8601 || "unknown"
        "- **Missed Fires:** ⚠️ #{trigger.missed_fire_count} consecutive fire(s) coalesced since #{since} — " \
        "the re-used session is still holding an undelivered prompt, so the scheduled work has not run. " \
        "It resumes on its own once that session takes a turn."
      end

      # The burst cap, plus a loud marker when the trigger is currently inside a
      # burst — that's the state in which it is spawning nothing at all, so a
      # caller wondering why the trigger looks dead needs to see it here.
      def burst_limit_summary(trigger)
        return "(no limit)" if trigger.max_sessions_per_minute.blank?

        summary = trigger.max_sessions_per_minute.to_s
        summary += " ⚠️ BURSTING — spawns suppressed until the burst subsides" if trigger.bursting?
        summary
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
