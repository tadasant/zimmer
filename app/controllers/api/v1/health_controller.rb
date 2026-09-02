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
      queue_recovery_mode: QueueRecoveryMode.status.as_json,
      timestamp: Time.current.iso8601,
      rails_env: Rails.env,
      ruby_version: RUBY_VERSION
    }
  end

  # GET /api/v1/health/queue_recovery_mode
  # Whether the demand-side job queues are currently halted, and until when.
  def queue_recovery_mode
    render json: QueueRecoveryMode.status.as_json
  end

  # POST /api/v1/health/enter_queue_recovery_mode
  # Halt the demand-side job queues (`pollers`, `triggers`, `inference`, `default`) so a
  # backlog can be investigated. `agents` keeps running, so sessions still start
  # and run. See QueueRecoveryMode.
  #
  # Request body:
  #   - reason: Optional free text shown in the UI banner and the Slack alert
  #   - ttl_minutes: Optional auto-exit window, clamped to 5..240 (default 60)
  #
  # Deliberately not behind HealthActionCooldown — see the same note on
  # HealthController#enter_queue_recovery_mode.
  def enter_queue_recovery_mode
    status = QueueRecoveryMode.enter!(
      reason: params[:reason],
      ttl: params[:ttl_minutes].presence&.to_i&.minutes,
      actor: "REST API"
    )

    render json: status.as_json
  rescue QueueRecoveryMode::NotAvailable => e
    render_api_error("Queue recovery mode unavailable", e.message, status: :service_unavailable)
  end

  # POST /api/v1/health/run_post_deploy_tasks
  # Re-arm any failed one-time post-deploy task and enqueue a pass.
  #
  # Their current state is already in GET /api/v1/health under
  # `health_report.post_deploy_task_health`; this is the action that unsticks one
  # without a shell on the box. Idempotent, and deliberately not rate-limited:
  # it enqueues a job and rewrites nothing in bulk.
  def run_post_deploy_tasks
    render json: PostDeployTask::Runner.request!
  end

  # POST /api/v1/health/exit_queue_recovery_mode
  # Resume normal processing. Idempotent, and never gated: the way out of a halt
  # must always be available.
  def exit_queue_recovery_mode
    render json: QueueRecoveryMode.exit!(actor: "REST API").as_json
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
      Rails.logger.error("[health_api] refusing #{action_name}: the cache cannot enforce the cooldown")
      return render_api_error(
        "Rate limiting unavailable",
        "The cache is unavailable, so the #{HealthActionCooldown::COOLDOWN.to_i}-second cooldown cannot be enforced. Refusing to run health maintenance actions.",
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
