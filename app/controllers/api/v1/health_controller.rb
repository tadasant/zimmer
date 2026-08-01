# API controller for system health monitoring and maintenance operations.
#
# Provides health diagnostics, process cleanup, session retry, and archiving.
#
# All endpoints require API key authentication via X-API-Key header.
class Api::V1::HealthController < Api::BaseController
  # Bounds for archive days
  MAX_ARCHIVE_DAYS = 365
  MIN_ARCHIVE_DAYS = 1

  # GET /api/v1/health
  # Get full system health report.
  def show
    service = HealthMonitorService.new
    report = service.full_health_report

    render json: {
      health_report: report,
      timestamp: Time.current.iso8601,
      rails_env: Rails.env,
      ruby_version: RUBY_VERSION
    }
  end

  # POST /api/v1/health/cleanup_processes
  # Terminate orphaned Claude CLI processes.
  def cleanup_processes
    return render_rate_limited if rate_limited?(:cleanup_processes)

    service = HealthMonitorService.new
    results = service.cleanup_orphaned_processes
    record_action(:cleanup_processes)

    render json: results
  end

  # POST /api/v1/health/retry_sessions
  # Retry failed sessions.
  #
  # Request body:
  #   - session_ids: Optional array of session IDs to retry (defaults to all failed)
  def retry_sessions
    return render_rate_limited if rate_limited?(:retry_sessions)

    session_ids = params[:session_ids]&.map(&:to_i)

    service = HealthMonitorService.new
    results = service.retry_failed_sessions(session_ids: session_ids)
    record_action(:retry_sessions)

    render json: results
  end

  # POST /api/v1/health/archive_old
  # Archive sessions older than N days.
  #
  # Request body:
  #   - days: Number of days (default: 7, min: 1, max: 365)
  def archive_old
    return render_rate_limited if rate_limited?(:archive_old)

    days = (params[:days] || 7).to_i.clamp(MIN_ARCHIVE_DAYS, MAX_ARCHIVE_DAYS)

    service = HealthMonitorService.new
    results = service.archive_old_sessions(older_than: days.days)
    record_action(:archive_old)

    render json: results
  end

  private

  # The cooldown object is shared with the native MCP server's action_health
  # tool, so the two surfaces throttle each other for the same caller.
  def cooldown
    @cooldown ||= HealthActionCooldown.new(HealthActionCooldown.fingerprint(api_key_from_request))
  end

  def rate_limited?(action)
    cooldown.limited?(action)
  end

  def record_action(action)
    cooldown.record(action)
  end

  def render_rate_limited
    unless cooldown.store_usable?
      Rails.logger.error("[health_api] refusing #{action_name}: Rails.cache is a NullStore, so the cooldown cannot be enforced")
      return render_api_error(
        "Rate limiting unavailable",
        "No usable cache store is configured, so the #{HealthActionCooldown::COOLDOWN.to_i}-second cooldown cannot be enforced. Refusing to run health maintenance actions.",
        status: :service_unavailable
      )
    end

    render_api_error(
      "Rate limited",
      "Please wait #{HealthActionCooldown::COOLDOWN.to_i} seconds between actions",
      status: :too_many_requests,
      retry_after: HealthActionCooldown::COOLDOWN.to_i
    )
  end
end
