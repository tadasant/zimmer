# API controller for managing triggers.
#
# Triggers automate session creation based on external events (Slack messages, schedules,
# Zimmer events). Each trigger can have multiple conditions with OR semantics.
#
# All endpoints require API key authentication via X-API-Key header.
class Api::V1::TriggersController < Api::BaseController
  before_action :set_trigger, only: [ :show, :update, :destroy, :toggle, :invoke ]

  # GET /api/v1/triggers
  # List all triggers with optional filtering and pagination.
  #
  # Query parameters:
  #   - condition_type: Filter by condition type (slack, schedule, ao_event)
  #   - status: Filter by status (enabled, disabled, failed)
  #   - page: Page number (default: 1)
  #   - per_page: Results per page (default: 25, max: 100)
  def index
    scope = Trigger.includes(:trigger_conditions).order(created_at: :desc)

    if params[:condition_type].present?
      scope = scope.joins(:trigger_conditions).where(trigger_conditions: { condition_type: params[:condition_type] }).distinct
    end
    scope = scope.where(status: params[:status]) if params[:status].present?

    result = paginate(scope)

    render json: {
      triggers: result[:records].map { |t| trigger_json(t) },
      pagination: result[:pagination]
    }
  end

  # GET /api/v1/triggers/:id
  # Get a single trigger with recent sessions.
  def show
    recent_sessions = Session
      .for_trigger(@trigger.id)
      .order(created_at: :desc)
      .limit(10)

    render json: {
      trigger: trigger_json(@trigger),
      recent_sessions: recent_sessions.map { |s| session_summary_json(s) }
    }
  end

  # POST /api/v1/triggers
  # Create a new trigger with conditions.
  #
  # Request body:
  #   - name: Trigger name (required)
  #   - agent_root_name: Agent root to use (required)
  #   - prompt_template: Template with variable interpolation (required)
  #   - status: "enabled" or "disabled" (default: "enabled")
  #   - goal: Optional goal
  #   - reuse_session: Boolean (default: false)
  #   - skip_if_pending_session: Boolean (default: false). When true, a fire creates
  #         nothing while a session this trigger already spawned is still `waiting` or
  #         `running`. Bounds the BACKLOG, where max_sessions_per_minute bounds the rate.
  #   - max_sessions_per_minute: Integer burst cap — the most NEW sessions this trigger
  #     may spawn in one minute. Omit or send null for no limit (the default). When the
  #     cap is exceeded the trigger spawns one burst-notice session and then suppresses
  #     spawns until the burst subsides.
  #   - mcp_servers: Array of MCP server names
  #   - last_session_id: Existing session to target (requires reuse_session: true).
  #     When set on a trigger with a one-time schedule condition, the target
  #     session is automatically transitioned to waiting (dormant) until the
  #     trigger fires. Manually resuming the session cancels the pending fire.
  #     Also accepted as "session_id" (alias).
  #   - trigger_conditions_attributes: Array of condition objects
  #     - condition_type: "slack", "schedule", or "ao_event"
  #     - configuration: Type-specific config hash. For ao_event:
  #       - event_name: "session_needs_input", "session_failed", or "session_archived" (required)
  #       - watched_session_id: Optional session id to scope the condition to.
  #         When set, the condition only fires when THAT session transitions
  #         into the watched state. When omitted, the condition fires for ANY
  #         autonomous session transitioning into that state (broadcast).
  #         Combine with reuse_session: true and last_session_id to build a
  #         per-session "wake me up when session X reaches state Y" trigger.
  def create
    @trigger = Trigger.new(trigger_params)

    if @trigger.save
      render json: { trigger: trigger_json(@trigger) }, status: :created
    else
      render_api_error("Validation failed", @trigger.errors.full_messages, status: :unprocessable_entity)
    end
  end

  # PATCH/PUT /api/v1/triggers/:id
  # Update an existing trigger.
  def update
    if @trigger.update(trigger_params)
      render json: { trigger: trigger_json(@trigger) }
    else
      render_api_error("Validation failed", @trigger.errors.full_messages, status: :unprocessable_entity)
    end
  end

  # DELETE /api/v1/triggers/:id
  # Delete a trigger.
  def destroy
    @trigger.destroy!
    head :no_content
  end

  # POST /api/v1/triggers/:id/toggle
  # Toggle a trigger's enabled/disabled status. A trigger in the `failed` status
  # (a fire raised and it was parked rather than destroyed) toggles back to
  # enabled, which clears the failure state and re-arms it.
  def toggle
    @trigger.toggle!
    render json: { trigger: trigger_json(@trigger) }
  end

  # POST /api/v1/triggers/:id/invoke
  # Fire a trigger by hand, right now, without waiting for one of its conditions
  # to match. The same thing the Invoke button on the trigger page does: the
  # session is linked to the trigger, counts toward its fire counter, and reuses
  # the trigger's target session when the trigger is a reuse trigger.
  #
  # Status is not consulted — a disabled trigger can still be invoked, which is
  # how you test one before enabling it. `status` governs whether the trigger's
  # own conditions fire it, not whether a caller may.
  #
  # Request body:
  #   - variables: Optional hash of prompt-template variables to interpolate.
  #     Only Trigger::USER_INPUT_VARIABLES are read ({{link}}, {{text}},
  #     {{author}}, {{channel}}, {{event}}, {{repo}}, {{number}}, {{title}},
  #     {{labels}}); any other key is ignored, and a variable the template names
  #     but the caller omits interpolates as an empty string. {{time}} and
  #     {{date}} fill themselves in.
  def invoke
    variables = invoke_variables

    # An agent fired this over the API, so the session's genesis is `api` rather
    # than the kind the trigger's conditions derive (which is what an actual
    # condition match would give it) or `web_ui` (which is the button).
    result = Triggers::ManualFire.call(trigger: @trigger, genesis: SessionGenesis::API, variables: variables)

    case result.outcome
    when :burst_suppressed
      render_api_error("Burst suppressed", result.message, status: :too_many_requests,
                       trigger: trigger_json(@trigger.reload))
    when :pending_session
      # 409: the request is well-formed and the trigger is healthy — it simply
      # already has a session pending for this intent, which is reported so the
      # caller can go and look at it instead of firing again.
      render_api_error("No session created", result.message, status: :conflict,
                       trigger: trigger_json(@trigger.reload),
                       session: result.session && session_summary_json(result.session))
    when :not_reusable
      # The target session is reported when the row still exists — it is the
      # thing to go and look at — and null when it is gone.
      render_api_error("No session created", result.message, status: :unprocessable_entity,
                       trigger: trigger_json(@trigger.reload),
                       session: result.session && session_summary_json(result.session))
    else
      # :burst_notice comes back 201 too, carrying the burst-notice session the
      # trigger spawned instead. It IS a session, and the message says whose.
      render json: {
        trigger: trigger_json(@trigger.reload),
        session: session_summary_json(result.session),
        burst_notice: result.outcome == :burst_notice,
        message: result.message
      }, status: :created
    end
  rescue AgentRootsConfig::AgentRootNotFoundError => e
    render_api_error("Invalid agent_root", e.message, status: :unprocessable_entity,
                     trigger: trigger_json(@trigger))
  end

  # GET /api/v1/triggers/channels
  # List available Slack channels for trigger configuration.
  def channels
    unless SlackService.configured?
      # These two keep their historical `error` label (it is the human-readable
      # sentence, not a code) and gain the `message`/`messages` pair the rest of
      # the surface carries.
      render_api_error("Slack is not configured", "Slack is not configured", status: :service_unavailable)
      return
    end

    channels = SlackService.list_channels
    render json: {
      channels: channels.map do |channel|
        {
          id: channel.id,
          name: channel.name,
          is_private: channel.is_private,
          num_members: channel.num_members
        }
      end
    }
  rescue SlackService::SlackError => e
    render_api_error(e.message, e.message, status: :service_unavailable)
  end

  private

  def set_trigger
    @trigger = Trigger.includes(:trigger_conditions).find(params[:id])
  end

  def trigger_params
    # Accept "session_id" as a friendly alias for "last_session_id" so clients
    # creating a per-session wake-up don't have to know the internal column name.
    if params[:session_id].present? && params[:last_session_id].blank?
      params[:last_session_id] = params[:session_id]
    end

    permitted = params.permit(
      :name, :status, :agent_root_name, :goal,
      :prompt_template, :reuse_session, :enqueue_messages, :resuscitate_archived,
      :last_session_id, :max_sessions_per_minute, :skip_if_pending_session,
      :scheduling_class, :precedence,
      mcp_servers: [],
      trigger_conditions_attributes: [
        :id, :condition_type, :_destroy,
        configuration: [ :channel_id, :channel_name, :event_type, :thread_ts, :interval, :unit, :time, :day_of_week, :timezone, :event_name, :scheduled_at, :watched_session_id, :target, allowed_user_ids: [], repos: [], labels: [], exclude_labels: [] ]
      ]
    )
    permitted[:mcp_servers] ||= []
    permitted
  end

  def trigger_json(trigger)
    {
      id: trigger.id,
      name: trigger.name,
      status: trigger.status,
      failed_at: trigger.failed_at&.iso8601,
      last_error: trigger.last_error,
      agent_root_name: trigger.agent_root_name,
      prompt_template: trigger.prompt_template,
      goal: trigger.goal,
      reuse_session: trigger.reuse_session,
      enqueue_messages: trigger.enqueue_messages,
      resuscitate_archived: trigger.resuscitate_archived,
      max_sessions_per_minute: trigger.max_sessions_per_minute,
      skip_if_pending_session: trigger.skip_if_pending_session,
      bursting: trigger.bursting?,
      # The chosen class (null when none was chosen) and the one its sessions
      # actually get, which falls back to the default for the genesis its
      # conditions derive.
      scheduling_class: trigger.scheduling_class,
      effective_scheduling_class: trigger.effective_scheduling_class,
      precedence: trigger.precedence,
      mcp_servers: trigger.mcp_servers,
      conditions: trigger.trigger_conditions.map { |c| condition_json(c) },
      last_session_id: trigger.last_session_id,
      last_triggered_at: trigger.last_triggered_at&.iso8601,
      sessions_created_count: trigger.sessions_created_count,
      created_at: trigger.created_at.iso8601,
      updated_at: trigger.updated_at.iso8601
    }
  end

  # Prompt-template values for the invoke action. Restricted to the variables a
  # template can name — the same list the web form renders an input per — so an
  # unknown key is dropped at the boundary rather than carried inward. `labels`
  # is the one that may arrive as an array, which Trigger#interpolate_prompt
  # joins with commas.
  def invoke_variables
    raw = params[:variables]
    return {} unless raw.is_a?(ActionController::Parameters)

    raw.permit(*Trigger::USER_INPUT_VARIABLES.map(&:to_sym), labels: []).to_h
  end

  # The compact session shape this controller returns: enough to identify and
  # follow a session the trigger produced, without restating what
  # GET /api/v1/sessions/:id already serves.
  def session_summary_json(session)
    {
      id: session.id,
      slug: session.slug,
      title: session.title,
      status: session.status,
      created_at: session.created_at.iso8601
    }
  end

  def condition_json(condition)
    {
      id: condition.id,
      condition_type: condition.condition_type,
      configuration: condition.configuration,
      description: condition.description,
      last_triggered_at: condition.last_triggered_at&.iso8601,
      last_polled_at: condition.last_polled_at&.iso8601
    }
  end
end
