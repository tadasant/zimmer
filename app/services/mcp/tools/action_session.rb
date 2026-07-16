# frozen_string_literal: true

require "automated_prompts"
require "path_sanitizer"

module Mcp
  module Tools
    # Mirrors the member actions of Api::V1::SessionsController — follow_up,
    # pause, restart, archive, unarchive, mcp_servers, model, heartbeat, fork,
    # refresh, refresh_all, notes, title, toggle_favorite, bulk_archive — behind
    # one `action` switch, exactly as the decoupled server's action_session did.
    #
    # Mcp::Tools::SelfSessionActionSession subclasses this to expose only the
    # self-management subset; the action bodies below are the single copy.
    class ActionSession < Tool
      tool_name "action_session"

      SESSION_ID_DESC = 'Session ID (numeric) or slug (string). Required for most actions. Not required for "refresh_all" and "bulk_archive".'
      ACTION_DESC = 'Action to perform: "follow_up", "pause", "restart", "archive", "unarchive", "change_mcp_servers", "change_model", "change_skills", "change_hooks", "change_plugins", "change_goal", "change_auto_compact_window", "change_category", "set_blocked", "toggle_push_notifications", "set_heartbeat", "fork", "refresh", "refresh_all", "update_notes", "update_title", "toggle_favorite", "bulk_archive"'
      PROMPT_DESC = 'Required for "follow_up" action. The prompt to send to the agent. Not used for other actions.'
      FORCE_IMMEDIATE_DESC = 'Optional for "follow_up" action. When true, interrupts a running session to deliver the prompt immediately instead of queuing it. Not used for other actions.'
      MCP_SERVERS_DESC = 'Required for "change_mcp_servers" action. Array of MCP server names to set for the session (replaces the existing set — this is not a merge).'
      MODEL_DESC = 'Required for "change_model" action. The model identifier to use (e.g., "opus", "sonnet").'
      SKILLS_DESC = 'Required for "change_skills" action. Array of catalog skill IDs to set for the session (replaces the existing set — this is not a merge). Invalid IDs are rejected. Call get_configs / the skills catalog for valid IDs.'
      HOOKS_DESC = 'Required for "change_hooks" action. Array of catalog hook IDs to set for the session (replaces the existing set — this is not a merge). Invalid IDs are rejected.'
      PLUGINS_DESC = 'Required for "change_plugins" action. Array of catalog plugin IDs to set for the session (replaces the existing set — this is not a merge). Invalid IDs are rejected.'
      GOAL_DESC = 'Required for "change_goal" action. The goal text to set for the session; pass an empty string to clear the goal.'
      AUTO_COMPACT_WINDOW_DESC = 'Required for "change_auto_compact_window" action. The context (auto-compact) window in tokens, a positive integer. Applies on the next turn or restart, not the currently running process.'
      CATEGORY_ID_DESC = 'Required for "change_category" action (the key must be present). The organizational category ID to assign; pass null to move the session back to Uncategorized.'
      BLOCKED_BY_SESSION_ID_DESC = 'Required for "set_blocked" action. The ID of the session that blocks this one; pass null to clear the blocked-by relationship.'
      ENABLED_DESC = 'Optional for "set_heartbeat" action. When true, enables the session heartbeat; when false, disables it. Omit to leave the enabled state unchanged (at least one of "enabled" or "interval_seconds" must be provided).'
      INTERVAL_SECONDS_DESC = 'Optional for "set_heartbeat" action. Heartbeat cadence in seconds (30–86400). Omit to leave the interval unchanged (at least one of "enabled" or "interval_seconds" must be provided).'
      MESSAGE_INDEX_DESC = 'Required for "fork" action. The transcript message index to fork from.'
      SESSION_NOTES_DESC = 'Required for "update_notes" action. The notes text to set on the session.'
      SESSION_IDS_DESC = 'Required for "bulk_archive" action. Array of session IDs to archive.'
      TITLE_DESC = 'Required for "update_title" action. The new title for the session.'

      ACTIONS = %w[
        follow_up
        pause
        restart
        archive
        unarchive
        change_mcp_servers
        change_model
        change_skills
        change_hooks
        change_plugins
        change_goal
        change_auto_compact_window
        change_category
        set_blocked
        toggle_push_notifications
        set_heartbeat
        fork
        refresh
        refresh_all
        update_notes
        update_title
        toggle_favorite
        bulk_archive
      ].freeze

      # Every action but the two bulk ones operates on a single session.
      SESSIONLESS_ACTIONS = %w[refresh_all bulk_archive].freeze

      MAX_MCP_SERVERS = 50
      MAX_MCP_SERVER_NAME_LENGTH = 100
      MAX_CATALOG_SKILLS = 100
      MAX_CATALOG_HOOKS = 100
      MAX_CATALOG_PLUGINS = 50
      MAX_CATALOG_ITEM_ID_LENGTH = 100
      MAX_SESSION_NOTES_LENGTH = 50_000
      REFRESH_ALL_LIMIT = 50

      # Shared spec for the three replace-semantics catalog list fields
      # (skills/hooks/plugins). Each mirrors change_mcp_servers: validate every id
      # against its catalog, persist the whole list (replace, not merge), and log
      # the delta. Config regeneration is deliberately deferred to the next
      # prepare/unarchive — the same as change_mcp_servers — so an archived session
      # picks the new set up when it is next prepared.
      CATALOG_LIST_FIELDS = {
        "change_skills" => { attribute: :catalog_skills, param: "skills", label: "Skills", max: MAX_CATALOG_SKILLS, config: "SkillsConfig" },
        "change_hooks" => { attribute: :catalog_hooks, param: "hooks", label: "Hooks", max: MAX_CATALOG_HOOKS, config: "HooksConfig" },
        "change_plugins" => { attribute: :catalog_plugins, param: "plugins", label: "Plugins", max: MAX_CATALOG_PLUGINS, config: "PluginsConfig" }
      }.freeze

      description <<~DESC
        Perform an action on an agent session.

        **Actions:**
        - **follow_up**: Send a follow-up prompt to a session (requires "prompt"; optional "force_immediate" to interrupt a running session). Without "force_immediate", uses smart routing: sends immediately if idle, auto-queues if running. Alternative: use manage_enqueued_messages "send_now" for one-step immediate delivery with goal support.
        - **pause**: Pause a running session, transitioning it to idle "needs_input" status
        - **restart**: Restart an idle or failed session without providing new input
        - **archive**: Archive a session (marks as completed)
        - **unarchive**: Restore an archived session to idle "needs_input" status
        - **change_mcp_servers**: Update the MCP servers for a session (requires "mcp_servers" parameter; replaces the set)
        - **change_model**: Update the model for a session (requires "model" parameter, e.g., "opus", "sonnet")
        - **change_skills**: Update the catalog skills for a session (requires "skills" parameter; replaces the set). Invalid skill IDs are rejected.
        - **change_hooks**: Update the catalog hooks for a session (requires "hooks" parameter; replaces the set). Invalid hook IDs are rejected.
        - **change_plugins**: Update the catalog plugins for a session (requires "plugins" parameter; replaces the set). Invalid plugin IDs are rejected.
        - **change_goal**: Update the goal for a session (requires "goal" parameter; empty string clears it)
        - **change_auto_compact_window**: Update the context (auto-compact) window in tokens (requires "auto_compact_window"; applies on the next turn/restart)
        - **change_category**: Assign the session's organizational category (requires "category_id"; null moves it to Uncategorized)
        - **set_blocked**: Set or clear the session's blocked-by relationship (requires "blocked_by_session_id"; null clears it)
        - **toggle_push_notifications**: Toggle push notifications on a session
        - **set_heartbeat**: Toggle a session's heartbeat and/or set its interval (provide "enabled" and/or "interval_seconds"). When enabled and the session sits in needs_input, a recurring nudge prompts it to keep working toward its goal; set "enabled" to false to stop the nudges.
        - **fork**: Fork a session from a specific transcript message (requires "message_index")
        - **refresh**: Refresh a single session's status from the execution provider
        - **refresh_all**: Refresh all active sessions (no session_id needed)
        - **update_notes**: Update the notes on a session (requires "session_notes")
        - **update_title**: Update the title of a session (requires "title")
        - **toggle_favorite**: Toggle favorite status on a session
        - **bulk_archive**: Archive multiple sessions at once (requires "session_ids", no session_id needed)

        List-valued fields (mcp_servers, skills, hooks, plugins) use replace semantics: the array you pass becomes the whole set, it is not merged with the existing one. These changes persist to the session and take effect the next time the session's runtime config is prepared (e.g. on the next turn or unarchive), matching how change_mcp_servers behaves — they do not hot-reconfigure a currently running process.

        **Use cases:**
        - Provide additional instructions to an agent
        - Control session lifecycle (pause, restart, fork, refresh)
        - Organize sessions (archive, unarchive, bulk_archive, toggle_favorite, update_notes, update_title, change_category, set_blocked, toggle_push_notifications)
        - Reconfigure session capabilities (MCP servers, skills, hooks, plugins, model, context window)
        - Set or clear a session's goal
      DESC

      input_schema({
        type: "object",
        properties: {
          session_id: {
            oneOf: [ { type: "string" }, { type: "number" } ],
            description: SESSION_ID_DESC
          },
          action: { type: "string", enum: ACTIONS, description: ACTION_DESC },
          prompt: { type: "string", description: PROMPT_DESC },
          force_immediate: { type: "boolean", description: FORCE_IMMEDIATE_DESC },
          mcp_servers: { type: "array", items: { type: "string" }, description: MCP_SERVERS_DESC },
          model: { type: "string", description: MODEL_DESC },
          skills: { type: "array", items: { type: "string" }, description: SKILLS_DESC },
          hooks: { type: "array", items: { type: "string" }, description: HOOKS_DESC },
          plugins: { type: "array", items: { type: "string" }, description: PLUGINS_DESC },
          goal: { type: "string", description: GOAL_DESC },
          auto_compact_window: { type: "integer", description: AUTO_COMPACT_WINDOW_DESC },
          category_id: { type: [ "number", "null" ], description: CATEGORY_ID_DESC },
          blocked_by_session_id: { type: [ "number", "null" ], description: BLOCKED_BY_SESSION_ID_DESC },
          enabled: { type: "boolean", description: ENABLED_DESC },
          interval_seconds: { type: "number", description: INTERVAL_SECONDS_DESC },
          message_index: { type: "number", description: MESSAGE_INDEX_DESC },
          session_notes: { type: "string", description: SESSION_NOTES_DESC },
          session_ids: { type: "array", items: { type: "number" }, description: SESSION_IDS_DESC },
          title: { type: "string", description: TITLE_DESC }
        },
        required: [ "action" ]
      })

      def call(args)
        action = require_arg(args, :action).to_s

        unless allowed_actions.include?(action)
          raise ToolError, "Unknown action \"#{action}\". Allowed actions: #{allowed_actions.join(', ')}"
        end

        if requires_session_id?(action) && args["session_id"].blank?
          raise ToolError, "The \"session_id\" parameter is required for the \"#{action}\" action."
        end

        dispatch(action, args)
      end

      private

      # The action list this variant exposes. SelfSessionActionSession narrows it.
      def allowed_actions
        ACTIONS
      end

      def requires_session_id?(action)
        !SESSIONLESS_ACTIONS.include?(action)
      end

      def dispatch(action, args)
        case action
        when "follow_up" then follow_up(find_session(args["session_id"]), args)
        when "pause" then pause(find_session(args["session_id"]))
        when "restart" then restart(find_session(args["session_id"]))
        when "archive" then archive(find_session(args["session_id"]))
        when "unarchive" then unarchive(find_session(args["session_id"]))
        when "change_mcp_servers" then change_mcp_servers(find_session(args["session_id"]), args)
        when "change_model" then change_model(find_session(args["session_id"]), args)
        when "change_skills", "change_hooks", "change_plugins" then change_catalog_list(find_session(args["session_id"]), action, args)
        when "change_goal" then change_goal(find_session(args["session_id"]), args)
        when "change_auto_compact_window" then change_auto_compact_window(find_session(args["session_id"]), args)
        when "change_category" then change_category(find_session(args["session_id"]), args)
        when "set_blocked" then set_blocked(find_session(args["session_id"]), args)
        when "toggle_push_notifications" then toggle_push_notifications(find_session(args["session_id"]))
        when "set_heartbeat" then set_heartbeat(find_session(args["session_id"]), args)
        when "fork" then fork_session(find_session(args["session_id"]), args)
        when "refresh" then refresh(find_session(args["session_id"]))
        when "refresh_all" then refresh_all
        when "update_notes" then update_notes(find_session(args["session_id"]), args)
        when "update_title" then update_title(find_session(args["session_id"]), args)
        when "toggle_favorite" then toggle_favorite(find_session(args["session_id"]))
        when "bulk_archive" then bulk_archive(args)
        end
      end

      # --- Actions --------------------------------------------------------------

      def follow_up(session, args)
        prompt = args["prompt"].to_s.strip
        raise ToolError, "The \"prompt\" parameter is required for the \"follow_up\" action." if prompt.blank?

        if prompt.length > Session::PROMPT_MAX_LENGTH
          raise ToolError, "prompt is too long (maximum #{Session::PROMPT_MAX_LENGTH} characters)"
        end

        return force_immediate_follow_up(session, prompt) if boolean(args["force_immediate"])
        return queue_follow_up(session, prompt) if session.running?

        unless session.waiting? || session.needs_input?
          raise ToolError, "Session is #{session.status}. Follow-up prompts can only be sent to running, waiting, or needs_input sessions."
        end

        ActiveRecord::Base.transaction do
          session.update!(prompt: prompt)
          session.resume! if session.may_resume?
          job = AgentSessionJob.enqueue_with_prompt(session.id, prompt)
          session.update!(running_job_id: job.job_id)
        end

        follow_up_result(session.reload, "Follow-up prompt sent")
      end

      # force_immediate goes through the one race-free interrupt path
      # (Sessions::InterruptService) the web and REST "Send Now" buttons use, so
      # "deliver now, terminating the current turn" cannot diverge across entry points.
      def force_immediate_follow_up(session, prompt)
        unless session.running? || session.waiting? || session.needs_input?
          raise ToolError, "Session is #{session.status}. Follow-up prompts can only be sent to running, waiting, or needs_input sessions."
        end

        enqueued_message = nil
        ActiveRecord::Base.transaction do
          max_position = session.enqueued_messages.maximum(:position) || 0
          enqueued_message = session.enqueued_messages.create!(
            content: prompt,
            position: max_position + 1,
            status: "pending"
          )
        end

        result = Sessions::InterruptService.new(
          session: session,
          enqueued_message: enqueued_message,
          actor: "mcp_force_immediate"
        ).call

        unless result.success?
          # All-or-nothing: drop the staged message so it is not silently delivered
          # later as a surprise queued follow-up. A concurrent interrupt may have
          # already claimed it, which is fine.
          begin
            enqueued_message.reload
            enqueued_message.destroy! if enqueued_message.status == "pending"
          rescue ActiveRecord::RecordNotFound
            # already claimed by a concurrent interrupt — nothing to clean up
          end
          raise ToolError, "Cannot send follow-up: #{result.error}"
        end

        follow_up_result(session.reload, "Follow-up prompt sent immediately")
      end

      # A running session queues the message rather than rejecting it, so a caller
      # that raced the end of a turn does not lose the prompt.
      def queue_follow_up(session, prompt)
        max_position = session.enqueued_messages.maximum(:position) || 0
        enqueued_message = session.enqueued_messages.create!(
          content: prompt,
          position: max_position + 1,
          status: "pending"
        )
        session.logs.create!(
          content: "Message queued at position #{enqueued_message.position} (session is running)",
          level: "info"
        )

        follow_up_result(
          session.reload,
          "Message queued (session is running). It will be sent when the agent completes its current task."
        )
      end

      def pause(session)
        raise ToolError, "Session is not running" unless session.running?

        # Mark as user-initiated so the pause push notification is skipped.
        session.update!(metadata: (session.metadata || {}).merge("paused_by" => "user"))
        session.pause!

        summary("Session Paused", session, status_label: "New Status")
      end

      def restart(session)
        unless session.may_resume?
          raise ToolError, "Session cannot be restarted from current status: #{session.status}"
        end

        # Setup never completed (e.g. the git clone failed), so re-run the whole
        # setup pipeline instead of prompting a clone that does not exist.
        return restart_from_scratch(session) if session.failed_before_initial_prompt? && !session.setup_complete?

        raise ToolError, "Session has no session_id" if session.session_id.blank?

        # Must be read before the stale metadata (which carries failure_reason) is cleared.
        use_initial_prompt = session.failed_before_initial_prompt? && session.prompt.present?
        restart_prompt = use_initial_prompt ? session.prompt : AutomatedPrompts::SYSTEM_RECOVERY

        ActiveRecord::Base.transaction do
          cleaned_metadata = (session.metadata || {}).except(*Session::STALE_RETRY_METADATA_KEYS)
          # For pre-prompt failures, drop runtime_started so the restart uses
          # --session-id (with --mcp-config) instead of --resume.
          cleaned_metadata = cleaned_metadata.except("runtime_started") if use_initial_prompt

          session.update!(running_job_id: nil, metadata: cleaned_metadata)
          session.resume!

          AgentSessionJob.enqueue_with_prompt(session.id, restart_prompt)
        end

        summary("Session Restarted", session.reload, status_label: "New Status", message: "Session restarted")
      end

      def restart_from_scratch(session)
        raise ToolError, "No git_root configured for restart from scratch" if session.git_root.blank?

        cleaned_metadata = (session.metadata || {}).except(
          *Session::STALE_RETRY_METADATA_KEYS,
          *Session::SETUP_ARTIFACT_KEYS
        )

        ActiveRecord::Base.transaction do
          session.logs.create!(
            content: "Restarting session from scratch: re-running full setup pipeline (git clone, MCP config, process spawn)",
            level: "info"
          )
          session.update!(running_job_id: nil, session_id: nil, metadata: cleaned_metadata)
          session.resume! if session.may_resume?
          AgentSessionJob.enqueue_new_session(session.id)
          session.logs.create!(
            content: "Session resumed - status changed to running, full setup will be re-attempted",
            level: "info"
          )
        end

        summary("Session Restarted", session.reload, status_label: "New Status", message: "Session restarted from scratch")
      end

      def archive(session)
        unless session.may_archive?
          raise ToolError, "Session cannot be trashed from current status: #{session.status}"
        end

        session.archive!
        session.reload

        [
          "## Session Archived",
          "",
          "- **Session ID:** #{session.id}",
          "- **Title:** #{session.title}",
          "- **New Status:** #{session.status}",
          "- **Archived At:** #{session.archived_at&.iso8601}"
        ].join("\n")
      end

      def unarchive(session)
        raise ToolError, "Session is not in trash" unless session.archived?

        result = UnarchiveSessionService.call(session: session)
        raise ToolError, "Failed to restore: #{result.error}" unless result.success?

        summary("Session Unarchived", session.reload, status_label: "New Status")
      end

      def change_mcp_servers(session, args)
        if context.restricted?
          raise ToolError, "The \"change_mcp_servers\" action is not allowed when this connection is restricted to " \
                           "specific agent roots. MCP servers are locked to the defaults configured for each allowed agent root."
        end

        unless args["mcp_servers"].is_a?(Array)
          raise ToolError, "The \"mcp_servers\" parameter is required for the \"change_mcp_servers\" action."
        end

        mcp_servers = args["mcp_servers"]
        raise ToolError, "Maximum #{MAX_MCP_SERVERS} MCP servers" if mcp_servers.length > MAX_MCP_SERVERS

        mcp_servers = mcp_servers.reject(&:blank?).map { |s| s.to_s.strip.first(100) }

        invalid = mcp_servers.reject { |name| ServersConfig.exists?(name) }
        raise ToolError, "Invalid MCP servers: #{invalid.join(', ')}" if invalid.any?

        old_servers = session.mcp_servers || []
        session.update!(mcp_servers: mcp_servers)

        added = mcp_servers - old_servers
        removed = old_servers - mcp_servers

        # A deliberate removal is not an unexplained loss — forget its status so
        # later config regenerations don't report it as one.
        session.forget_mcp_server_status!(removed)

        changes = []
        changes << "added: #{added.join(', ')}" if added.any?
        changes << "removed: #{removed.join(', ')}" if removed.any?
        session.logs.create!(content: "MCP servers updated via MCP (#{changes.join('; ')})", level: "info") if changes.any?

        [
          "## MCP Servers Updated",
          "",
          "- **Session ID:** #{session.id}",
          "- **Title:** #{session.title}",
          "- **MCP Servers:** #{format_list(session.mcp_servers)}"
        ].join("\n")
      end

      def change_model(session, args)
        model = args["model"]
        unless model.is_a?(String) && model.present?
          raise ToolError, "The \"model\" parameter is required for the \"change_model\" action."
        end

        model = model.strip.first(100)

        unless ModelCatalog.valid_model?(session.agent_runtime, model)
          allowed = ModelCatalog.model_ids_for(session.agent_runtime)
          raise ToolError, "model #{model.inspect} is not valid for runtime #{session.agent_runtime}. Valid models: #{allowed.join(', ')}"
        end

        old_model = session.config&.dig("model")
        session.update!(config: (session.config || {}).merge("model" => model))
        session.logs.create!(content: "Model updated via MCP (#{old_model} → #{model})", level: "info") if old_model != model

        [
          "## Model Updated",
          "",
          "- **Session ID:** #{session.id}",
          "- **Title:** #{session.title}",
          "- **Model:** #{session.config&.dig('model').presence || '(default)'}"
        ].join("\n")
      end

      # Shared body for change_skills / change_hooks / change_plugins. Mirrors
      # change_mcp_servers: replace-not-merge, reject any id outside the catalog
      # (listing valid options so a rename like `pr` → `open-pr` is easy to fix),
      # persist, and log the delta. The unknown-id rejection is what prevents an
      # invalid value from being persisted and bricking the session on next prepare.
      def change_catalog_list(session, action, args)
        spec = CATALOG_LIST_FIELDS.fetch(action)
        param = spec[:param]

        # Plugins can bundle MCP servers (see Session#derive_mcp_servers_from_plugins),
        # so on a restricted connection they are a bypass of the same agent-root MCP
        # lock change_mcp_servers enforces. Skills and hooks carry no such server
        # expansion, so only plugins inherit the guard.
        if action == "change_plugins" && context.restricted?
          raise ToolError, "The \"change_plugins\" action is not allowed when this connection is restricted to " \
                           "specific agent roots. Plugins can add MCP servers, which are locked to the defaults configured for each allowed agent root."
        end

        unless args[param].is_a?(Array)
          raise ToolError, "The \"#{param}\" parameter is required for the \"#{action}\" action."
        end

        items = args[param]
        raise ToolError, "Maximum #{spec[:max]} #{spec[:label].downcase}" if items.length > spec[:max]

        items = items.reject(&:blank?).map { |s| s.to_s.strip.first(MAX_CATALOG_ITEM_ID_LENGTH) }

        config = spec[:config].constantize
        invalid = items.reject { |id| config.exists?(id) }
        if invalid.any?
          valid = config.all.map(&:id).sort
          raise ToolError, "Invalid #{spec[:label].downcase}: #{invalid.join(', ')}. Valid #{spec[:label].downcase}: #{valid.join(', ')}"
        end

        old_items = session.public_send(spec[:attribute]) || []
        session.update!(spec[:attribute] => items)

        added = items - old_items
        removed = old_items - items
        changes = []
        changes << "added: #{added.join(', ')}" if added.any?
        changes << "removed: #{removed.join(', ')}" if removed.any?
        session.logs.create!(content: "#{spec[:label]} updated via MCP (#{changes.join('; ')})", level: "info") if changes.any?

        [
          "## #{spec[:label]} Updated",
          "",
          "- **Session ID:** #{session.id}",
          "- **Title:** #{session.title}",
          "- **#{spec[:label]}:** #{format_list(session.public_send(spec[:attribute]))}"
        ].join("\n")
      end

      def change_goal(session, args)
        unless args.key?("goal")
          raise ToolError, "The \"goal\" parameter is required for the \"change_goal\" action."
        end

        goal = args["goal"].to_s.strip.presence
        if goal && goal.length > Session::GOAL_MAX_LENGTH
          raise ToolError, "Goal is too long (maximum #{Session::GOAL_MAX_LENGTH} characters)"
        end

        old_goal = session.goal
        session.update!(goal: goal)

        if old_goal != goal
          change_desc = if goal.blank?
            "Goal cleared"
          elsif old_goal.blank?
            "Goal set"
          else
            "Goal updated"
          end
          session.logs.create!(content: "#{change_desc} via MCP", level: "info")
        end

        [
          "## Goal Updated",
          "",
          "- **Session ID:** #{session.id}",
          "- **Title:** #{session.title}",
          "- **Goal:** #{session.goal.presence || '(none)'}"
        ].join("\n")
      end

      def change_auto_compact_window(session, args)
        raw = args["auto_compact_window"]
        unless raw.to_s.match?(/\A\d+\z/)
          raise ToolError, "The \"auto_compact_window\" parameter is required for the \"change_auto_compact_window\" action and must be a positive integer."
        end

        window = raw.to_i
        if window <= 0 || window > Session::MAX_AUTO_COMPACT_WINDOW
          raise ToolError, "\"auto_compact_window\" must be between 1 and #{Session::MAX_AUTO_COMPACT_WINDOW}."
        end

        old_window = session.auto_compact_window
        session.update!(auto_compact_window: window)
        session.logs.create!(content: "Context window updated via MCP (#{old_window} → #{window}); applies on next turn or restart", level: "info") if old_window != window

        [
          "## Context Window Updated",
          "",
          "- **Session ID:** #{session.id}",
          "- **Title:** #{session.title}",
          "- **Auto-compact Window:** #{session.auto_compact_window} tokens"
        ].join("\n")
      end

      def change_category(session, args)
        unless args.key?("category_id")
          raise ToolError, "The \"category_id\" parameter is required for the \"change_category\" action (pass null to clear)."
        end

        category_id = args["category_id"].presence
        category = nil
        if category_id
          category = Category.find_by(id: category_id)
          raise ToolError, "Category ##{category_id} not found" unless category
        end

        session.update!(category_id: category&.id)

        [
          "## Category Updated",
          "",
          "- **Session ID:** #{session.id}",
          "- **Title:** #{session.title}",
          "- **Category:** #{category&.name || '(uncategorized)'}"
        ].join("\n")
      end

      def set_blocked(session, args)
        unless args.key?("blocked_by_session_id")
          raise ToolError, "The \"blocked_by_session_id\" parameter is required for the \"set_blocked\" action (pass null to clear)."
        end

        blocker_id = args["blocked_by_session_id"].presence
        blocker = nil
        if blocker_id
          blocker = Session.find_by(id: blocker_id)
          raise ToolError, "Session ##{blocker_id} not found" unless blocker
          raise ToolError, "A session cannot be blocked by itself" if blocker.id == session.id
        end

        session.update!(blocked_by_session_id: blocker&.id)

        [
          "## Blocked-by Updated",
          "",
          "- **Session ID:** #{session.id}",
          "- **Title:** #{session.title}",
          "- **Blocked By:** #{blocker ? "##{blocker.id}" : '(none)'}"
        ].join("\n")
      end

      def toggle_push_notifications(session)
        session.update!(push_notifications_enabled: !session.push_notifications_enabled)

        [
          "## Push Notifications Toggled",
          "",
          "- **Session ID:** #{session.id}",
          "- **Title:** #{session.title}",
          "- **Push Notifications:** #{session.push_notifications_enabled ? 'Enabled' : 'Disabled'}"
        ].join("\n")
      end

      def set_heartbeat(session, args)
        attrs = {}

        unless args["enabled"].nil?
          casted = ActiveModel::Type::Boolean.new.cast(args["enabled"])
          raise ToolError, "\"enabled\" must be a boolean." if casted.nil?
          attrs[:heartbeat_enabled] = casted
        end

        unless args["interval_seconds"].nil?
          interval = args["interval_seconds"]
          raise ToolError, "\"interval_seconds\" must be an integer." unless interval.to_s.match?(/\A\d+\z/)

          interval = interval.to_i
          unless interval.between?(Session::HEARTBEAT_MIN_INTERVAL_SECONDS, Session::HEARTBEAT_MAX_INTERVAL_SECONDS)
            raise ToolError, "\"interval_seconds\" must be between #{Session::HEARTBEAT_MIN_INTERVAL_SECONDS} and #{Session::HEARTBEAT_MAX_INTERVAL_SECONDS}."
          end
          attrs[:heartbeat_interval_seconds] = interval
        end

        if attrs.empty?
          raise ToolError, "The \"set_heartbeat\" action requires at least one of \"enabled\" or \"interval_seconds\"."
        end

        session.update!(attrs)

        [
          "## Heartbeat Updated",
          "",
          "- **Session ID:** #{session.id}",
          "- **Title:** #{session.title}",
          "- **Heartbeat Enabled:** #{session.heartbeat_enabled ? 'Yes' : 'No'}",
          "- **Interval:** #{session.heartbeat_interval_seconds} seconds"
        ].join("\n")
      end

      def fork_session(session, args)
        message_index = args["message_index"]
        if message_index.nil?
          raise ToolError, "The \"message_index\" parameter is required for the \"fork\" action."
        end

        result = ForkSessionService.call(source_session: session, message_index: message_index.to_i)
        raise ToolError, "Fork failed: #{result.error}" unless result.success?

        forked = result.forked_session
        [
          "## Session Forked",
          "",
          "- **New Session ID:** #{forked.id}",
          "- **Title:** #{forked.title}",
          "- **Status:** #{forked.status}",
          "- **Message:** Session forked successfully"
        ].join("\n")
      end

      # Re-read the transcript the runtime writes to disk into the session record.
      def refresh(session)
        transcript_dir = transcript_directory(session)
        raise ToolError, "No clone path found for this session" if transcript_dir.nil?

        transcript_file = Dir.exist?(transcript_dir) ? TranscriptFileLocator.find_main_transcript(session, transcript_dir) : nil
        raise ToolError, "No transcript files found on filesystem" unless transcript_file

        content = File.read(transcript_file)
        message_count = count_transcript_messages(content)

        # Never let a refresh shrink the stored transcript: a shorter filesystem
        # transcript means the clone was recreated at a new path and started a
        # fresh file, and session.transcript is the only durable record.
        if Session.transcript_regression?(session.transcript, content)
          Rails.logger.warn "[Mcp::Tools::ActionSession] Refused transcript regression for session #{session.id} " \
                            "(stored #{Session.transcript_line_count(session.transcript)} events, filesystem #{message_count}); preserving stored transcript"
          return summary(
            "Session Refreshed",
            session,
            message: "Filesystem transcript is shorter than the stored one (clone likely recreated); kept the stored transcript"
          )
        end

        session.update!(
          transcript: content,
          metadata: (session.metadata || {}).merge("broadcast_message_count" => message_count)
        )
        session.logs.create!(content: "Transcript refreshed via MCP (#{message_count} messages)", level: "info")

        summary("Session Refreshed", session, message: "Transcript refreshed (#{message_count} messages)")
      end

      # Bulk sweep: restart failed sessions, continue auto-continuable paused ones.
      # Sessions in a frozen category are a parked bucket and stay parked.
      def refresh_all
        sessions = Session.not_in_frozen_category.where.not(status: :archived)

        if sessions.empty?
          return refresh_all_result("No non-archived sessions to refresh", 0, 0, 0, 0)
        end

        restarted = 0
        continued = 0
        errors = 0

        failed_sessions = sessions.where(status: :failed).limit(REFRESH_ALL_LIMIT).load
        remaining_limit = [ REFRESH_ALL_LIMIT - failed_sessions.size, 0 ].max
        needs_input_sessions = sessions
          .where(status: :needs_input)
          .where("metadata->>'paused_by' IS NULL OR metadata->>'paused_by' != 'user'")
          .limit(remaining_limit)

        failed_sessions.each do |session|
          if session.may_resume?
            session.resume!
            AgentSessionJob.enqueue_with_prompt(session.id, AutomatedPrompts::SYSTEM_RECOVERY)
            restarted += 1
          end
        rescue StandardError => e
          errors += 1
          Rails.logger.warn "[Mcp::Tools::ActionSession] Failed to restart session #{session.id}: #{e.message}"
        end

        needs_input_sessions.each do |session|
          if session.may_resume?
            session.resume!
            AgentSessionJob.enqueue_with_prompt(session.id, AutomatedPrompts::SYSTEM_RECOVERY)
            continued += 1
          end
        rescue StandardError => e
          errors += 1
          Rails.logger.warn "[Mcp::Tools::ActionSession] Failed to continue session #{session.id}: #{e.message}"
        end

        refresh_all_result("Refresh complete", 0, restarted, continued, errors)
      end

      def update_notes(session, args)
        notes = args["session_notes"]
        if notes.nil?
          raise ToolError, "The \"session_notes\" parameter is required for the \"update_notes\" action."
        end

        if notes.length > MAX_SESSION_NOTES_LENGTH
          raise ToolError, "Notes are too long (maximum #{MAX_SESSION_NOTES_LENGTH} characters)"
        end

        session.update!(
          session_notes: notes.presence,
          session_notes_updated_at: notes.present? ? Time.current : nil
        )

        [
          "## Session Notes Updated",
          "",
          "- **Session ID:** #{session.id}",
          "- **Title:** #{session.title}"
        ].join("\n")
      end

      def update_title(session, args)
        title = args["title"].to_s.strip
        raise ToolError, "The \"title\" parameter is required for the \"update_title\" action." if title.blank?

        session.update!(title: title)

        [
          "## Session Title Updated",
          "",
          "- **Session ID:** #{session.id}",
          "- **Title:** #{session.title}"
        ].join("\n")
      end

      def toggle_favorite(session)
        session.update!(favorited: !session.favorited)

        [
          "## Favorite Toggled",
          "",
          "- **Session ID:** #{session.id}",
          "- **Title:** #{session.title}",
          "- **Favorited:** #{session.favorited ? 'Yes' : 'No'}"
        ].join("\n")
      end

      def bulk_archive(args)
        session_ids = args["session_ids"]
        if !session_ids.is_a?(Array) || session_ids.empty?
          raise ToolError, "The \"session_ids\" parameter is required for the \"bulk_archive\" action."
        end

        archived_count = 0
        errors = []

        Session.where(id: session_ids).where.not(status: :archived).each do |session|
          if session.may_archive?
            session.archive!
            session.logs.create!(content: "Session archived via MCP (bulk)", level: "info")
            archived_count += 1
          else
            errors << { id: session.id, error: "Cannot archive from status: #{session.status}" }
          end
        end

        lines = [ "## Bulk Archive Complete", "", "- **Archived:** #{archived_count}" ]
        if errors.any?
          lines << "- **Errors:** #{errors.size}"
          errors.each { |err| lines << "  - Session #{err[:id]}: #{err[:error]}" }
        end
        lines.join("\n")
      end

      # --- Formatting -----------------------------------------------------------

      def follow_up_result(session, message)
        heading = message.downcase.include?("immediately") ? "Follow-up Sent Immediately" : "Follow-up Sent"

        lines = [
          "## #{heading}",
          "",
          "- **Session ID:** #{session.id}",
          "- **Title:** #{session.title}",
          "- **New Status:** #{session.status}",
          "- **Message:** #{message}"
        ]
        lines << "- **Job ID:** #{session.running_job_id}" if session.running_job_id.present?
        lines.join("\n")
      end

      def summary(heading, session, status_label: "Status", message: nil)
        lines = [
          "## #{heading}",
          "",
          "- **Session ID:** #{session.id}",
          "- **Title:** #{session.title}",
          "- **#{status_label}:** #{session.status}"
        ]
        lines << "- **Message:** #{message}" if message
        lines.join("\n")
      end

      def refresh_all_result(message, refreshed, restarted, continued, errors)
        [
          "## All Sessions Refreshed",
          "",
          "- **Message:** #{message}",
          "- **Refreshed:** #{refreshed}",
          "- **Restarted:** #{restarted}",
          "- **Continued:** #{continued}",
          "- **Errors:** #{errors}"
        ].join("\n")
      end

      def format_list(list)
        list.blank? ? "(none)" : list.join(", ")
      end

      # --- Helpers --------------------------------------------------------------

      def boolean(value)
        ActiveModel::Type::Boolean.new.cast(value) || false
      end

      def transcript_directory(session)
        path = session.metadata&.dig("working_directory") || session.metadata&.dig("clone_path")
        return nil unless path.is_a?(String) && path.present?

        File.join(File.expand_path("~"), ".claude", "projects", PathSanitizer.sanitize(path))
      rescue StandardError => e
        Rails.logger.error "[Mcp::Tools::ActionSession] Failed to get transcript directory: #{e.message}"
        nil
      end

      def count_transcript_messages(content)
        return 0 if content.blank?

        content.lines.count do |line|
          line.strip.present? && JSON.parse(line.strip)
        rescue JSON::ParserError
          false
        end
      end
    end
  end
end
