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
  include ApiSessionSerialization
  include SessionTranscriptLookup

  before_action :set_session, only: [ :show, :update, :destroy, :archive, :unarchive, :follow_up, :pause, :sleep_session, :restart, :fork, :regenerate_status_summary, :refresh, :update_mcp_servers, :update_catalog_skills, :update_catalog_hooks, :update_catalog_plugins, :update_model, :transcript, :update_notes, :toggle_favorite, :update_visibility, :update_heartbeat, :set_category ]

  # GET /api/v1/sessions
  # List all sessions with optional filtering and pagination.
  #
  # Query parameters:
  #   - status: Filter by status (waiting, running, needs_input, failed, archived)
  #   - agent_runtime: Filter by agent runtime
  #   - show_archived: Include archived sessions (default: false)
  #   - visibility: board visibility, the presentation-only axis. "on_board" for the
  #     sessions a tidied dashboard shows, "off_board" for the hidden and snoozed
  #     ones. OMITTED BY DEFAULT — this listing is unfiltered on that axis, so an
  #     agent checking whether work is already in flight is never shown fewer
  #     sessions because a human tidied their board.
  #   - page: Page number (default: 1)
  #   - per_page: Results per page (default: 25, max: 100)
  def index
    # Status-summary forks are Zimmer's own bookkeeping (see
    # SessionStatusSummaryGenerator) — excluded here so this listing matches the
    # dashboard and the MCP search.
    scope = Session.includes(:category).excluding_status_summary_forks.order(created_at: :desc)

    # Filter by status
    scope = scope.where(status: params[:status]) if params[:status].present?

    # Filter by agent_runtime
    scope = scope.where(agent_runtime: params[:agent_runtime]) if params[:agent_runtime].present?

    # Filter by scheduling class / genesis. A session that carries no class of its
    # own is classified through SessionGenesis on read, so moving a genesis in
    # Settings moves those sessions here immediately.
    scope = scope.priority_classified(params[:priority_class]) if SessionGenesis::CLASSES.include?(params[:priority_class])
    scope = scope.with_genesis(params[:genesis]) if SessionGenesis.valid?(params[:genesis].to_s)

    scope = apply_visibility_filter(scope)

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
    record = @session.human_message_record

    render json: {
      session: session_json(@session, include_transcript: params[:include_transcript] == "true"),
      status_summary: session_status_summary_json(@session),
      session_hierarchy: session_hierarchy_json(record.hierarchy),
      human_messages: human_messages_json(record)
    }
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
  #   - mcp_servers: Array of MCP server names (overrides agent_root's defaults if provided;
  #     an explicit [] means no servers, while omitting the key takes the root's defaults)
  #   - catalog_skills: Array of skill names (same omitted-vs-[] rule as mcp_servers)
  #   - catalog_hooks: Array of hook names (same omitted-vs-[] rule as mcp_servers)
  #   - catalog_plugins: Array of plugin IDs (same omitted-vs-[] rule as mcp_servers)
  #   - config: Additional configuration (JSON)
  #   - custom_metadata: Custom user metadata (JSON)
  #   - scheduling_class: "spot" or "priority" for this session, overriding the class its
  #     genesis would give it. Omit to derive (inheriting a parent's explicit class if it has one).
  #   - precedence: where this session sits in the spot queue — higher is handled sooner, on an
  #     absolute scale. Omit to land one point above the parent, or at the default with no parent.
  #   - place: a symbolic placement (SessionPrecedence::PLACES, "top_of_spot" today) the server
  #     resolves against the live queue as part of this write, so the caller does not have to read
  #     the current top and write above it in a second request. Mutually exclusive with precedence.
  #   - idempotency_key: names THIS create attempt so it is safe to retry. Repeating the call
  #     with the same key returns the session the first call made — 200 with
  #     "idempotent_replay": true rather than 201 — and queues no second agent job. Without
  #     one, a create whose response is lost (a gateway timeout after the row committed) is
  #     indistinguishable from one that never landed, and retrying duplicates the session.
  def create
    # Answered before anything is built: the retry this exists for is a caller
    # that already has its session and cannot tell. See Sessions::IdempotentCreate.
    idempotency_key = session_params[:idempotency_key].presence
    if (replayed = Sessions::IdempotentCreate.existing(idempotency_key))
      return render json: { session: session_json(replayed), idempotent_replay: true }, status: :ok
    end

    # Resolved before the record exists, so a bad pairing is a 422 rather than a
    # session created and then ranked wrong. Nothing to exclude and no rank to
    # keep on a create, so this is the plain class-method resolution.
    placement = resolved_placement(session_params)
    return if performed?

    @session = Session.new(session_params.except(:agent_root, :place))
    @session.precedence = placement unless placement.nil?
    # Machine-created. When the caller passed a parent_session_id this is an agent
    # continuing an existing line of work, so assign_genesis inherits that parent's
    # genesis and leaves `api` alone; `api` is only what a parentless call gets.
    @session.genesis = SessionGenesis::API if @session.parent_session_id.blank?

    # Recorded before save so the job starting moments later can tell a
    # deliberate "no MCP servers" from a column that landed empty by accident.
    @session.record_explicit_mcp_servers(@session.mcp_servers) if explicit_list_param?(:mcp_servers)

    # Resolve the runtime, the model, and — when agent_root was given — the
    # repository fields, through the shared param → root → AppSetting → hardcoded
    # chain. This always leaves an explicit model in config.
    resolve_agent_root_defaults!

    # The lookup above answers the sequential retry; this answers the concurrent
    # one, where the first request is still inside its INSERT when the second
    # arrives. A reused result means the winning request already queued the agent
    # job, so this one queues nothing.
    result = Sessions::IdempotentCreate.save(@session, idempotency_key)

    if result.nil?
      render_api_error("Validation failed", @session.errors.full_messages, status: :unprocessable_entity)
    elsif result.reused?
      render json: { session: session_json(result.session), idempotent_replay: true }, status: :ok
    else
      # Queue the agent job if a prompt was provided
      if @session.prompt.present?
        job = AgentSessionJob.enqueue_new_session(@session.id)
        @session.update(job_id: job.job_id)
      end

      render json: { session: session_json(@session) }, status: :created
    end
  rescue AgentRootsConfig::AgentRootNotFoundError => e
    render_api_error("Invalid agent_root", e.message, status: :unprocessable_entity)
  end

  # PATCH/PUT /api/v1/sessions/:id
  # Update an existing session.
  # Note: Only certain fields can be updated based on session status.
  #
  # Ranking takes either `precedence` (an absolute rank) or `place` (a symbolic
  # one the server resolves against the live queue), never both.
  def update
    was_priority = @session.priority_class == SessionGenesis::PRIORITY

    # The session already holds a rank, so it places itself: excluded from its own
    # population, and never lowered by a request to put it first.
    placement = resolved_placement(session_update_params, session: @session)
    return if performed?

    attrs = session_update_params.except(:place)
    attrs[:precedence] = placement unless placement.nil?

    if @session.update(attrs)
      # Promoting a waiting session starts it, the same as the Ranked view's
      # Promote and `action_session`'s `change_scheduling_class` — which is what
      # makes the promise above ("moved to priority and started") true. The hold
      # this releases carries a deferred re-check up to an hour out, and nothing
      # else would bring it forward. Only on the transition INTO priority, so an
      # unrelated PATCH cannot restart a session by touching its title.
      start = if !was_priority && @session.priority_class == SessionGenesis::PRIORITY && @session.waiting?
        Sessions::StartNow.call(@session, actor: "the REST API promoting it")
      end

      # Reported rather than swallowed: a start this refuses (a session asleep on
      # an armed wake, say) is something the caller has to be able to see.
      payload = { session: session_json(@session) }
      payload[:start] = { outcome: start.outcome, message: start.message } if start && !start.nothing_queued?

      render json: payload
    else
      render_api_error("Validation failed", @session.errors.full_messages, status: :unprocessable_entity)
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
  #
  # Refused with 422 when messages are still queued for the session — archiving
  # discards them, and nothing delivers a queued message once the session is in
  # the trash. `force: true` overrides it for a caller that has read them and is
  # deliberately discarding them. See Sessions::ArchiveGuard.
  def archive
    if @session.may_archive?
      force = ActiveModel::Type::Boolean.new.cast(params[:force])
      queued = force ? [] : Sessions::ArchiveGuard.pending_messages(@session)

      if queued.any?
        render_api_error(
          "Queued messages would be discarded",
          Sessions::ArchiveGuard.refusal_message(@session, queued),
          status: :unprocessable_entity
        )
        return
      end

      @session.archive_actor = "the REST API"
      @session.archive_forced = force
      @session.archive!
      render json: {
        session: session_json(@session.reload),
        message: "Session moved to trash",
        trash_after: @session.trash_after&.iso8601
      }
    else
      render_api_error("Cannot trash", "Session cannot be trashed from current status: #{@session.status}", status: :unprocessable_entity)
    end
  end

  # POST /api/v1/sessions/:id/unarchive
  # Restore a session from trash and restore Claude Code state.
  # This recreates the clone directory (if needed) and restores the transcript
  # so Claude Code can resume where it left off.
  def unarchive
    unless @session.archived?
      render_api_error("Cannot restore", "Session is not in trash", status: :unprocessable_entity)
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
      render_api_error("Failed to restore", result.error, status: :unprocessable_entity)
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
  #   - goal: Optional goal override. A non-blank goal is applied to the session on every
  #     branch; a blank or absent one preserves whatever goal the session already has
  #     (use PATCH /api/v1/sessions/:id to clear a goal).
  #   - force_immediate: When true, sends immediately even if session is running (default: false)
  #   - acting_session_id: Optional. The ID of the agent session making this call. Records an
  #     "uncle" lineage edge marking the caller as a senior of the target session. Self-declared,
  #     because the shared API key identifies a caller and not a session; omitting it records
  #     nothing. See Sessions::RecordUncleEdge.
  def follow_up
    prompt = params[:prompt].to_s.strip

    if prompt.blank?
      render_api_error("Missing parameter", "prompt is required", status: :unprocessable_entity)
      return
    end

    if prompt.length > Session::PROMPT_MAX_LENGTH
      render_api_error("Validation failed", "prompt is too long (maximum #{Session::PROMPT_MAX_LENGTH} characters)", status: :unprocessable_entity)
      return
    end

    goal = params[:goal].to_s.strip.presence

    # Rejected up front, before any branch mutates state, so an over-long goal
    # fails the same way whether the message is queued, interrupted in, or sent
    # directly — and never after the prompt has already been delivered.
    if goal && goal.length > Session::GOAL_MAX_LENGTH
      render_api_error("Validation failed", "goal is too long (maximum #{Session::GOAL_MAX_LENGTH} characters)", status: :unprocessable_entity)
      return
    end

    force_immediate = params[:force_immediate] == true || params[:force_immediate] == "true"

    # When force_immediate is set, send immediately regardless of session state.
    # If the session is running, pause it first, then resume with the new prompt.
    if force_immediate
      unless @session.running? || @session.waiting? || @session.needs_input?
        render_api_error("Cannot send follow-up", "Session is #{@session.status}. Follow-up prompts can only be sent to running, waiting, or needs_input sessions.", status: :unprocessable_entity)
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
        record_uncle_edge(@session, "api_v1:sessions.follow_up")
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
        render_api_error("Cannot send follow-up", result.error, status: result.error_code || :internal_server_error)
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
      record_uncle_edge(@session, "api_v1:sessions.follow_up")
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
      render_api_error("Cannot send follow-up", "Session is #{@session.status}. Follow-up prompts can only be sent to running, waiting, or needs_input sessions.", status: :unprocessable_entity)
      return
    end

    ActiveRecord::Base.transaction do
      # The goal is applied here, on the session itself — the other two branches
      # carry it on the EnqueuedMessage and EnqueuedMessageProcessorService applies
      # it when it claims the message. Same rule in all three places: a non-blank
      # goal overwrites, a blank or absent one leaves the session's goal alone
      # (clearing a goal is PATCH /api/v1/sessions/:id).
      if goal && goal != @session.goal
        @session.update!(prompt: prompt, goal: goal)
        @session.logs.create!(content: "Goal updated from follow-up", level: "info")
      else
        @session.update!(prompt: prompt)
      end
      @session.resume! if @session.may_resume?
      # Before the enqueue, and in the same transaction: the job this line
      # creates builds the next prompt for the session, and it must see the edge
      # — a job that starts first renders a hierarchy missing exactly the human
      # context the edge exists to carry. A rollback takes the edge with it, so a
      # failed send still records nothing.
      record_uncle_edge(@session, "api_v1:sessions.follow_up")
      job = AgentSessionJob.enqueue_with_prompt(@session.id, prompt)
      @session.update!(running_job_id: job.job_id)
    end

    render json: { session: session_json(@session.reload), message: "Follow-up prompt sent" }
  rescue ActiveRecord::RecordInvalid => e
    render_api_error("Validation failed", e.message, status: :unprocessable_entity)
  rescue ActiveRecord::RecordNotUnique
    render_api_error("Conflict", "Message position conflict, please retry", status: :conflict)
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
      render_api_error("Cannot pause", "Session is not running", status: :unprocessable_entity)
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
      render_api_error("Cannot sleep", "Session must be in needs_input or running state to sleep (current: #{@session.status})", status: :unprocessable_entity)
      return
    end

    # Mark the sleep as deliberate. This endpoint is the one path into `waiting`
    # that arms nothing and writes none of the dormancy markers the sweeps read —
    # every other one either creates a wake trigger or records why it parked. Left
    # unmarked, StrandedSleepRescue cannot tell a session slept on purpose from
    # one whose wake set was destroyed, and would resume it fifteen minutes later
    # saying its wake had been lost. The marker is in STALE_RETRY_METADATA_KEYS,
    # so any resume or restart clears it.
    metadata = (@session.metadata || {}).merge(Session::DELIBERATE_SLEEP_KEY => Time.current.iso8601)

    if @session.needs_input?
      @session.update!(metadata: metadata)
      @session.sleep!
    else
      @session.update!(metadata: metadata.merge("pending_sleep" => true))
    end

    render json: { session: session_json(@session) }
  end

  # POST /api/v1/sessions/:id/restart
  # Restart a failed or paused session by clearing stale metadata and
  # enqueuing a recovery prompt to spawn a new CLI process.
  def restart
    unless @session.may_resume?
      render_api_error("Cannot restart", "Session cannot be restarted from current status: #{@session.status}", status: :unprocessable_entity)
      return
    end

    return if refuse_restart_of_paused_session

    # When there is no conversation to prompt into — setup never completed (e.g.
    # the git clone failed), or the session never ran at all — re-run the full
    # setup pipeline instead of sending a follow-up prompt into nothing.
    if @session.needs_restart_from_scratch?
      restart_from_scratch(@session)
      return
    end

    # Everything past here resumes a conversation, so it needs the id that
    # conversation is filed under. A session with no id but a transcript to lose
    # reaches this point (#needs_restart_from_scratch? deliberately does not
    # claim it), and is refused rather than silently restarted from scratch.
    unless @session.session_id.present?
      render_api_error("Cannot restart", "Session has no session_id", status: :unprocessable_entity)
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
      render_api_error("Missing parameter", "message_index is required", status: :unprocessable_entity)
      return
    end

    result = ForkSessionService.call(
      source_session: @session,
      message_index: params[:message_index].to_i
    )

    if result.success?
      render json: { session: session_json(result.forked_session), message: "Session forked successfully" }, status: :created
    else
      render_api_error("Fork failed", result.error, status: :unprocessable_entity)
    end
  end

  # POST /api/v1/sessions/:id/regenerate_status_summary
  # Rewrite the session's Status blurb. Forced — it regenerates even when the
  # cached blurb is current — and asynchronous, because generation normally forks
  # the session and spends a whole agent turn. (With no login-pool account free
  # it takes the one-shot path instead, which is quicker but still not inline.)
  #
  # An archived session is a normal candidate, and so is one whose clone Zimmer
  # reclaimed when it went to the trash: the fork answers from the conversation,
  # and is given an empty working directory when there is no tree left. 422 with
  # the reason, rather than a 202 for work that will never run, for the two cases
  # that stay impossible — no transcript at all, or a session that is itself a
  # summary fork.
  def regenerate_status_summary
    unavailable = SessionStatusSummaryGenerator.unavailable_reason(session: @session, force: true)

    if unavailable
      render_api_error("Cannot regenerate status summary", unavailable.message, status: :unprocessable_entity)
      return
    end

    SessionStatusSummaryJob.set(priority: SessionStatusSummaryJob::FORCED_PRIORITY).perform_later(@session.id, force: true)

    render json: {
      session_id: @session.id,
      message: "Status summary regeneration queued"
    }, status: :accepted
  end

  # POST /api/v1/sessions/:id/refresh
  # Re-read transcript from filesystem and recover orphaned jobs.
  def refresh
    transcript_dir = get_transcript_directory_for_session(@session)

    if transcript_dir.nil?
      render_api_error("No clone path", "No clone path found for this session", status: :unprocessable_entity)
      return
    end

    if Dir.exist?(transcript_dir)
      main_transcript_file = find_main_transcript_file_for_session(@session, transcript_dir)

      if main_transcript_file
        # Through the runtime's TranscriptSource, not File.read: that is where
        # TranscriptRedactor runs, so a manual refresh cannot write an unredacted
        # transcript over the redacted one the poller stored. It also decompresses a
        # Codex .zst rollout, which a raw read would have stored as binary.
        transcript_content = TranscriptRuntime.source_for(@session).read(main_transcript_file)
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

    render_api_error("Not found", "No transcript files found on filesystem", status: :not_found)
  rescue => e
    render_api_error("Refresh failed", e.message, status: :internal_server_error)
  end

  # POST /api/v1/sessions/refresh_all
  # Bulk refresh all non-archived sessions: restart failed, continue paused, refresh running.
  # Sessions in a frozen category are a parked bucket and are intentionally excluded.
  def refresh_all
    # A status-summary fork sitting in needs_input between its pause and the
    # harvest is not work anyone is waiting on — resuming it would spend a
    # whole agent turn against a throwaway clone, outside the fork lifecycle.
    sessions = Session.not_in_frozen_category.excluding_status_summary_forks.where.not(status: :archived)

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
    needs_input_sessions = auto_continuable.limit(remaining_limit).load

    # Ids of everything the two restart/continue loops below touch, captured
    # BEFORE they run: each loop flips its session to :running, so a lazily
    # evaluated "everything else" relation would pick the same session up again
    # in the transcript pass — counting it twice and overwriting a transcript
    # its freshly enqueued job is about to rewrite. Same guard as the web
    # bulk refresh.
    restarted_ids = (failed_sessions + needs_input_sessions).map(&:id)

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

    # Everything not restarted or continued above still gets its transcript
    # re-read from disk — that is what "refreshed" counts, and it is the pass
    # the API was missing entirely, which is why `refreshed` was always 0.
    #
    # Capped at the same bulk_limit as the restart passes. Each iteration is a
    # whole-file read plus an UPDATE that broadcasts, and this runs inside the
    # request, so an instance with hundreds of live sessions would otherwise turn
    # one POST into an unbounded synchronous fan-out.
    sessions
      .where.not(status: [ :failed, :needs_input ])
      .where.not(id: restarted_ids)
      .limit(bulk_limit)
      .each do |session|
        refreshed_count += 1 if refresh_transcript_from_disk(session)
      rescue => e
        error_count += 1
        Rails.logger.error "[API refresh_all] Failed to refresh session #{session.id}: #{e.message}"
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
      render_api_error("Invalid parameter", "mcp_servers must be an array", status: :unprocessable_entity)
      return
    end

    if mcp_servers.length > 50
      render_api_error("Too many servers", "Maximum 50 MCP servers", status: :unprocessable_entity)
      return
    end

    mcp_servers = mcp_servers.reject(&:blank?).map { |s| s.to_s.strip.first(100) }

    # Validate server names
    invalid_servers = mcp_servers.reject { |name| ServersConfig.exists?(name) }
    if invalid_servers.any?
      render_api_error("Invalid servers", "Invalid MCP servers: #{invalid_servers.join(', ')}", status: :unprocessable_entity)
      return
    end

    old_servers = @session.mcp_servers || []

    # Clearing the list has to be recorded as deliberate, or McpServerBackfill
    # reads the empty column as an accident and restores the root's defaults the
    # next time the config is regenerated.
    @session.record_explicit_mcp_servers(mcp_servers)

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
      render_api_error("Update failed", @session.errors.full_messages, status: :unprocessable_entity)
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
      render_api_error("Invalid parameter", "catalog_skills must be an array", status: :unprocessable_entity)
      return
    end

    if catalog_skills.length > SessionsController::MAX_CATALOG_SKILLS
      render_api_error("Too many skills", "Maximum #{SessionsController::MAX_CATALOG_SKILLS} catalog skills", status: :unprocessable_entity)
      return
    end

    catalog_skills = catalog_skills.reject(&:blank?).map { |s| s.to_s.strip.first(SessionsController::MAX_CATALOG_SKILL_NAME_LENGTH) }

    invalid_skills = catalog_skills.reject { |name| SkillsConfig.exists?(name) }
    if invalid_skills.any?
      render_api_error("Invalid skills", "Invalid catalog skills: #{invalid_skills.join(', ')}", status: :unprocessable_entity)
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
      render_api_error("Update failed", @session.errors.full_messages, status: :unprocessable_entity)
    end
  end

  # PATCH /api/v1/sessions/:id/catalog_hooks
  def update_catalog_hooks
    catalog_hooks = params[:catalog_hooks] || []

    unless catalog_hooks.is_a?(Array)
      render_api_error("Invalid parameter", "catalog_hooks must be an array", status: :unprocessable_entity)
      return
    end

    if catalog_hooks.length > SessionsController::MAX_CATALOG_HOOKS
      render_api_error("Too many hooks", "Maximum #{SessionsController::MAX_CATALOG_HOOKS} catalog hooks", status: :unprocessable_entity)
      return
    end

    catalog_hooks = catalog_hooks.reject(&:blank?).map { |s| s.to_s.strip.first(SessionsController::MAX_CATALOG_HOOK_NAME_LENGTH) }

    invalid_hooks = catalog_hooks.reject { |name| HooksConfig.exists?(name) }
    if invalid_hooks.any?
      render_api_error("Invalid hooks", "Invalid catalog hooks: #{invalid_hooks.join(', ')}", status: :unprocessable_entity)
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
      render_api_error("Update failed", @session.errors.full_messages, status: :unprocessable_entity)
    end
  end

  # PATCH /api/v1/sessions/:id/catalog_plugins
  def update_catalog_plugins
    catalog_plugins = params[:catalog_plugins] || []

    unless catalog_plugins.is_a?(Array)
      render_api_error("Invalid parameter", "catalog_plugins must be an array", status: :unprocessable_entity)
      return
    end

    if catalog_plugins.length > SessionsController::MAX_CATALOG_PLUGINS
      render_api_error("Too many plugins", "Maximum #{SessionsController::MAX_CATALOG_PLUGINS} catalog plugins", status: :unprocessable_entity)
      return
    end

    catalog_plugins = catalog_plugins.reject(&:blank?).map { |s| s.to_s.strip.first(SessionsController::MAX_CATALOG_PLUGIN_ID_LENGTH) }

    invalid_plugins = catalog_plugins.reject { |id| PluginsConfig.exists?(id) }
    if invalid_plugins.any?
      render_api_error("Invalid plugins", "Invalid catalog plugins: #{invalid_plugins.join(', ')}", status: :unprocessable_entity)
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
      render_api_error("Update failed", @session.errors.full_messages, status: :unprocessable_entity)
    end
  end

  # PATCH /api/v1/sessions/:id/model
  # Update the model for a session.
  #
  # Request body:
  #   - model: String model identifier. Must be valid for the session's
  #     agent_runtime (e.g. "opus", "sonnet", "haiku", "fable" for claude_code).
  def update_model
    model = params[:model]

    unless model.is_a?(String) && model.present?
      render_api_error("Invalid parameter", "model must be a non-empty string", status: :unprocessable_entity)
      return
    end

    model = model.strip.first(100)

    # Reject models that don't belong to the session's runtime catalog.
    unless ModelCatalog.valid_model?(@session.agent_runtime, model)
      allowed = ModelCatalog.model_ids_for(@session.agent_runtime)
      render_api_error("Invalid model", "model #{model.inspect} is not valid for runtime #{@session.agent_runtime}. Valid models: #{allowed.join(', ')}", status: :unprocessable_entity)
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
      render_api_error("Update failed", @session.errors.full_messages, status: :unprocessable_entity)
    end
  end

  # GET /api/v1/sessions/:id/transcript
  # Get a formatted plain-text transcript for a session.
  def transcript
    parsed = @session.parsed_transcript
    if parsed.blank?
      render_api_error("No transcript", "No transcript available for this session", status: :not_found)
      return
    end

    text = TranscriptTextRenderer.render(parsed)

    if params[:format] == "text"
      render plain: text, content_type: "text/plain"
    else
      render json: { transcript_text: text }
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
      render_api_error("Too long", "Notes are too long (maximum 50,000 characters)", status: :unprocessable_entity)
      return
    end

    if @session.update(session_notes: notes.presence, session_notes_updated_at: notes.present? ? Time.current : nil)
      render json: {
        session: session_json(@session),
        session_notes_updated_at: @session.session_notes_updated_at&.iso8601
      }
    else
      render_api_error("Update failed", @session.errors.full_messages, status: :unprocessable_entity)
    end
  end

  # POST /api/v1/sessions/:id/toggle_favorite
  # Toggle the favorited status of a session.
  def toggle_favorite
    @session.update!(favorited: !@session.favorited)
    render json: { session: session_json(@session), favorited: @session.favorited }
  end

  # PATCH /api/v1/sessions/:id/visibility
  # Set a session's BOARD VISIBILITY — a presentation-only axis, orthogonal to
  # `status` and to everything else. It decides whether the session's card is on
  # the operator's dashboard and NOTHING ELSE: it never starts, stops, sleeps,
  # wakes or reorders a session, and the scheduler does not read it. If you are
  # looking for the endpoint that actually puts a session to sleep, that is
  # POST /api/v1/sessions/:id/sleep.
  #
  # Params:
  #   - visibility: "visible" | "hidden" | "snoozed" (required)
  #   - snoozed_until: required with "snoozed". A naive wall-clock ISO-8601
  #     datetime ("2026-09-05T09:00:00") read in `timezone`, and it must be in the
  #     future. Cleared automatically for the other two values.
  #   - timezone: IANA name `snoozed_until` is expressed in. Default "UTC".
  #
  # A snooze expires by being READ: once `snoozed_until` passes, the session is
  # back on the board with no request and no background job having touched the row.
  def update_visibility
    Sessions::SetVisibility.call(
      session: @session,
      visibility: params[:visibility],
      snoozed_until: params[:snoozed_until],
      timezone: params[:timezone].presence || "UTC"
    )

    render json: { session: session_json(@session) }
  rescue Sessions::SetVisibility::Error => e
    render_api_error("Visibility update failed", [ e.message ], status: :unprocessable_entity)
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
        render_api_error("Validation failed", "enabled must be a boolean", status: :unprocessable_entity)
        return
      end
      attrs[:heartbeat_enabled] = casted
    end

    unless params[:interval_seconds].nil?
      interval = params[:interval_seconds]
      unless interval.to_s.match?(/\A\d+\z/)
        render_api_error("Validation failed", "interval_seconds must be an integer", status: :unprocessable_entity)
        return
      end
      attrs[:heartbeat_interval_seconds] = interval.to_i
    end

    if attrs.empty?
      render_api_error("Missing parameter", "Provide enabled and/or interval_seconds", status: :unprocessable_entity)
      return
    end

    @session.update!(attrs)
    render json: {
      session: session_json(@session),
      heartbeat_enabled: @session.heartbeat_enabled,
      heartbeat_interval_seconds: @session.heartbeat_interval_seconds
    }
  rescue ActiveRecord::RecordInvalid => e
    render_api_error("Validation failed", e.message, status: :unprocessable_entity)
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
        render_api_error("Not Found", "Category ##{category_id} not found", status: :not_found)
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
      render_api_error("Missing parameter", "session_ids array is required", status: :unprocessable_entity)
      return
    end

    sessions = Session.where(id: session_ids).where.not(status: :archived)
    archived_count = 0
    errors = []

    force = ActiveModel::Type::Boolean.new.cast(params[:force])

    # One request is one caller action, so it owes the caller one page rather
    # than one per session — see the MCP twin, including why this is defensive
    # here and load-bearing on HealthMonitorService's sweep.
    AlertBatcher.with_batch do
      sessions.each do |session|
        queued = force ? [] : Sessions::ArchiveGuard.pending_messages(session)

        if queued.any?
          # Reported and skipped rather than aborting the batch, matching the MCP
          # twin. `force` applies to the whole batch, not one member of it.
          errors << { id: session.id, message: Sessions::ArchiveGuard.refusal_message(session, queued, batch: true) }
        elsif session.may_archive?
          session.archive_actor = "the REST API (bulk)"
          session.archive_forced = force
          session.archive!
          archived_count += 1
        else
          errors << { id: session.id, message: "Cannot archive from status: #{session.status}" }
        end
      end
    end

    render json: { archived_count: archived_count, errors: errors }
  end

  # GET /api/v1/sessions/search
  # Search sessions by query string.
  #
  # Query parameters:
  #   - q (or query): Search query (required) - searches title, metadata, and custom_metadata
  #   - search_contents: "true" or "1" to also search transcript contents
  #   - scan_cursor: resume token from a previous content search's content_scan.next_cursor
  #   - status: Filter by status (waiting, running, needs_input, failed, archived)
  #   - agent_runtime: Filter by agent runtime
  #   - show_archived: Include archived sessions (default: false)
  #   - page: Page number (default: 1) - ignored when search_contents is set
  #   - per_page: Results per page (default: 25, max: 100)
  #
  # `search_contents` runs a bounded, resumable scan (SessionContentSearch) instead of
  # the single unbounded ILIKE that used to 504 here (#405). It reports `content_scan`
  # alongside the results and does NOT report a total count — counting matches over the
  # transcript corpus costs exactly the full scan being avoided.
  def search
    # `q` is this endpoint's name for it; `query` is what every other surface calls it
    # (the MCP tool's parameter, the dashboard's field). Accepting both stops a caller
    # who guessed the other name from getting a 400 that names no alternative.
    query = params[:q].presence&.to_s&.strip || params[:query].to_s.strip

    if query.blank?
      render_api_error("Missing parameter", "q (search query) is required", status: :bad_request)
      return
    end

    # Validate query length to prevent performance issues
    if query.length > 1000
      render_api_error("Query too long", "Maximum query length is 1000 characters", status: :bad_request)
      return
    end

    # Excludes status-summary forks for the same reason #index does — the two
    # listings must not disagree about which sessions exist.
    scope = Session.includes(:category).excluding_status_summary_forks.order(created_at: :desc)

    # Filter by status
    scope = scope.where(status: params[:status]) if params[:status].present?

    # Filter by agent_runtime
    scope = scope.where(agent_runtime: params[:agent_runtime]) if params[:agent_runtime].present?

    # Filter by scheduling class / genesis. A session that carries no class of its
    # own is classified through SessionGenesis on read, so moving a genesis in
    # Settings moves those sessions here immediately.
    scope = scope.priority_classified(params[:priority_class]) if SessionGenesis::CLASSES.include?(params[:priority_class])
    scope = scope.with_genesis(params[:genesis]) if SessionGenesis.valid?(params[:genesis].to_s)

    scope = apply_visibility_filter(scope)

    # Exclude archived unless requested
    scope = scope.where.not(status: :archived) unless params[:show_archived] == "true"

    # Apply search filter
    include_contents = SessionSearchable.search_contents?(params[:search_contents])

    unless include_contents
      result = paginate(filter_sessions_by_search(scope, query))

      render json: {
        query: query,
        search_contents: false,
        sessions: result[:records].map { |s| session_json(s) },
        pagination: result[:pagination]
      }
      return
    end

    per_page = pagination_params[:per_page]
    matches, scan = search_sessions_by_content(scope, query, limit: per_page, cursor: params[:scan_cursor])
    sessions = matches.reorder(created_at: :desc, id: :desc).to_a

    render json: {
      query: query,
      search_contents: true,
      sessions: sessions.map { |s| session_json(s) },
      pagination: {
        page: 1,
        per_page: per_page,
        # Deliberately null: see the comment above #search. Callers page a content
        # search with content_scan.next_cursor, not with `page`.
        total_count: nil,
        total_pages: nil
      },
      content_scan: {
        complete: scan.complete?,
        timed_out: scan.timed_out?,
        scanned_sessions: scan.scanned,
        candidate_sessions: scan.candidate_count,
        next_cursor: scan.next_cursor
      }
    }
  end

  private

  # Refuse a restart while the session is paused until a time it has not reached.
  #
  # The twin of Mcp::Tools::ActionSession#refuse_if_paused!, and it has to exist
  # separately because the two surfaces share no restart code. Both are the
  # non-interactive door — a script, an integration, an agent working a queue —
  # where "start this session" is a claim about the queue rather than a person
  # taking one session over. The web UI's Restart button is the interactive door
  # and deliberately still consumes the pause.
  #
  # It sits ahead of `resume!`, which is the only place it can: `resume`'s
  # cancel_pending_one_time_wake_triggers callback consumes the pause, so anything
  # further down would arrive after it was gone.
  #
  # @return [Boolean] true when a response has been rendered and the caller must stop
  def refuse_restart_of_paused_session
    return false unless @session.paused_until_scheduled_time?

    render_api_error(
      "Cannot restart",
      "Session #{@session.id} is asleep on a wake-up it has not reached yet " \
      "(#{@session.pending_wake_phrase}). A pause outranks precedence and scheduling class, so this " \
      "session does not start early — it wakes on its own schedule.",
      status: :unprocessable_entity
    )
    true
  end

  # Restart a session from scratch by re-running the full setup pipeline.
  # Used when setup never completed (e.g., git clone failed).
  def restart_from_scratch(session)
    unless session.git_root.present?
      render_api_error("Cannot restart", "No git_root configured for restart from scratch", status: :unprocessable_entity)
      return
    end

    cleaned_metadata = (session.metadata || {}).except(
      *Session::STALE_RETRY_METADATA_KEYS,
      *Session::SETUP_ARTIFACT_KEYS,
      *SpotSessionHold::METADATA_KEYS
    )

    # The replacement turn IS the original first turn — same prompt, new clone,
    # new session_id — so it carries the attachments that turn was created with
    # (Sessions::FirstTurnAttachments, which never raises). Replaying all of them
    # is deliberate: this path is reached only when there is no conversation to
    # prompt into — a pre-prompt failure with setup incomplete, or a session that
    # never ran — and a restart from scratch discards the conversation any earlier
    # delivery went to. Read outside the transaction.
    images, files = Sessions::FirstTurnAttachments.for(session)
    carrying = Sessions::FirstTurnAttachments.carrying_clause(images, files)

    ActiveRecord::Base.transaction do
      session.logs.create!(
        content: "Restarting session from scratch: re-running full setup pipeline " \
                 "(git clone, MCP config, process spawn)#{carrying}",
        level: "info"
      )

      session.update!(
        running_job_id: nil,
        session_id: nil,
        metadata: cleaned_metadata
      )
      session.resume! if session.may_resume?
      AgentSessionJob.enqueue_new_session(session.id, images: images.presence, files: files.presence)

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
    render_api_error("Cannot restart", e.message, status: :internal_server_error)
  end

  # Board visibility — the presentation-only axis — applied to a listing scope.
  #
  # OPTIONAL, and unfiltered when the caller says nothing. Both listings are read
  # by agents as often as by the dashboard, and an agent checking whether a piece
  # of work already has a session must not have that session hidden from it
  # because a human tidied their board: that produces duplicate work with no
  # visible cause. An unrecognized value narrows nothing, for the same reason.
  def apply_visibility_filter(scope)
    case params[:visibility].to_s
    when SessionVisibility::FILTER_ON_BOARD then scope.board_visible
    when SessionVisibility::FILTER_OFF_BOARD then scope.board_hidden
    else scope
    end
  end

  def set_session
    # Try to find by slug first, then by ID
    @session = Session.find_by(slug: params[:id]) || Session.find(params[:id])
  end

  # `agent_root` is permitted here alongside the rest of the create payload, but
  # it is not a Session column — it names a catalog entry that
  # resolve_agent_root_defaults! expands into git_root, branch, subdirectory and
  # the catalog defaults. `place` is not a column either; it resolves to a
  # `precedence` before the record is built. Hence `.except(:agent_root, :place)`
  # at the Session.new call.
  def session_params
    params.permit(
      :agent_root, :agent_runtime, :prompt, :git_root, :branch, :subdirectory,
      :title, :slug, :goal, :execution_provider, :is_autonomous,
      :parent_session_id, :auto_compact_window, :scheduling_class, :precedence, :place,
      :idempotency_key,
      mcp_servers: [], catalog_skills: [], catalog_hooks: [], catalog_plugins: [], config: {}, custom_metadata: {}
    )
  end

  # True when the request actually named this artifact list, empty or not. An
  # array is the only thing that counts as naming one, so an explicit `[]` is a
  # request for none while an absent key falls through to the root's defaults.
  def explicit_list_param?(key)
    session_params[key].is_a?(Array)
  end

  # Resolve agent_root param to git_root and apply catalog defaults.
  # Explicit params (git_root, branch, subdirectory, mcp_servers, catalog_skills, catalog_hooks, catalog_plugins)
  # take precedence over agent root defaults.
  # Resolve the runtime and model for a new session, and — when an agent_root was
  # named — the repository fields that come with it.
  #
  # The precedence is the one the whole app shares:
  #
  #   request param  →  agent root's declared value  →  AppSetting (the global
  #   base default set on the Settings page)  →  the hardcoded default
  #
  # This runs whether or not an agent_root was given. Without one there is simply
  # no root tier, and the chain falls straight through to AppSetting — which is
  # the point: the Settings page presents those values as global defaults, so a
  # rootless API spawn has to honor them too.
  def resolve_agent_root_defaults!
    agent_root_name = session_params[:agent_root].to_s.strip
    agent_root = AgentRootsConfig.find!(agent_root_name) if agent_root_name.present?
    app_setting = AppSetting.current

    # An explicit agent_runtime param (the per-spawn override) wins and is left
    # exactly as given, so an unregistered value still fails the model's
    # inclusion validation with a 422 rather than being silently corrected.
    unless params[:agent_runtime].present?
      @session.agent_runtime = agent_root&.default_runtime.presence ||
        app_setting.default_runtime.presence ||
        RuntimeRegistry::DEFAULT_RUNTIME
    end

    if agent_root
      @session.git_root = agent_root.url if @session.git_root.blank?
      @session.branch = agent_root.default_branch || "main" unless params[:branch].present?
      @session.subdirectory = agent_root.subdirectory if @session.subdirectory.blank? && agent_root.subdirectory.present?
      # Only an OMITTED list falls back to the root's defaults. A `.blank?` test
      # cannot tell omitted from explicitly-empty, so it overwrites an explicit
      # `[]` with the defaults — handing a caller that asked for no MCP servers
      # whatever the root declares, SSH access included.
      @session.mcp_servers = agent_root.default_mcp_servers || [] unless explicit_list_param?(:mcp_servers)
      @session.catalog_skills = agent_root.default_skills || [] unless explicit_list_param?(:catalog_skills)
      @session.catalog_hooks = agent_root.default_hooks || [] unless explicit_list_param?(:catalog_hooks)
      @session.catalog_plugins = agent_root.default_plugins || [] unless explicit_list_param?(:catalog_plugins)
      @session.metadata = (@session.metadata || {}).merge("agent_root_key" => agent_root_name)
    end

    # When the caller didn't specify a model, adopt the agent root's default
    # (which already folds in the global base default). A root's default is
    # typically a claude_code model (e.g. "opus"); applying it unconditionally to
    # a codex spawn would persist an invalid model, so self-heal to the global
    # base default for the resolved runtime (falling back to that runtime's
    # catalog default) whenever the root's model isn't valid for the runtime.
    # With no root, that self-heal branch is the whole resolution.
    return if @session.config&.dig("model").present?

    model = agent_root&.default_model
    unless ModelCatalog.valid_model?(@session.agent_runtime, model)
      model = app_setting.resolved_default_model_for(@session.agent_runtime)
    end
    @session.config = (@session.config || {}).merge("model" => model)
  end

  # `scheduling_class` is updatable after creation on purpose: a spot session
  # held behind the quota gate is still `waiting`, and this is how it gets moved
  # to priority and started without touching the trigger that spawned it or the
  # policy every other session shares. Send null to drop back to derived.
  #
  # `precedence` is updatable for the same reason at one remove: a session that
  # stays spot still needs to be movable within the queue. `place` is the
  # symbolic form of the same move — not a column, so #update excepts it.
  def session_update_params
    params.permit(:title, :slug, :goal, :is_autonomous, :scheduling_class, :precedence, :place, custom_metadata: {})
  end

  # The precedence a `place` asks for, or nil when the caller named no placement.
  #
  # `place` is the symbolic half of the pair: rather than naming a number, the
  # caller names a position (SessionPrecedence::PLACES) and the server works the
  # value out against the queue as it stands at the moment of this write. The
  # alternative is a read-then-write — read the current top, write a few points
  # above it — which can be overtaken between the two requests, landing the
  # session second in the queue it meant to head, and which makes the caller
  # re-derive a rule (the live maximum over non-archived *spot* sessions) that
  # the server owns. Resolution goes through `Session.precedence_for_place`, the
  # same helper the Ranked view's demote button and the MCP tools use, so the
  # surfaces cannot drift apart on what "the top of the queue" means.
  #
  # Renders a 422 and returns nil on a bad request; callers check `performed?`.
  #
  # `place` is an enum, so a blank one is the argument left out rather than a
  # placement. `precedence` is a scalar whose whole range is meaningful, so
  # anything but a JSON null is a value the caller chose — and choosing both is
  # two answers to one question, refused the way MCP refuses it rather than
  # silently preferring one.
  #
  # @param permitted [ActionController::Parameters] the permitted write payload
  # @param session [Session, nil] the session being placed, when it already exists
  # @return [Integer, nil]
  def resolved_placement(permitted, session: nil)
    place = permitted[:place]
    return nil if place.blank?

    unless permitted[:precedence].nil?
      render_api_error(
        "Invalid placement",
        '"place" and "precedence" are mutually exclusive — they are two answers to the same ' \
        'question. Pass "place" to let the server work the value out against the live queue, ' \
        'or "precedence" to name an absolute rank yourself.',
        status: :unprocessable_entity
      )
      return nil
    end

    unless SessionPrecedence::PLACES.include?(place.to_s)
      render_api_error(
        "Invalid placement",
        "Unknown place: #{place.inspect}. Valid: #{SessionPrecedence::PLACES.join(', ')}.",
        status: :unprocessable_entity
      )
      return nil
    end

    session ? session.precedence_for_place(place.to_s) : Session.precedence_for_place(place.to_s)
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

  # Re-read one session's transcript from the filesystem and persist it.
  #
  # Returns true only when the stored transcript actually changed — that is what
  # `refresh_all` counts as "refreshed". Returns false when there is nothing to
  # read (no clone path, no transcript directory, no main transcript file), when
  # the filesystem copy is byte-identical to the stored one (nothing was
  # refreshed, and writing anyway would append a log row to every session on
  # every call), or when the filesystem copy is shorter than the stored one. That
  # last case means the clone was recreated at a new path and started a fresh
  # file; session.transcript is the only durable record, so the longer stored copy
  # is kept rather than destroyed.
  def refresh_transcript_from_disk(session)
    transcript_dir = get_transcript_directory_for_session(session)
    return false if transcript_dir.nil? || !Dir.exist?(transcript_dir)

    main_transcript_file = find_main_transcript_file_for_session(session, transcript_dir)
    return false unless main_transcript_file

    # Through the runtime's TranscriptSource, not File.read: that is where
    # TranscriptRedactor runs, so a manual refresh cannot write an unredacted
    # transcript over the redacted one the poller stored. It also decompresses a
    # Codex .zst rollout, which a raw read would have stored as binary.
    transcript_content = TranscriptRuntime.source_for(session).read(main_transcript_file)
    return false if session.transcript == transcript_content

    message_count = count_transcript_messages(transcript_content)

    if Session.transcript_regression?(session.transcript, transcript_content)
      Rails.logger.warn "[API refresh_all] Skipped transcript regression for session #{session.id} (stored #{Session.transcript_line_count(session.transcript)} events, filesystem #{message_count}); preserving stored transcript"
      return false
    end

    session.update!(
      transcript: transcript_content,
      metadata: (session.metadata || {}).merge("broadcast_message_count" => message_count)
    )

    session.logs.create!(
      content: "Transcript refreshed via API bulk refresh (#{message_count} messages)",
      level: "info"
    )

    true
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
