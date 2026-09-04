# frozen_string_literal: true

module Mcp
  module Tools
    # The write half of the fleet-scheduling surface — everything the spot gate
    # and backlog top-up cards on /inference can do, reachable by an agent.
    #
    # Follows ActionSession's dispatch shape: one `action` argument validated
    # against a constant, one private method per action.
    class ActionSpotPolicy < Tool
      tool_name "action_spot_policy"

      ACTIONS = %w[
        set_gating
        set_top_up
        promote_genesis
        demote_genesis
        reset_genesis_classes
      ].freeze

      # The three numbers FleetIdleMonitor fires on, as tool argument → column.
      # One list, so the schema, the dispatch and the echo cannot drift apart.
      TOP_UP_FIELDS = {
        "max_sessions_in_hand" => :fleet_idle_max_sessions,
        "idle_minutes" => :fleet_idle_threshold_minutes,
        "min_fire_interval_minutes" => :fleet_idle_min_fire_interval_minutes
      }.freeze

      description <<~DESC
        Change Zimmer's spot/priority scheduling policy. Read the current state first with `get_spot_policy`.

        **Actions:**
        - **set_gating**: Turn the spot gate on or off, set how much of each quota window is RESERVED
          for priority sessions, and set the ceiling on how many sessions run at once. Any of `enabled`,
          `five_hour_reserve_pct`, `weekly_reserve_pct` and `max_concurrent_sessions` may be given;
          omitted ones are left alone.

          The reserve is set as a PERCENTAGE and enforced in DOLLARS: Zimmer estimates what a full
          window is worth in Opus spend, carves out the reserve, and paces spot work into the rest on a
          curve that reaches 100% of the non-reserved capacity exactly as the window rolls over. So a
          higher reserve means less spot work, not a lower stopping line — spot work still fills
          whatever is left, just more slowly. `get_spot_policy` shows the dollar figure each percentage
          currently derives. `max_concurrent_sessions` bounds the fleet: every running session counts
          toward it, priority included, but only spot sessions are held by it. With gating off, spot
          sessions start like any other.
        - **set_top_up**: Tune when the `no_sessions_in_progress` trigger event fires — the event that
          hands a fleet with spare capacity more work. Any of `max_sessions_in_hand`, `idle_minutes` and
          `min_fire_interval_minutes` may be given; omitted ones are left alone.

          The fleet counts as idle enough while it holds FEWER THAN `max_sessions_in_hand` sessions,
          counting running ones and spot ones queued behind the gate together — so it does not have to
          empty out completely before topping up. 1 means literally nothing running and nothing queued.
          `idle_minutes` is how long it must stay under that ceiling first; `min_fire_interval_minutes`
          is the floor between two fires, and with a ceiling above 1 that floor, not the ceiling, is
          what caps how often work gets started. `get_spot_policy` reports all three plus where the
          fleet currently sits against them.
        - **promote_genesis**: Make a genesis kind `priority` (requires `genesis`). This is the one-click
          promotion: it reclassifies every session from that genesis, including ones that already exist,
          because a session's class is derived from its genesis unless something named one for it.
        - **demote_genesis**: Make a genesis kind `spot` (requires `genesis`).
        - **reset_genesis_classes**: Drop every override and return all genesis kinds to their defaults.

        Settable genesis keys: `web_ui`, `api`, `unknown` — the origins nothing triggers.

        **The other five kinds are not settable here.** `slack`, `github_issue`, `github_label`,
        `schedule` and `ao_event` restate trigger condition types, and their class lives on the trigger
        that fires them: set `scheduling_class` with `action_trigger` so one trigger moves without
        dragging every other session of the same kind with it. To change a single session rather than a
        whole feed, pass `scheduling_class` to `start_session` when spawning it, or set it afterwards
        with `action_session`.

        **Use cases:**
        - Demote `web_ui` to spot while you are letting a long unattended batch run
        - Turn gating on before a long unattended run, off when you want everything to go now
        - Raise or lower the targets, or the number of sessions allowed at once
      DESC

      input_schema({
        type: "object",
        properties: {
          action: {
            type: "string",
            enum: ACTIONS,
            description: "The action to perform"
          },
          genesis: {
            type: "string",
            enum: SessionGenesis::SETTABLE_KEYS,
            description: "Genesis kind. Required for promote_genesis and demote_genesis. Only the kinds " \
                         "no trigger produces can be set here; use action_trigger for the rest."
          },
          enabled: {
            type: "boolean",
            description: "set_gating: whether the spot gate holds sessions at all."
          },
          five_hour_reserve_pct: {
            type: "integer",
            minimum: 0,
            maximum: 100,
            description: "set_gating: percentage of each 5-hour window held back for priority sessions, 0-100. " \
                         "Spot work paces itself into the rest. 0 reserves nothing; 100 holds every spot session."
          },
          weekly_reserve_pct: {
            type: "integer",
            minimum: 0,
            maximum: 100,
            description: "set_gating: percentage of each weekly window held back for priority sessions, 0-100. " \
                         "Spot work paces itself into the rest. 0 reserves nothing; 100 holds every spot session."
          },
          max_concurrent_sessions: {
            type: "integer",
            minimum: 1,
            maximum: 100,
            description: "set_gating: most sessions allowed to run at once, 1-100 (10 by default). Counts " \
                         "every running session, priority included; holds only spot ones."
          },
          max_sessions_in_hand: {
            type: "integer",
            minimum: 1,
            maximum: 100,
            description: "set_top_up: the fleet counts as idle enough while it holds FEWER than this many " \
                         "sessions, 1-100 (3 by default). Running sessions and spot-queued ones count " \
                         "together. 1 means nothing running and nothing queued."
          },
          idle_minutes: {
            type: "integer",
            minimum: 1,
            maximum: 1440,
            description: "set_top_up: how long the fleet must stay under that ceiling before the event " \
                         "fires, in minutes, 1-1440 (5 by default). Sampled once a minute."
          },
          min_fire_interval_minutes: {
            type: "integer",
            minimum: 1,
            maximum: 10080,
            description: "set_top_up: floor between two fires, in minutes, 1-10080 (60 by default). With " \
                         "a ceiling above 1 this is the real cap on how often work gets started."
          }
        },
        required: [ "action" ]
      })

      def call(args)
        action = require_arg(args, :action)
        raise ToolError, "Unknown action: #{action}. Valid actions: #{ACTIONS.join(', ')}" unless ACTIONS.include?(action)

        case action
        when "set_gating" then set_gating(args)
        when "set_top_up" then set_top_up(args)
        when "promote_genesis" then set_genesis_class(args, SessionGenesis::PRIORITY)
        when "demote_genesis" then set_genesis_class(args, SessionGenesis::SPOT)
        when "reset_genesis_classes" then reset_genesis_classes
        end
      end

      private

      def set_gating(args)
        setting = AppSetting.editable
        changes = []

        unless args["enabled"].nil?
          setting.spot_gating_enabled = ActiveModel::Type::Boolean.new.cast(args["enabled"])
          changes << "gating #{setting.spot_gating_enabled ? 'enabled' : 'disabled'}"
        end
        # `.nil?`, not truthiness: 0 is a meaningful reserve (hold nothing back)
        # and would otherwise be silently ignored.
        unless args["five_hour_reserve_pct"].nil?
          setting.spot_reserve_five_hour_pct = args["five_hour_reserve_pct"]
          changes << "5-hour priority reserve #{setting.spot_reserve_five_hour_pct}%"
        end
        unless args["weekly_reserve_pct"].nil?
          setting.spot_reserve_weekly_pct = args["weekly_reserve_pct"]
          changes << "weekly priority reserve #{setting.spot_reserve_weekly_pct}%"
        end
        if args["max_concurrent_sessions"]
          setting.spot_max_concurrent_sessions = args["max_concurrent_sessions"]
          changes << "max #{setting.spot_max_concurrent_sessions} sessions at once"
        end

        if changes.empty?
          raise ToolError, "Nothing to change: pass enabled, five_hour_reserve_pct, weekly_reserve_pct " \
                           "or max_concurrent_sessions"
        end

        # Surface a bad reserve as a message the caller can act on rather than
        # as an internal error, matching every other validation in this tool.
        raise ToolError, "Invalid spot policy: #{setting.errors.full_messages.join(', ')}" unless setting.save
        "Spot policy updated: #{changes.join(', ')}.\n\n#{decision_summary}"
      end

      # The backlog top-up policy. `.nil?` rather than truthiness, so an explicit
      # null is skipped rather than assigned to a NOT NULL column — and a call
      # carrying nothing but nulls raises "Nothing to change" instead of saving an
      # empty edit.
      def set_top_up(args)
        setting = AppSetting.editable
        changes = []

        TOP_UP_FIELDS.each do |arg, column|
          next if args[arg].nil?

          setting.public_send("#{column}=", args[arg])
          changes << "#{arg} #{setting.public_send(column)}"
        end

        if changes.empty?
          raise ToolError, "Nothing to change: pass #{TOP_UP_FIELDS.keys.join(', ')}"
        end
        raise ToolError, "Invalid top-up policy: #{setting.errors.full_messages.join(', ')}" unless setting.save

        "Fleet top-up policy updated: #{changes.join(', ')}.\n\n#{top_up_summary(setting)}"
      end

      def top_up_summary(setting)
        status = FleetTopUpStatus.current(setting: setting)
        "Top-up fires #{status.cadence_phrase}. #{status.sentence}"
      end

      def set_genesis_class(args, klass)
        genesis = require_arg(args, :genesis)
        raise ToolError, "Unknown genesis: #{genesis}. Valid: #{SessionGenesis::SETTABLE_KEYS.join(', ')}" unless SessionGenesis.valid?(genesis)
        unless SessionGenesis.settable?(genesis)
          raise ToolError, "`#{genesis}` takes its class from the trigger that fires it, not from this policy. " \
                           "Set `scheduling_class` on the trigger with `action_trigger` (search_triggers lists them), " \
                           "or on one session with `start_session`/`action_session`."
        end

        setting = AppSetting.editable
        setting.set_genesis_class(genesis, klass)
        setting.save!

        affected = Session.genesis_count_for(genesis)
        "#{SessionGenesis.label(genesis)} (`#{genesis}`) is now **#{klass}**. " \
          "#{affected} live session(s) reclassified.\n\n#{decision_summary}"
      end

      def reset_genesis_classes
        setting = AppSetting.editable
        setting.reset_genesis_classes
        setting.save!

        "All genesis kinds reset to their default classes.\n\n#{decision_summary}"
      end

      # Every write echoes back what the gate now decides, so a caller does not
      # have to make a second call to learn whether its change took effect.
      def decision_summary
        decision = SpotGateService.evaluate
        "Spot sessions are now #{decision.allowed? ? 'running' : 'HELD'} (`#{decision.reason}`): #{decision.detail}"
      end
    end
  end
end
