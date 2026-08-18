# API controller for managing enqueued messages within sessions.
#
# Enqueued messages are follow-up prompts queued for delivery to a running or paused session.
# They are processed sequentially when the agent completes its current task.
#
# All endpoints require API key authentication via X-API-Key header.
class Api::V1::EnqueuedMessagesController < Api::BaseController
  include ApiSessionSerialization

  before_action :set_session
  before_action :set_enqueued_message, only: [ :show, :update, :destroy, :reorder, :interrupt ]

  # GET /api/v1/sessions/:session_id/enqueued_messages
  # List all enqueued messages for a session.
  #
  # Query parameters:
  #   - status: Filter by status (pending, processing, sent, undelivered)
  #   - page: Page number (default: 1)
  #   - per_page: Results per page (default: 25, max: 100)
  def index
    scope = @session.enqueued_messages.ordered

    scope = scope.where(status: params[:status]) if params[:status].present?

    result = paginate(scope)

    render json: {
      enqueued_messages: result[:records].map { |m| enqueued_message_json(m) },
      pagination: result[:pagination]
    }
  end

  # GET /api/v1/sessions/:session_id/enqueued_messages/:id
  # Get a single enqueued message.
  def show
    render json: { enqueued_message: enqueued_message_json(@enqueued_message) }
  end

  # POST /api/v1/sessions/:session_id/enqueued_messages
  # Create a new enqueued message for the session.
  #
  # Request body:
  #   - content: Message text (required, max 500,000 chars)
  #   - goal: Optional goal override
  def create
    content = params[:content].to_s.strip

    if content.blank?
      render_api_error("Missing parameter", "content is required", status: :unprocessable_entity)
      return
    end

    # Calculate next position
    max_position = @session.enqueued_messages.maximum(:position) || 0

    @enqueued_message = @session.enqueued_messages.new(
      content: content,
      goal: params[:goal].to_s.strip.presence,
      position: max_position + 1,
      status: "pending"
    )

    if @enqueued_message.save
      @session.logs.create!(content: "Enqueued message added at position #{@enqueued_message.position}", level: "info")
      record_uncle_edge(@session, "api_v1:enqueued_messages.create")
      render json: { enqueued_message: enqueued_message_json(@enqueued_message) }, status: :created
    else
      render_api_error("Validation failed", @enqueued_message.errors.full_messages, status: :unprocessable_entity)
    end
  end

  # PATCH/PUT /api/v1/sessions/:session_id/enqueued_messages/:id
  # Update an enqueued message's content and/or goal.
  def update
    attrs = {}
    attrs[:content] = params[:content].to_s.strip if params.key?(:content)
    attrs[:goal] = params[:goal].to_s.strip.presence if params.key?(:goal)

    if attrs.key?(:content) && attrs[:content].blank?
      render_api_error("Validation failed", [ "Content can't be blank" ], status: :unprocessable_entity)
      return
    end

    if @enqueued_message.update(attrs)
      @session.logs.create!(content: "Enqueued message at position #{@enqueued_message.position} updated", level: "info")
      render json: { enqueued_message: enqueued_message_json(@enqueued_message) }
    else
      render_api_error("Validation failed", @enqueued_message.errors.full_messages, status: :unprocessable_entity)
    end
  end

  # DELETE /api/v1/sessions/:session_id/enqueued_messages/:id
  # Delete an enqueued message and re-number remaining positions.
  def destroy
    position = @enqueued_message.position

    ActiveRecord::Base.transaction do
      @enqueued_message.destroy!
      # A bulk decrement transiently puts two rows on the same position unless
      # the planner happens to visit them in ascending order, and nothing here
      # pins that order. This is correct only because uniqueness on
      # (session_id, position) is DEFERRABLE INITIALLY DEFERRED, so the check
      # runs once at commit against the final state.
      @session.enqueued_messages
              .where("position > ?", position)
              .update_all("position = position - 1")
      @session.logs.create!(content: "Enqueued message at position #{position} removed", level: "info")
    end

    head :no_content
  end

  # PATCH /api/v1/sessions/:session_id/enqueued_messages/:id/reorder
  # Move an enqueued message to a new position.
  #
  # Request body:
  #   - position: New position (required, >= 1)
  def reorder
    new_position = params[:position].to_i

    if new_position < 1
      render_api_error("Invalid position", "Position must be >= 1", status: :unprocessable_entity)
      return
    end

    old_position = @enqueued_message.position
    @enqueued_message.reorder_to(new_position)

    @session.logs.create!(content: "Enqueued message moved from position #{old_position} to #{new_position}", level: "info")

    render json: { enqueued_message: enqueued_message_json(@enqueued_message.reload) }
  end

  # POST /api/v1/sessions/:session_id/enqueued_messages/:id/interrupt
  # Send the enqueued message immediately, interrupting the current session.
  # If the session is running, it will be paused first.
  #
  # Race correctness lives in Sessions::InterruptService — see that class for
  # the per-session advisory lock and exactly-once delivery contract. The web
  # controller delegates to the same service, so the two HTTP surfaces cannot
  # diverge.
  def interrupt
    result = Sessions::InterruptService.new(
      session: @session,
      enqueued_message: @enqueued_message,
      actor: "api_v1"
    ).call

    if result.success?
      record_uncle_edge(@session, "api_v1:enqueued_messages.interrupt")
      render json: { session: session_json(@session.reload), message: "Message sent as interrupt" }
    else
      # Sessions::Result error codes are already valid Rails status symbols
      # (:not_found, :conflict, :unprocessable_entity, :internal_server_error).
      render_api_error("Cannot interrupt", result.error, status: result.error_code || :internal_server_error)
    end
  end

  private

  def set_session
    @session = Session.find_by(slug: params[:session_id]) || Session.find(params[:session_id])
  end

  def set_enqueued_message
    @enqueued_message = @session.enqueued_messages.find(params[:id])
  end

  def enqueued_message_json(message)
    {
      id: message.id,
      session_id: message.session_id,
      content: message.content,
      goal: message.goal,
      position: message.position,
      status: message.status,
      created_at: message.created_at.iso8601,
      updated_at: message.updated_at.iso8601
    }
  end
end
