# API controller for managing session logs.
#
# Logs are scoped to sessions - all operations require a session_id.
#
# All endpoints require API key authentication via X-API-Key header.
class Api::V1::LogsController < Api::BaseController
  before_action :set_session
  before_action :set_log, only: [ :show, :update, :destroy ]

  # GET /api/v1/sessions/:session_id/logs
  # List all logs for a session with optional filtering and pagination.
  #
  # Query parameters:
  #   - level: Filter by level (info, error, debug, warning, verbose)
  #   - page: Page number (default: 1)
  #   - per_page: Results per page (default: 25, max: 100)
  def index
    scope = @session.logs.order(created_at: :desc)

    # Filter by level
    scope = scope.where(level: params[:level]) if params[:level].present?

    result = paginate(scope)

    render json: {
      logs: result[:records].map { |l| log_json(l) },
      pagination: result[:pagination]
    }
  end

  # GET /api/v1/sessions/:session_id/logs/:id
  # Get a single log entry.
  def show
    render json: { log: log_json(@log) }
  end

  # POST /api/v1/sessions/:session_id/logs
  # Create a new log entry for a session.
  #
  # Request body:
  #   - content: Log message (required)
  #   - level: Log level (info, error, debug, warning, verbose) (default: info)
  def create
    @log = @session.logs.new(log_params)

    if @log.save
      render json: { log: log_json(@log) }, status: :created
    else
      render json: { error: "Validation failed", messages: @log.errors.full_messages }, status: :unprocessable_entity
    end
  end

  # PATCH/PUT /api/v1/sessions/:session_id/logs/:id
  # Update an existing log entry.
  def update
    if @log.update(log_params)
      render json: { log: log_json(@log) }
    else
      render json: { error: "Validation failed", messages: @log.errors.full_messages }, status: :unprocessable_entity
    end
  end

  # DELETE /api/v1/sessions/:session_id/logs/:id
  # Delete a log entry.
  def destroy
    @log.destroy!
    head :no_content
  end

  private

  def set_session
    # Try to find by slug first, then by ID
    @session = Session.find_by(slug: params[:session_id]) || Session.find(params[:session_id])
  end

  def set_log
    @log = @session.logs.find(params[:id])
  end

  def log_params
    params.permit(:content, :level)
  end

  def log_json(log)
    {
      id: log.id,
      session_id: log.session_id,
      content: log.content,
      level: log.level,
      created_at: log.created_at.iso8601,
      updated_at: log.updated_at.iso8601
    }
  end
end
