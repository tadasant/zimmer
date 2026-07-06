# API controller for managing subagent transcripts.
#
# Subagent transcripts are scoped to sessions - all operations require a session_id.
# Each transcript represents a nested Claude agent spawned via the Task tool.
#
# All endpoints require API key authentication via X-API-Key header.
class Api::V1::SubagentTranscriptsController < Api::BaseController
  before_action :set_session
  before_action :set_transcript, only: [ :show, :update, :destroy ]

  # GET /api/v1/sessions/:session_id/subagent_transcripts
  # List all subagent transcripts for a session with optional filtering and pagination.
  #
  # Query parameters:
  #   - status: Filter by status (running, completed, failed)
  #   - subagent_type: Filter by subagent type
  #   - page: Page number (default: 1)
  #   - per_page: Results per page (default: 25, max: 100)
  def index
    scope = @session.subagent_transcripts.order(created_at: :desc)

    # Filter by status
    scope = scope.where(status: params[:status]) if params[:status].present?

    # Filter by subagent_type
    scope = scope.where(subagent_type: params[:subagent_type]) if params[:subagent_type].present?

    result = paginate(scope)

    render json: {
      subagent_transcripts: result[:records].map { |t| transcript_json(t) },
      pagination: result[:pagination]
    }
  end

  # GET /api/v1/sessions/:session_id/subagent_transcripts/:id
  # Get a single subagent transcript.
  #
  # Query parameters:
  #   - include_transcript: Include the full JSONL transcript (default: false)
  def show
    render json: { subagent_transcript: transcript_json(@transcript, include_transcript: params[:include_transcript] == "true") }
  end

  # POST /api/v1/sessions/:session_id/subagent_transcripts
  # Create a new subagent transcript.
  #
  # Request body:
  #   - agent_id: Unique identifier for the subagent (required)
  #   - tool_use_id: ID of the parent Task tool call
  #   - transcript: JSONL transcript content
  #   - filename: Original transcript filename
  #   - message_count: Number of messages
  #   - subagent_type: Type of subagent
  #   - description: Description of subagent task
  #   - status: Status (running, completed, failed)
  #   - duration_ms: Execution duration in milliseconds
  #   - total_tokens: Total tokens used
  #   - tool_use_count: Number of tool uses
  def create
    @transcript = @session.subagent_transcripts.new(transcript_params)

    if @transcript.save
      render json: { subagent_transcript: transcript_json(@transcript) }, status: :created
    else
      render json: { error: "Validation failed", messages: @transcript.errors.full_messages }, status: :unprocessable_entity
    end
  end

  # PATCH/PUT /api/v1/sessions/:session_id/subagent_transcripts/:id
  # Update an existing subagent transcript.
  def update
    if @transcript.update(transcript_params)
      render json: { subagent_transcript: transcript_json(@transcript) }
    else
      render json: { error: "Validation failed", messages: @transcript.errors.full_messages }, status: :unprocessable_entity
    end
  end

  # DELETE /api/v1/sessions/:session_id/subagent_transcripts/:id
  # Delete a subagent transcript.
  def destroy
    @transcript.destroy!
    head :no_content
  end

  private

  def set_session
    # Try to find by slug first, then by ID
    @session = Session.find_by(slug: params[:session_id]) || Session.find(params[:session_id])
  end

  def set_transcript
    @transcript = @session.subagent_transcripts.find(params[:id])
  end

  def transcript_params
    params.permit(
      :agent_id, :tool_use_id, :transcript, :filename,
      :message_count, :subagent_type, :description, :status,
      :duration_ms, :total_tokens, :tool_use_count
    )
  end

  def transcript_json(transcript, include_transcript: false)
    json = {
      id: transcript.id,
      session_id: transcript.session_id,
      agent_id: transcript.agent_id,
      tool_use_id: transcript.tool_use_id,
      filename: transcript.filename,
      message_count: transcript.message_count,
      subagent_type: transcript.subagent_type,
      description: transcript.description,
      status: transcript.status,
      duration_ms: transcript.duration_ms,
      total_tokens: transcript.total_tokens,
      tool_use_count: transcript.tool_use_count,
      formatted_duration: transcript.formatted_duration,
      formatted_tokens: transcript.formatted_tokens,
      display_label: transcript.display_label,
      created_at: transcript.created_at.iso8601,
      updated_at: transcript.updated_at.iso8601
    }

    json[:transcript] = transcript.transcript if include_transcript

    json
  end
end
