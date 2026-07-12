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
      ACTION_DESC = 'Action to perform: "follow_up", "pause", "restart", "archive", "unarchive", "change_mcp_servers", "change_model", "set_heartbeat", "fork", "refresh", "refresh_all", "update_notes", "update_title", "toggle_favorite", "bulk_archive"'
      PROMPT_DESC = 'Required for "follow_up" action. The prompt to send to the agent. Not used for other actions.'
      FORCE_IMMEDIATE_DESC = 'Optional for "follow_up" action. When true, interrupts a running session to deliver the prompt immediately instead of queuing it. Not used for other actions.'
      MCP_SERVERS_DESC = 'Required for "change_mcp_servers" action. Array of MCP server names to set for the session.'
      MODEL_DESC = 'Required for "change_model" action. The model identifier to use (e.g., "opus", "sonnet").'
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
      MAX_SESSION_NOTES_LENGTH = 50_000
      REFRESH_ALL_LIMIT = 50

      description <<~DESC
        Perform an action on an agent session.

        **Actions:**
        - **follow_up**: Send a follow-up prompt to a session (requires "prompt"; optional "force_immediate" to interrupt a running session). Without "force_immediate", uses smart routing: sends immediately if idle, auto-queues if running. Alternative: use manage_enqueued_messages "send_now" for one-step immediate delivery with goal support.
        - **pause**: Pause a running session, transitioning it to idle "needs_input" status
        - **restart**: Restart an idle or failed session without providing new input
        - **archive**: Archive a session (marks as completed)
        - **unarchive**: Restore an archived session to idle "needs_input" status
        - **change_mcp_servers**: Update the MCP servers for a session (requires "mcp_servers" parameter)
        - **change_model**: Update the model for a session (requires "model" parameter, e.g., "opus", "sonnet")
        - **set_heartbeat**: Toggle a session's heartbeat and/or set its interval (provide "enabled" and/or "interval_seconds"). When enabled and the session sits in needs_input, a recurring nudge prompts it to keep working toward its goal; set "enabled" to false to stop the nudges.
        - **fork**: Fork a session from a specific transcript message (requires "message_index")
        - **refresh**: Refresh a single session's status from the execution provider
        - **refresh_all**: Refresh all active sessions (no session_id needed)
        - **update_notes**: Update the notes on a session (requires "session_notes")
        - **update_title**: Update the title of a session (requires "title")
        - **toggle_favorite**: Toggle favorite status on a session
        - **bulk_archive**: Archive multiple sessions at once (requires "session_ids", no session_id needed)

        **Use cases:**
        - Provide additional instructions to an agent
        - Control session lifecycle (pause, restart, fork, refresh)
        - Organize sessions (archive, unarchive, bulk_archive, toggle_favorite, update_notes, update_title)
        - Reconfigure session MCP server access
        - Change the model used by a session
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
