# Base controller for API v1 endpoints.
# Provides API key authentication via the X-API-Key header.
#
# API keys are configured via the API_KEYS environment variable as a
# comma-separated list of valid keys.
#
# Example:
#   API_KEYS=key1,key2,key3
#
# Usage:
#   curl -H "X-API-Key: your_api_key" https://example.com/api/v1/sessions
class Api::BaseController < ActionController::API
  include ControllerDatabaseRetry

  before_action :authenticate_api_key

  # Return 404 for not found records
  rescue_from ActiveRecord::RecordNotFound, with: :not_found

  # Return 422 for validation errors
  rescue_from ActiveRecord::RecordInvalid, with: :unprocessable_entity

  private

  def authenticate_api_key
    api_key = api_key_from_request

    # Use constant-time comparison to prevent timing attacks
    unless api_key.present? && valid_api_keys.any? { |valid_key| ActiveSupport::SecurityUtils.secure_compare(valid_key, api_key) }
      render json: { error: "Unauthorized", message: "Invalid or missing API key" }, status: :unauthorized
    end
  end

  # Where the key lives on the request. Subclasses may widen this — the native
  # MCP endpoint also accepts `Authorization: Bearer <key>`, since MCP clients
  # configure a bearer token rather than a custom header.
  def api_key_from_request
    request.headers["X-API-Key"]
  end

  def valid_api_keys
    @valid_api_keys ||= begin
      keys_string = ENV.fetch("API_KEYS", "")
      keys_string.split(",").map(&:strip).reject(&:empty?)
    end
  end

  def not_found
    render json: { error: "Not Found", message: "The requested resource was not found" }, status: :not_found
  end

  def unprocessable_entity(exception)
    render json: { error: "Unprocessable Entity", message: exception.record.errors.full_messages }, status: :unprocessable_entity
  end

  # Pagination helper with validation
  def pagination_params
    {
      page: [ params[:page]&.to_i || 1, 1 ].max, # Minimum page 1
      per_page: [ [ params[:per_page]&.to_i || 25, 1 ].max, 100 ].min # Between 1-100
    }
  end

  # Apply pagination to a scope
  def paginate(scope)
    pagination = pagination_params
    offset = (pagination[:page] - 1) * pagination[:per_page]

    total = scope.count # Call count once for efficiency
    {
      records: scope.limit(pagination[:per_page]).offset(offset),
      pagination: {
        page: pagination[:page],
        per_page: pagination[:per_page],
        total_count: total,
        total_pages: (total.to_f / pagination[:per_page]).ceil
      }
    }
  end
end
