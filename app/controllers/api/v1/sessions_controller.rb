# API controller for managing agent sessions.
#
# Provides full CRUD operations plus additional actions for session lifecycle management:
# - archive/unarchive sessions
# - send follow-up prompts
# - pause/restart sessions
# - search sessions
#
# All endpoints require API key authentication via X-API-Key header.
class Api::V1::SessionsController < Api::BaseController
  require "automated_prompts"
  include SessionSearchable

  before_action :set_session, only: [ :show, :update, :destroy, :archive, :unarchive, :follow_up, :pause, :sleep_session, :restart, :fork, :refresh, :update_mcp_servers, :update_catalog_skills, :update_catalog_hooks, :update_catalog_plugins, :update_model, :transcript, :update_notes, :toggle_favorite, :update_heartbeat, :set_category ]

  # GET /api/v1/sessions
  # List all sessions with optional filtering and pagination.
  #
  # Query parameters:
  #   - status: Filter by status (waiting, running, needs_input, failed, archived)
  #   - agent_runtime: Filter by agent runtime
  #   - show_archived: Include archived sessions (default: false)
  #   - page: Page number (default: 1)
  #   - per_page: Results per page (default: 25, max: 100)
  def index
    scope = Session.includes(:category).order(created_at: :desc)

    # Filter by status
    scope = scope.where(status: params[:status]) if params[:status].present?

    # Filter by agent_runtime
    scope = scope.where(agent_runtime: params[:agent_runtime]) if params[:agent_runtime].present?

    # Exclude archived unless requested
    scope = scope.where.not(status: :archived) unless params[:show_archived] == "true"

    result = paginate(scope)

    render json: {
      sessions: result[:records].map { |s| session_json(s) },
      pagination: result[:pagination]
    }
  end

  # GET /api/v1/sessions/:id
  # Get a single session by ID or slug.
  def show
    render json: { session: session_json(@session, include_transcript: params[:include_transcript] == "true") }
  end

  # POST /api/v1/sessions
  # Create a new session and optionally start agent execution.
  #
  # Request body:
  #   - agent_root: Agent root name (resolves git_root, branch, subdirectory, mcp_servers, catalog_skills from catalog)
  #   - agent_runtime: Agent runtime override (default: the agent_root's default_runtime, falling back to "claude_code"). Must be a registered runtime.
  #   - prompt: Initial prompt for the agent (optional for clone-only sessions)
  #   - git_root: Repository URL or local path (overrides agent_root's URL if both provided)
  #   - branch: Git branch (default: "main")
  #   - subdirectory: Subdirectory within repo
  #   - title: Session title
  #   - slug: URL-friendly identifier
  #   - goal: High-level goal/stop-criteria for the session
  #   - mcp_servers: Array of MCP server names (overrides agent_root's defaults if provided)
  #   - catalog_skills: Array of skill names (overrides agent_root's defaults if provided)
  #   - catalog_hooks: Array of hook names (overrides agent_root's defaults if provided)
  #   - catalog_plugins: Array of plugin IDs (overrides agent_root's defaults if provided)
  #   - config: Additional configuration (JSON)
  #   - custom_metadata: Custom user metadata (JSON)
  def create
    @session = Session.new(session_params)

    # Resolve agent_root to git_root and defaults from the catalog
    resolve_agent_root_defaults!

    # Ensure model is always explicitly set in config, defaulting to the
    # resolved runtime's default model (ModelCatalog is the source of truth).
    unless @session.config&.dig("model").present?
      @session.config = (@session.config || {}).merge("model" => ModelCatalog.default_for(@session.agent_runtime))
    end

    if @session.save
      # Queue the agent job if a prompt was provided
      if @session.prompt.present?
        job = AgentSessionJob.enqueue_new_session(@session.id)
        @session.update(job_id: job.job_id)
      end

      render json: { session: session_json(@session) }, status: :created
    else
      render json: { error: "Validation failed", messages: @session.errors.full_messages }, status: :unprocessable_entity
    end
  rescue AgentRootsConfig::AgentRootNotFoundError => e
    render json: { error: "Invalid agent_root", message: e.message }, status: :unprocessable_entity
  end

  # PATCH/PUT /api/v1/sessions/:id
  # Update an existing session.
  # Note: Only certain fields can be updated based on session status.
  def update
    if @session.update(session_update_params)
      render json: { session: session_json(@session) }
    else
      render json: { error: "Validation failed", messages: @session.errors.full_messages }, status: :unprocessable_entity
    end
  end

  # DELETE /api/v1/sessions/:id
  # Delete a session and all associated logs and transcripts.
  def destroy
    @session.destroy!
    head :no_content
  end

  # POST /api/v1/sessions/:id/archive
  # Archive a session.
  def archive
    if @session.may_archive?
      @session.archive!
      render json: {
        session: session_json(@session.reload),
        message: "Session moved to trash",
        trash_after: @session.trash_after&.iso8601
      }
    else
      render json: { error: "Cannot trash", message: "Session cannot be trashed from current status: #{@session.status}" }, status: :unprocessable_entity
    end
  end

  # POST /api/v1/sessions/:id/unarchive
  # Restore a session from trash and restore Claude Code state.
  # This recreates the clone directory (if needed) and restores the transcript
  # so Claude Code can resume where it left off.
  def unarchive
    unless @session.archived?
      render json: { error: "Cannot restore", message: "Session is not in trash" }, status: :unprocessable_entity
      return
    end

    result = UnarchiveSessionService.call(session: @session)

    if result.success?
      render json: {
        session: session_json(@session.reload),
        clone_restored: result.clone_restored,
        message: result.clone_restored ? "Session restored from trash with clone restored" : "Session restored from trash"
      }
    else
      render json: { error: "Failed to restore", message: result.error }, status: :unprocessable_entity
    end
  end

  # POST /api/v1/sessions/:id/follow_up
  # Send a follow-up prompt to a session.
  #
  # Behavior depends on session status:
  # - running: Message is queued and will be sent when the agent completes its current task
  # - waiting/needs_input: Message is sent immediately
  # - failed/archived: Returns error
  #
  # When force_immediate is true, the message is always sent immediately regardless of
  # session state. If the session is running, it is paused first, then resumed with the
  # new prompt. This combines the create-and-interrupt pattern into a single API call.
  #
  # Request body:
  #   - prompt: The follow-up prompt text (required)
  #   - goal: Optional goal override
  #   - force_immediate: When true, sends immediately even if session is running (default: false)
  def follow_up
    prompt = params[:prompt].to_s.strip

    if prompt.blank?
      render json: { error: "Missing parameter", message: "prompt is required" }, status: :unprocessable_entity
      return
    end

    if prompt.length > Session::PROMPT_MAX_LENGTH
      render json: { error: "Validation failed", message: "prompt is too long (maximum #{Session::PROMPT_MAX_LENGTH} characters)" }, status: :unprocessable_entity
      return
    end

    goal = params[:goal].to_s.strip.presence
    force_immediate = params[:force_immediate] == true || params[:force_immediate] == "true"

    # When force_immediate is set, send immediately regardless of session state.
    # If the session is running, pause it first, then resume with the new prompt.
    if force_immediate
      unless @session.running? || @session.waiting? || @session.needs_input?
        render json: { error: "Cannot send follow-up", message: "Session is #{@session.status}. Follow-up prompts can only be sent to running, waiting, or needs_input sessions." }, status: :unprocessable_entity
        return
      end

      # Route force_immediate through the single race-free interrupt path
      # (Sessions::InterruptService) rather than pausing and resuming inline. This
      # is the same backend the web + API "Send Now" / interrupt buttons use, so
      # the "deliver now, terminating the current turn" behavior cannot diverge
      # across entry points. Critically, it inherits the per-session advisory
      # lock, exactly-once FIFO delivery, and the worker-side cross-container
      # termination the inline pause/resume lacked: inline pause/resume flipped
      # needs_input -> running within this one request and never reliably killed
      # the worker-spawned Claude CLI process, so the "immediate" send silently
      # degraded into ordinary post-turn queued delivery.
      enqueued_message = nil
      ActiveRecord::Base.transaction do
        max_position = @session.enqueued_messages.maximum(:position) || 0
        # Pass goal through on the message; EnqueuedMessageProcessorService applies
        # a non-blank message goal to the session when it claims the message.
        enqueued_message = @session.enqueued_messages.create!(
          content: prompt,
          goal: goal,
          position: max_position + 1,
          status: "pending"
        )
      end

      result = Sessions::InterruptService.new(
        session: @session,
        enqueued_message: enqueued_message,
        actor: "api_force_immediate"
      ).call

      if result.success?
        render json: { session: session_json(@session.reload), message: "Follow-up prompt sent immediately" }
      else
        # force_immediate is all-or-nothing: if the interrupt could not be
        # dispatched, remove the message we staged so it is not silently delivered
        # later as a surprise queued follow-up. A concurrent interrupt may have
        # already claimed/destroyed it (RecordNotFound) — that is fine.
        begin
          enqueued_message.reload
          enqueued_message.destroy! if enqueued_message.status == "pending"
        rescue ActiveRecord::RecordNotFound
          # already claimed by a concurrent interrupt — nothing to clean up
        end
        render json: { error: "Cannot send follow-up", message: result.error }, status: (result.error_code || :internal_server_error)
      end
      return
    end

    # When session is running, queue the message instead of rejecting.
    # This prevents message loss when the caller doesn't know the exact session state
    # (e.g., race condition between session completing a turn and the API call arriving).
    if @session.running?
      max_position = @session.enqueued_messages.maximum(:position) || 0
      enqueued_message = @session.enqueued_messages.create!(
        content: prompt,
        goal: goal,
        position: max_position + 1,
        status: "pending"
      )
      @session.logs.create!(
        content: "Message queued at position #{enqueued_message.position} (session is running)",
        level: "info"
      )
      render json: {
        session: session_json(@session.reload),
        enqueued_message: {
          id: enqueued_message.id,
          position: enqueued_message.position,
          status: enqueued_message.status
        },
        message: "Message queued (session is running). It will be sent when the agent completes its current task."
      }, status: :accepted
      return
    end

    # For waiting/needs_input sessions, send immediately
    unless @session.waiting? || @session.needs_input?
      render json: { error: "Cannot send follow-up", message: "Session is #{@session.status}. Follow-up prompts can only be sent to running, waiting, or needs_input sessions." }, status: :unprocessable_entity
      return
    end

    ActiveRecord::Base.transaction do
      @session.update!(prompt: prompt)
      @session.resume! if @session.may_resume?
      job = AgentSessionJob.enqueue_with_prompt(@session.id, prompt)
      @session.update!(running_job_id: job.job_id)
    end

    render json: { session: session_json(@session.reload), message: "Follow-up prompt sent" }
  rescue ActiveRecord::RecordInvalid => e
    render json: { error: "Validation failed", message: e.message }, status: :unprocessable_entity
  rescue ActiveRecord::RecordNotUnique
    render json: { error: "Conflict", message: "Message position conflict, please retry" }, status: :conflict
  end

  # POST /api/v1/sessions/:id/pause
  # Pause a running session.
  def pause
    if @session.running?
      # Mark as user-initiated pause so push notification is skipped
      @session.update!(metadata: (@session.metadata || {}).merge("paused_by" => "user"))
      @session.pause!
      render json: { session: session_json(@session) }
    else
      render json: { error: "Cannot pause", message: "Session is not running" }, status: :unprocessable_entity
    end
  end

  # POST /api/v1/sessions/:id/sleep
  # Transition a session to waiting (dormant).
  # Used by the "wake me up later" workflow — the session becomes dormant
  # and a one-time schedule trigger will resume it at the specified time.
  #
  # Accepts both needs_input (immediate sleep) and running (deferred sleep).
  # When called from running state, sets a pending_sleep flag in metadata.
  # The pause callback executes the sleep after the agent's turn completes.
  def sleep_session
    unless @session.needs_input? || @session.running?
      render json: { error: "Cannot sleep", message: "Session must be in needs_input or running state to sleep (current: #{@session.status})" }, status: :unprocessable_entity
      return
    end

    if @session.needs_input?
      @session.sleep!
    else
      @session.update!(metadata: (@session.metadata || {}).merge("pending_sleep" => true))
    end

    render json: { session: session_json(@session) }
  end

  # POST /api/v1/sessions/:id/restart
  # Restart a failed or paused session by clearing stale metadata and
  # enqueuing a recovery prompt to spawn a new CLI process.
  def restart
    unless @session.may_resume?
      render json: { error: "Cannot restart", message: "Session cannot be restarted from current status: #{@session.status}" }, status: :unprocessable_entity
      return
    end

    # When setup never completed (e.g., git clone failed), re-run the full setup
    # pipeline instead of trying to send a follow-up prompt to a non-existent clone.
    if @session.failed_before_initial_prompt? && !@session.setup_complete?
      restart_from_scratch(@session)
      return
    end

    # For sessions with complete setup artifacts, only require session_id.
    # The job handles clone recreation if the working directory is missing.
    unless @session.session_id.present?
      render json: { error: "Cannot restart", message: "Session has no session_id" }, status: :unprocessable_entity
      return
    end

    # Determine restart prompt: re-send original for pre-prompt failures,
    # otherwise use system recovery message.
    # NOTE: This check must happen BEFORE clearing stale metadata (which removes failure_reason).
    use_initial_prompt = @session.failed_before_initial_prompt? && @session.prompt.present?
    restart_prompt = use_initial_prompt ? @session.prompt : AutomatedPrompts::SYSTEM_RECOVERY

    ActiveRecord::Base.transaction do
      # Clear stale retry and transcript polling metadata before resuming.
      # See Session::STALE_RETRY_METADATA_KEYS for the full list of keys cleared.
      cleaned_metadata = (@session.metadata || {}).except(*Session::STALE_RETRY_METADATA_KEYS)

      # For pre-prompt failures, also clear runtime_started so the restart
      # uses --session-id (with --mcp-config) instead of --resume.
      cleaned_metadata = cleaned_metadata.except("runtime_started") if use_initial_prompt

      @session.update!(
        running_job_id: nil,
        metadata: cleaned_metadata
      )
      @session.resume!

      AgentSessionJob.enqueue_with_prompt(@session.id, restart_prompt)
    end

    render json: { session: session_json(@session.reload), message: "Session restarted" }
  end

  # POST /api/v1/sessions/:id/fork
  # Fork a session at a specific message index to create an alternative branch.
  #
  # Request body:
  #   - message_index: Index of the transcript message to fork from (required)
  def fork
    if params[:message_index].blank?
      render json: { error: "Missing parameter", message: "message_index is required" }, status: :unprocessable_entity
      return
    end

    result = ForkSessionService.call(
      source_session: @session,
      message_index: params[:message_index].to_i
    )

    if result.success?
      render json: { session: session_json(result.forked_session), message: "Session forked successfully" }, status: :created
    else
      render json: { error: "Fork failed", message: result.error }, status: :unprocessable_entity
    end
  end

  # POST /api/v1/sessions/:id/refresh
  # Re-read transcript from filesystem and recover orphaned jobs.
  def refresh
    transcript_dir = get_transcript_directory_for_session(@session)

    if transcript_dir.nil?
      render json: { error: "No clone path", message: "No clone path found for this session" }, status: :unprocessable_entity
      return
    end

    if Dir.exist?(transcript_dir)
      main_transcript_file = find_main_transcript_file_for_session(@session, transcript_dir)

      if main_transcript_file
        transcript_content = File.read(main_transcript_file)
        message_count = count_transcript_messages(transcript_content)

        # Never let a refresh shrink the stored transcript. A shorter filesystem
        # transcript means the clone was recreated at a new path and started a fresh
        # file; session.transcript is the only durable record, so we keep the longer
        # stored copy instead of destroying history. Response shape is unchanged.
        if Session.transcript_regression?(@session.transcript, transcript_content)
          Rails.logger.warn "[Api::V1::SessionsController#refresh] Refused transcript regression for session #{@session.id} (stored #{Session.transcript_line_count(@session.transcript)} events, filesystem #{message_count}); preserving stored transcript"
          render json: { session: session_json(@session), message: "Filesystem transcript is shorter than the stored one (clone likely recreated); kept the stored transcript" }
          return
        end

        @session.update!(
          transcript: transcript_content,
          metadata: (@session.metadata || {}).merge("broadcast_message_count" => message_count)
        )

        @session.logs.create!(
          content: "Transcript refreshed via API (#{message_count} messages)",
          level: "info"
        )

        render json: { session: session_json(@session), message: "Transcript refreshed (#{message_count} messages)" }
        return
      end
    end

    render json: { error: "Not found", message: "No transcript files found on filesystem" }, status: :not_found
  rescue => e
    render json: { error: "Refresh failed", message: e.message }, status: :internal_server_error
  end

  # POST /api/v1/sessions/refresh_all
  # Bulk refresh all non-archived sessions: restart failed, continue paused, refresh running.
  # Sessions in a frozen category are a parked bucket and are intentionally excluded.
  def refresh_all
    sessions = Session.not_in_frozen_category.where.not(status: :archived)

    if sessions.empty?
      render json: { message: "No non-archived sessions to refresh", refreshed: 0, restarted: 0, continued: 0, errors: 0 }
      return
    end

    refreshed_count = 0
    restarted_count = 0
    continued_count = 0
    error_count = 0
    bulk_limit = 50

    # Auto-continuable needs_input sessions (not user-paused)
    auto_continuable = sessions
      .where(status: :needs_input)
      .where("metadata->>'paused_by' IS NULL OR metadata->>'paused_by' != 'user'")

    failed_sessions = sessions.where(status: :failed).limit(bulk_limit).load
    remaining_limit = [ bulk_limit - failed_sessions.size, 0 ].max
    needs_input_sessions = auto_continuable.limit(remaining_limit)

    # Restart failed sessions
    failed_sessions.each do |session|
      begin
        if session.may_resume?
          session.resume!
          AgentSessionJob.enqueue_with_prompt(session.id, AutomatedPrompts::SYSTEM_RECOVERY)
          restarted_count += 1
        end
      rescue => e
        error_count += 1
        Rails.logger.warn "[API refresh_all] Failed to restart session #{session.id}: #{e.message}"
      end
    end

    # Continue auto-continuable paused sessions
    needs_input_sessions.each do |session|
      begin
        if session.may_resume?
          session.resume!
          AgentSessionJob.enqueue_with_prompt(session.id, AutomatedPrompts::SYSTEM_RECOVERY)
          continued_count += 1
        end
      rescue => e
        error_count += 1
        Rails.logger.warn "[API refresh_all] Failed to continue session #{session.id}: #{e.message}"
      end
    end

    render json: {
      message: "Refresh complete",
      refreshed: refreshed_count,
      restarted: restarted_count,
      continued: continued_count,
      errors: error_count
    }
  end

  # PATCH /api/v1/sessions/:id/mcp_servers
  # Update MCP servers for a session.
  #
  # Request body:
  #   - mcp_servers: Array of MCP server names (max 50)
  def update_mcp_servers
    mcp_servers = params[:mcp_servers] || []

    unless mcp_servers.is_a?(Array)
      render json: { error: "Invalid parameter", message: "mcp_servers must be an array" }, status: :unprocessable_entity
      return
    end

    if mcp_servers.length > 50
      render json: { error: "Too many servers", message: "Maximum 50 MCP servers" }, status: :unprocessable_entity
      return
    end

    mcp_servers = mcp_servers.reject(&:blank?).map { |s| s.to_s.strip.first(100) }

    # Validate server names
    invalid_servers = mcp_servers.reject { |name| ServersConfig.exists?(name) }
    if invalid_servers.any?
      render json: { error: "Invalid servers", message: "Invalid MCP servers: #{invalid_servers.join(', ')}" }, status: :unprocessable_entity
      return
    end

    old_servers = @session.mcp_servers || []

    if @session.update(mcp_servers: mcp_servers)
      added = mcp_servers - old_servers
      removed = old_servers - mcp_servers

      # A deliberate removal is not an unexplained loss — forget its status so
      # later config regenerations don't report it as one.
      @session.forget_mcp_server_status!(removed)

      changes = []
      changes << "added: #{added.join(', ')}" if added.any?
      changes << "removed: #{removed.join(', ')}" if removed.any?

      if changes.any?
        @session.logs.create!(content: "MCP servers updated via API (#{changes.join('; ')})", level: "info")
      end

      render json: { session: session_json(@session), message: "MCP servers updated" }
    else
      render json: { error: "Update failed", messages: @session.errors.full_messages }, status: :unprocessable_entity
    end
  end

  # PATCH /api/v1/sessions/:id/catalog_skills
  # Update catalog skills for a session.
  #
  # Request body:
  #   - catalog_skills: Array of skill names (max 100)
  def update_catalog_skills
    catalog_skills = params[:catalog_skills] || []

    unless catalog_skills.is_a?(Array)
      render json: { error: "Invalid parameter", message: "catalog_skills must be an array" }, status: :unprocessable_entity
      return
    end

    if catalog_skills.length > SessionsController::MAX_CATALOG_SKILLS
      render json: { error: "Too many skills", message: "Maximum #{SessionsController::MAX_CATALOG_SKILLS} catalog skills" }, status: :unprocessable_entity
      return
    end

    catalog_skills = catalog_skills.reject(&:blank?).map { |s| s.to_s.strip.first(SessionsController::MAX_CATALOG_SKILL_NAME_LENGTH) }

    invalid_skills = catalog_skills.reject { |name| SkillsConfig.exists?(name) }
    if invalid_skills.any?
      render json: { error: "Invalid skills", message: "Invalid catalog skills: #{invalid_skills.join(', ')}" }, status: :unprocessable_entity
      return
    end

    old_skills = @session.catalog_skills || []

    if @session.update(catalog_skills: catalog_skills)
      added = catalog_skills - old_skills
      removed = old_skills - catalog_skills
      changes = []
      changes << "added: #{added.join(', ')}" if added.any?
      changes << "removed: #{removed.join(', ')}" if removed.any?

      if changes.any?
        @session.logs.create!(content: "Catalog skills updated via API (#{changes.join('; ')})", level: "info")
      end

      render json: { session: session_json(@session), message: "Catalog skills updated" }
    else
      render json: { error: "Update failed", messages: @session.errors.full_messages }, status: :unprocessable_entity
    end
  end

  # PATCH /api/v1/sessions/:id/catalog_hooks
  def update_catalog_hooks
    catalog_hooks = params[:catalog_hooks] || []

    unless catalog_hooks.is_a?(Array)
      render json: { error: "Invalid parameter", message: "catalog_hooks must be an array" }, status: :unprocessable_entity
      return
    end

    if catalog_hooks.length > SessionsController::MAX_CATALOG_HOOKS
      render json: { error: "Too many hooks", message: "Maximum #{SessionsController::MAX_CATALOG_HOOKS} catalog hooks" }, status: :unprocessable_entity
      return
    end

    catalog_hooks = catalog_hooks.reject(&:blank?).map { |s| s.to_s.strip.first(SessionsController::MAX_CATALOG_HOOK_NAME_LENGTH) }

    invalid_hooks = catalog_hooks.reject { |name| HooksConfig.exists?(name) }
    if invalid_hooks.any?
      render json: { error: "Invalid hooks", message: "Invalid catalog hooks: #{invalid_hooks.join(', ')}" }, status: :unprocessable_entity
      return
    end

    old_hooks = @session.catalog_hooks || []

    if @session.update(catalog_hooks: catalog_hooks)
      added = catalog_hooks - old_hooks
      removed = old_hooks - catalog_hooks
      changes = []
      changes << "added: #{added.join(', ')}" if added.any?
      changes << "removed: #{removed.join(', ')}" if removed.any?

      if changes.any?
        @session.logs.create!(content: "Catalog hooks updated via API (#{changes.join('; ')})", level: "info")
      end

      render json: { session: session_json(@session), message: "Catalog hooks updated" }
    else
      render json: { error: "Update failed", messages: @session.errors.full_messages }, status: :unprocessable_entity
    end
  end

  # PATCH /api/v1/sessions/:id/catalog_plugins
  def update_catalog_plugins
    catalog_plugins = params[:catalog_plugins] || []

    unless catalog_plugins.is_a?(Array)
      render json: { error: "Invalid parameter", message: "catalog_plugins must be an array" }, status: :unprocessable_entity
      return
    end

    if catalog_plugins.length > SessionsController::MAX_CATALOG_PLUGINS
      render json: { error: "Too many plugins", message: "Maximum #{SessionsController::MAX_CATALOG_PLUGINS} catalog plugins" }, status: :unprocessable_entity
      return
    end

    catalog_plugins = catalog_plugins.reject(&:blank?).map { |s| s.to_s.strip.first(SessionsController::MAX_CATALOG_PLUGIN_ID_LENGTH) }

    invalid_plugins = catalog_plugins.reject { |id| PluginsConfig.exists?(id) }
    if invalid_plugins.any?
      render json: { error: "Invalid plugins", message: "Invalid catalog plugins: #{invalid_plugins.join(', ')}" }, status: :unprocessable_entity
      return
    end

    old_plugins = @session.catalog_plugins || []

    if @session.update(catalog_plugins: catalog_plugins)
      added = catalog_plugins - old_plugins
      removed = old_plugins - catalog_plugins
      changes = []
      changes << "added: #{added.join(', ')}" if added.any?
      changes << "removed: #{removed.join(', ')}" if removed.any?

      if changes.any?
        @session.logs.create!(content: "Catalog plugins updated via API (#{changes.join('; ')})", level: "info")
      end

      regenerate_mcp_config_file(@session)

      render json: { session: session_json(@session), message: "Catalog plugins updated" }
    else
      render json: { error: "Update failed", messages: @session.errors.full_messages }, status: :unprocessable_entity
    end
  end

  # PATCH /api/v1/sessions/:id/model
  # Update the model for a session.
  #
  # Request body:
  #   - model: String model identifier. Must be valid for the session's
  #     agent_runtime (e.g. "opus", "sonnet", "haiku" for claude_code).
  def update_model
    model = params[:model]

    unless model.is_a?(String) && model.present?
      render json: { error: "Invalid parameter", message: "model must be a non-empty string" }, status: :unprocessable_entity
      return
    end

    model = model.strip.first(100)

    # Reject models that don't belong to the session's runtime catalog.
    unless ModelCatalog.valid_model?(@session.agent_runtime, model)
      allowed = ModelCatalog.model_ids_for(@session.agent_runtime)
      render json: { error: "Invalid model", message: "model #{model.inspect} is not valid for runtime #{@session.agent_runtime}. Valid models: #{allowed.join(', ')}" }, status: :unprocessable_entity
      return
    end

    old_model = @session.config&.dig("model")
    new_config = (@session.config || {}).merge("model" => model)

    if @session.update(config: new_config)
      if old_model != model
        @session.logs.create!(content: "Model updated via API (#{old_model} → #{model})", level: "info")
      end

      render json: { session: session_json(@session), message: "Model updated" }
    else
      render json: { error: "Update failed", messages: @session.errors.full_messages }, status: :unprocessable_entity
    end
  end

  # GET /api/v1/sessions/:id/transcript
  # Get a formatted plain-text transcript for a session.
  def transcript
    parsed = @session.parsed_transcript
    if parsed.blank?
      render json: { error: "No transcript", message: "No transcript available for this session" }, status: :not_found
      return
    end

    lines = []
    parsed.each do |entry|
      type = entry["type"]
      message = entry["message"] || entry
      content = message["content"] || ""
      role = message["role"]

      case type
      when "user"
        lines << "--- User ---"
        lines << content
        lines << ""
      when "assistant"
        lines << "--- Assistant ---"
        lines << content
        lines << ""
      when "tool_use"
        tool_name = message["name"] || "unknown"
        lines << "--- Tool Use: #{tool_name} ---"
        lines << content.to_s unless content.blank?
        lines << ""
      when "tool_result"
        lines << "--- Tool Result ---"
        lines << content.to_s.truncate(500) unless content.blank?
        lines << ""
      end
    end

    if params[:format] == "text"
      render plain: lines.join("\n"), content_type: "text/plain"
    else
      render json: { transcript_text: lines.join("\n") }
    end
  end

  # PATCH /api/v1/sessions/:id/notes
  # Update session notes.
  #
  # Request body:
  #   - session_notes: Notes text (max 50,000 chars, blank to clear)
  def update_notes
    notes = params[:session_notes]

    if notes.present? && notes.length > 50_000
      render json: { error: "Too long", message: "Notes are too long (maximum 50,000 characters)" }, status: :unprocessable_entity
      return
    end

    if @session.update(session_notes: notes.presence, session_notes_updated_at: notes.present? ? Time.current : nil)
      render json: {
        session: session_json(@session),
        session_notes_updated_at: @session.session_notes_updated_at&.iso8601
      }
    else
      render json: { error: "Update failed", messages: @session.errors.full_messages }, status: :unprocessable_entity
    end
  end

  # POST /api/v1/sessions/:id/toggle_favorite
  # Toggle the favorited status of a session.
  def toggle_favorite
    @session.update!(favorited: !@session.favorited)
    render json: { session: session_json(@session), favorited: @session.favorited }
  end

  # PATCH /api/v1/sessions/:id/heartbeat
  # Enable/disable the per-session heartbeat and/or set its interval. Both params
  # are optional; omitting a param leaves that setting unchanged.
  #
  # Params:
  #   - enabled: boolean — turn the heartbeat on/off
  #   - interval_seconds: integer — how often the heart beats
  #     (#{Session::HEARTBEAT_MIN_INTERVAL_SECONDS}–#{Session::HEARTBEAT_MAX_INTERVAL_SECONDS})
  def update_heartbeat
    attrs = {}

    unless params[:enabled].nil?
      casted = ActiveModel::Type::Boolean.new.cast(params[:enabled])
      # cast("") / cast("maybe") => nil; reject rather than let a nil reach the
      # NOT NULL column (which would surface as a 500, not a 422).
      if casted.nil?
        render json: { error: "Validation failed", message: "enabled must be a boolean" }, status: :unprocessable_entity
        return
      end
      attrs[:heartbeat_enabled] = casted
    end

    unless params[:interval_seconds].nil?
      interval = params[:interval_seconds]
      unless interval.to_s.match?(/\A\d+\z/)
        render json: { error: "Validation failed", message: "interval_seconds must be an integer" }, status: :unprocessable_entity
        return
      end
      attrs[:heartbeat_interval_seconds] = interval.to_i
    end

    if attrs.empty?
      render json: { error: "Missing parameter", message: "Provide enabled and/or interval_seconds" }, status: :unprocessable_entity
      return
    end

    @session.update!(attrs)
    render json: {
      session: session_json(@session),
      heartbeat_enabled: @session.heartbeat_enabled,
      heartbeat_interval_seconds: @session.heartbeat_interval_seconds
    }
  rescue ActiveRecord::RecordInvalid => e
    render json: { error: "Validation failed", message: e.message }, status: :unprocessable_entity
  end

  # PATCH /api/v1/sessions/:id/set_category
  # Assign (or clear) a session's organizational category. A blank/absent
  # category_id moves the session back to "Uncategorized".
  #
  # Request body:
  #   - category_id: Target category id, or blank/null to clear (Uncategorized)
  def set_category
    category_id = params[:category_id].presence

    if category_id.present?
      category = Category.find_by(id: category_id)
      unless category
        render json: { error: "Not Found", message: "Category ##{category_id} not found" }, status: :not_found
        return
      end
      @session.update!(category_id: category.id)
    else
      @session.update!(category_id: nil)
    end

    render json: {
      session: session_json(@session),
      message: @session.category_id ? "Session assigned to category" : "Session moved to Uncategorized"
    }
  end

  # POST /api/v1/sessions/bulk_archive
  # Archive multiple sessions at once.
  #
  # Request body:
  #   - session_ids: Array of session IDs to archive (required)
  def bulk_archive
    session_ids = params[:session_ids]

    if session_ids.blank? || !session_ids.is_a?(Array)
      render json: { error: "Missing parameter", message: "session_ids array is required" }, status: :unprocessable_entity
      return
    end

    sessions = Session.where(id: session_ids).where.not(status: :archived)
    archived_count = 0
    errors = []

    sessions.each do |session|
      if session.may_archive?
        session.archive!
        session.logs.create!(content: "Session archived via API (bulk)", level: "info")
        archived_count += 1
      else
        errors << { id: session.id, message: "Cannot archive from status: #{session.status}" }
      end
    end

    render json: { archived_count: archived_count, errors: errors }
  end

  # GET /api/v1/sessions/search
  # Search sessions by query string.
  #
  # Query parameters:
  #   - q: Search query (required) - searches title, metadata, and custom_metadata
  #   - search_contents: Set to "true" to also search transcript contents
  #   - status: Filter by status (waiting, running, needs_input, failed, archived)
  #   - agent_runtime: Filter by agent runtime
  #   - show_archived: Include archived sessions (default: false)
  #   - page: Page number (default: 1)
  #   - per_page: Results per page (default: 25, max: 100)
  def search
    query = params[:q].to_s.strip

    if query.blank?
      render json: { error: "Missing parameter", message: "q (search query) is required" }, status: :bad_request
      return
    end

    # Validate query length to prevent performance issues
    if query.length > 1000
      render json: { error: "Query too long", message: "Maximum query length is 1000 characters" }, status: :bad_request
      return
    end

    scope = Session.includes(:category).order(created_at: :desc)

    # Filter by status
    scope = scope.where(status: params[:status]) if params[:status].present?

    # Filter by agent_runtime
    scope = scope.where(agent_runtime: params[:agent_runtime]) if params[:agent_runtime].present?

    # Exclude archived unless requested
    scope = scope.where.not(status: :archived) unless params[:show_archived] == "true"

    # Apply search filter
    include_contents = params[:search_contents] == "true"
    scope = filter_sessions_by_search(scope, query, include_contents: include_contents)

    result = paginate(scope)

    render json: {
      query: query,
      search_contents: include_contents,
      sessions: result[:records].map { |s| session_json(s) },
      pagination: result[:pagination]
    }
  end

  private

  # Restart a session from scratch by re-running the full setup pipeline.
  # Used when setup never completed (e.g., git clone failed).
  def restart_from_scratch(session)
    unless session.git_root.present?
      render json: { error: "Cannot restart", message: "No git_root configured for restart from scratch" }, status: :unprocessable_entity
      return
    end

    cleaned_metadata = (session.metadata || {}).except(
      *Session::STALE_RETRY_METADATA_KEYS,
      *Session::SETUP_ARTIFACT_KEYS
    )

    ActiveRecord::Base.transaction do
      session.logs.create!(
        content: "Restarting session from scratch: re-running full setup pipeline (git clone, MCP config, process spawn)",
        level: "info"
      )

      session.update!(
        running_job_id: nil,
        session_id: nil,
        metadata: cleaned_metadata
      )
      session.resume! if session.may_resume?
      AgentSessionJob.enqueue_new_session(session.id)

      session.logs.create!(
        content: "Session resumed - status changed to running, full setup will be re-attempted",
        level: "info"
      )
    end

    render json: { session: session_json(session.reload), message: "Session restarted from scratch" }
  rescue => e
    Rails.logger.error "[Api::V1::SessionsController] Error restarting session #{session.id} from scratch: #{e.message}"
    session.logs.create(
      content: "Error restarting session from scratch: #{e.message}",
      level: "error"
    )
    render json: { error: "Cannot restart", message: e.message }, status: :internal_server_error
  end

  def set_session
    # Try to find by slug first, then by ID
    @session = Session.find_by(slug: params[:id]) || Session.find(params[:id])
  end

  def session_params
    params.permit(
      :agent_runtime, :prompt, :git_root, :branch, :subdirectory,
      :title, :slug, :goal, :execution_provider, :is_autonomous,
      :parent_session_id, :auto_compact_window,
      mcp_servers: [], catalog_skills: [], catalog_hooks: [], catalog_plugins: [], config: {}, custom_metadata: {}
    )
  end

  # Resolve agent_root param to git_root and apply catalog defaults.
  # Explicit params (git_root, branch, subdirectory, mcp_servers, catalog_skills, catalog_hooks, catalog_plugins)
  # take precedence over agent root defaults.
  def resolve_agent_root_defaults!
    agent_root_name = params[:agent_root]&.to_s&.strip
    return unless agent_root_name.present?

    agent_root = AgentRootsConfig.find!(agent_root_name)

    # An explicit agent_runtime param (the per-spawn override) wins; otherwise the
    # session adopts the agent root's declared runtime rather than the column
    # default, so spawning under a non-default-runtime root carries that runtime.
    @session.agent_runtime = agent_root.default_runtime unless params[:agent_runtime].present?
    @session.git_root = agent_root.url if @session.git_root.blank?
    @session.branch = agent_root.default_branch || "main" unless params[:branch].present?
    @session.subdirectory = agent_root.subdirectory if @session.subdirectory.blank? && agent_root.subdirectory.present?
    @session.mcp_servers = agent_root.default_mcp_servers || [] if @session.mcp_servers.blank?
    @session.catalog_skills = agent_root.default_skills || [] if @session.catalog_skills.blank?
    @session.catalog_hooks = agent_root.default_hooks || [] if @session.catalog_hooks.blank?
    @session.catalog_plugins = agent_root.default_plugins || [] if @session.catalog_plugins.blank?
    @session.metadata = (@session.metadata || {}).merge("agent_root_key" => agent_root_name)

    # When the caller didn't specify a model, adopt the agent root's default
    # (which already folds in the global base default). A root's default is
    # typically a claude_code model (e.g. "opus"); applying it unconditionally to
    # a codex spawn would persist an invalid model, so self-heal to the global
    # base default for the resolved runtime (falling back to that runtime's
    # catalog default) whenever the root's model isn't valid for the runtime.
    if @session.config&.dig("model").blank?
      model = agent_root.default_model
      unless ModelCatalog.valid_model?(@session.agent_runtime, model)
        model = AppSetting.current.resolved_default_model_for(@session.agent_runtime)
      end
      @session.config = (@session.config || {}).merge("model" => model)
    end
  end

  def session_update_params
    params.permit(:title, :slug, :goal, :is_autonomous, custom_metadata: {})
  end

  def regenerate_mcp_config_file(session)
    working_directory = session.metadata&.dig("working_directory")
    return unless working_directory.present? && Dir.exist?(working_directory)

    air_service = AirPrepareService.new(
      session: session,
      working_directory: working_directory
    )
    air_service.prepare!

    Rails.logger.info "AIR prepare completed for session #{session.id} at #{working_directory}"
  rescue => e
    Rails.logger.error "Failed to run AIR prepare for session #{session.id}: #{e.message}"
  end

  def session_json(session, include_transcript: false)
    json = {
      id: session.id,
      slug: session.slug,
      title: session.title,
      status: session.status,
      agent_runtime: session.agent_runtime,
      prompt: session.prompt,
      git_root: session.git_root,
      branch: session.branch,
      subdirectory: session.subdirectory,
      execution_provider: session.execution_provider,
      goal: session.goal,
      mcp_servers: session.mcp_servers,
      # `mcp_servers` is only the explicitly-selected list. Consumers asking
      # "which MCP servers does this session actually have wired?" must read
      # `all_mcp_servers` — the effective set, including plugin-bundled and
      # Zimmer-auto-injected servers. `injected_mcp_servers` is the auto-injected
      # subset alone (e.g. the self-session server); on a healthy session it
      # legitimately omits every user-selected server, so it must never be read
      # as the effective set.
      all_mcp_servers: session.all_mcp_servers,
      injected_mcp_servers: session.injected_mcp_servers,
      catalog_skills: session.catalog_skills,
      catalog_hooks: session.catalog_hooks,
      catalog_plugins: session.catalog_plugins,
      config: session.config,
      metadata: session.metadata,
      custom_metadata: session.custom_metadata,
      is_autonomous: session.is_autonomous,
      heartbeat_enabled: session.heartbeat_enabled,
      heartbeat_interval_seconds: session.heartbeat_interval_seconds,
      auto_compact_window: session.auto_compact_window,
      category_id: session.category_id,
      category: category_summary(session.category),
      session_id: session.session_id,
      job_id: session.job_id,
      running_job_id: session.running_job_id,
      archived_at: session.archived_at&.iso8601,
      trash_after: session.trash_after&.iso8601,
      created_at: session.created_at.iso8601,
      updated_at: session.updated_at.iso8601
    }

    json[:session_notes] = session.session_notes
    json[:session_notes_updated_at] = session.session_notes_updated_at&.iso8601
    json[:favorited] = session.favorited
    json[:transcript] = session.transcript if include_transcript

    json
  end

  # Compact representation of the session's category (nil when Uncategorized).
  def category_summary(category)
    return nil unless category

    {
      id: category.id,
      name: category.name,
      position: category.position,
      is_frozen: category.is_frozen
    }
  end

  # Transcript directory helpers (shared with web SessionsController)

  def get_transcript_directory_for_session(session)
    working_directory = session.metadata&.dig("working_directory")
    clone_path = session.metadata&.dig("clone_path")
    path_to_use = working_directory || clone_path
    return nil unless path_to_use.is_a?(String) && path_to_use.present?

    home_dir = File.expand_path("~")
    claude_projects_dir = File.join(home_dir, ".claude", "projects")
    sanitized_path = PathSanitizer.sanitize(path_to_use)
    File.join(claude_projects_dir, sanitized_path)
  rescue => e
    Rails.logger.error "Failed to get transcript directory: #{e.message}"
    nil
  end

  def find_main_transcript_file_for_session(session, transcript_dir)
    TranscriptFileLocator.find_main_transcript(session, transcript_dir)
  end

  def count_transcript_messages(transcript_content)
    return 0 unless transcript_content.present?

    transcript_content.lines.count do |line|
      line.strip.present? && JSON.parse(line.strip)
    rescue JSON::ParserError
      false
    end
  end
end
