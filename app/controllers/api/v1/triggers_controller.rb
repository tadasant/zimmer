# API controller for managing triggers.
#
# Triggers automate session creation based on external events (Slack messages, schedules,
# AO events). Each trigger can have multiple conditions with OR semantics.
#
# All endpoints require API key authentication via X-API-Key header.
class Api::V1::TriggersController < Api::BaseController
  before_action :set_trigger, only: [ :show, :update, :destroy, :toggle ]

  # GET /api/v1/triggers
  # List all triggers with optional filtering and pagination.
  #
  # Query parameters:
  #   - condition_type: Filter by condition type (slack, schedule, ao_event)
  #   - status: Filter by status (enabled, disabled)
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
      .where("metadata->>'trigger_id' = ?", @trigger.id.to_s)
      .order(created_at: :desc)
      .limit(10)

    render json: {
      trigger: trigger_json(@trigger),
      recent_sessions: recent_sessions.map { |s| { id: s.id, slug: s.slug, title: s.title, status: s.status, created_at: s.created_at.iso8601 } }
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
      render json: { error: "Validation failed", messages: @trigger.errors.full_messages }, status: :unprocessable_entity
    end
  end

  # PATCH/PUT /api/v1/triggers/:id
  # Update an existing trigger.
  def update
    if @trigger.update(trigger_params)
      render json: { trigger: trigger_json(@trigger) }
    else
      render json: { error: "Validation failed", messages: @trigger.errors.full_messages }, status: :unprocessable_entity
    end
  end

  # DELETE /api/v1/triggers/:id
  # Delete a trigger.
  def destroy
    @trigger.destroy!
    head :no_content
  end

  # POST /api/v1/triggers/:id/toggle
  # Toggle a trigger's enabled/disabled status.
  def toggle
    @trigger.toggle!
    render json: { trigger: trigger_json(@trigger) }
  end

  # GET /api/v1/triggers/channels
  # List available Slack channels for trigger configuration.
  def channels
    unless SlackService.configured?
      render json: { error: "Slack is not configured" }, status: :service_unavailable
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
    render json: { error: e.message }, status: :service_unavailable
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
      :last_session_id,
      mcp_servers: [],
      trigger_conditions_attributes: [
        :id, :condition_type, :_destroy,
        configuration: [ :channel_id, :channel_name, :event_type, :thread_ts, :interval, :unit, :time, :day_of_week, :timezone, :event_name, :scheduled_at, :watched_session_id, allowed_user_ids: [] ]
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
      agent_root_name: trigger.agent_root_name,
      prompt_template: trigger.prompt_template,
      goal: trigger.goal,
      reuse_session: trigger.reuse_session,
      enqueue_messages: trigger.enqueue_messages,
      resuscitate_archived: trigger.resuscitate_archived,
      mcp_servers: trigger.mcp_servers,
      conditions: trigger.trigger_conditions.map { |c| condition_json(c) },
      last_session_id: trigger.last_session_id,
      last_triggered_at: trigger.last_triggered_at&.iso8601,
      sessions_created_count: trigger.sessions_created_count,
      created_at: trigger.created_at.iso8601,
      updated_at: trigger.updated_at.iso8601
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
