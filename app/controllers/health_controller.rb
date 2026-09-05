# frozen_string_literal: true

# Controller for the health check dashboard
#
# Provides system health monitoring, diagnostics, and cleanup actions.
# All actions require user interaction for safety (no automated cleanup).
class HealthController < ApplicationController
  # Maximum days for archive operation (security bound)
  MAX_ARCHIVE_DAYS = 365
  # Minimum days for archive operation
  MIN_ARCHIVE_DAYS = 1

  def dashboard
    @health_service = HealthMonitorService.new
    @health_report = @health_service.full_health_report
  end

  # GET /up/deep
  #
  # The strict sibling of `/up`. `/up` answers 200 for a process that booted;
  # this answers 200 only when the database, the cache, and Redis each responded
  # to a real round trip, and 503 naming the one that did not. DeepHealthCheck
  # carries the reasoning, including why this is deliberately not behind the
  # HealthActionCooldown that guards the maintenance actions below.
  def deep
    report = DeepHealthCheck.new.call

    render json: report, status: report[:status] == "ok" ? :ok : :service_unavailable
  end

  def refresh
    @health_service = HealthMonitorService.new
    @health_report = @health_service.full_health_report

    respond_to do |format|
      format.html { render partial: "health_content", locals: { health_report: @health_report } }
      format.json { render json: @health_report }
    end
  end

  def cleanup_processes
    return render_rate_limited if rate_limited?(:cleanup_processes)

    @health_service = HealthMonitorService.new
    results = @health_service.cleanup_orphaned_processes

    record_action(:cleanup_processes)

    respond_to do |format|
      format.html do
        if results[:terminated].any? || results[:already_dead].any?
          flash[:notice] = "Cleanup complete: #{results[:terminated].size} terminated, #{results[:already_dead].size} already dead"
        elsif results[:failed].any?
          flash[:alert] = "Cleanup partially failed: #{results[:failed].size} processes could not be terminated"
        else
          flash[:notice] = "No orphaned processes to clean up"
        end
        redirect_to health_dashboard_path
      end
      format.json { render json: results }
    end
  end

  # POST /health/run_post_deploy_tasks
  #
  # Re-arm any failed one-time post-deploy task and kick a pass. The mechanism
  # runs itself after every deploy; this is the surface for the case it cannot
  # handle on its own — a task that failed for a reason somebody has now fixed —
  # so that unsticking it does not need a shell on the box.
  #
  # Not behind HealthActionCooldown: it terminates nothing and rewrites nothing
  # in bulk, and the way to restart a stuck rollout should work first time.
  def run_post_deploy_tasks
    result = PostDeployTask::Runner.request!

    respond_to do |format|
      format.html do
        flash[:notice] = if result[:rearmed].positive?
          "Re-armed #{result[:rearmed]} post-deploy task#{'s' unless result[:rearmed] == 1} and queued a run"
        else
          "Queued a post-deploy task run"
        end
        redirect_to health_dashboard_path
      end
      format.json { render json: result }
    end
  end

  def retry_sessions
    return render_rate_limited if rate_limited?(:retry_sessions)

    session_ids = params[:session_ids]&.map(&:to_i)

    @health_service = HealthMonitorService.new
    results = @health_service.retry_failed_sessions(session_ids: session_ids)

    record_action(:retry_sessions)

    respond_to do |format|
      format.html do
        flash_for_retry(results)
        redirect_to health_dashboard_path
      end
      format.json { render json: results }
    end
  end

  def archive_old
    return render_rate_limited if rate_limited?(:archive_old)

    # Validate days parameter with bounds checking
    days = (params[:days] || 7).to_i
    days = days.clamp(MIN_ARCHIVE_DAYS, MAX_ARCHIVE_DAYS)
    older_than = days.days

    @health_service = HealthMonitorService.new
    results = @health_service.archive_old_sessions(older_than: older_than)

    record_action(:archive_old)

    respond_to do |format|
      format.html do
        if results[:archived].any?
          flash[:notice] = "Moved #{results[:archived].size} old session(s) to trash"
        elsif results[:failed].any?
          flash[:alert] = "Failed to trash #{results[:failed].size} session(s)"
        else
          flash[:notice] = "No old sessions to trash"
        end
        redirect_to health_dashboard_path
      end
      format.json { render json: results }
    end
  end

  # POST /health/enter_queue_recovery_mode
  #
  # Halts the demand-side job queues so the cause of a backlog can be
  # investigated. See QueueRecoveryMode — in particular, this does NOT halt
  # `agents`, so sessions can still be started and can still run.
  #
  # Deliberately NOT behind HealthActionCooldown. The cooldown exists to throttle
  # bulk mutations (terminating processes, rewriting session rows); this writes two
  # rows. More importantly, its partner action must work on the first try during an
  # incident, and a cooldown that fails closed when the cache is down — which is a
  # plausible symptom of the very overload being recovered from — would be a lock
  # on the escape hatch.
  def enter_queue_recovery_mode
    status = QueueRecoveryMode.enter!(
      reason: params[:reason],
      ttl: recovery_mode_ttl,
      actor: "web UI"
    )

    respond_to do |format|
      format.html do
        flash[:notice] = "Queue recovery mode ON — #{QueueRecoveryMode::HALTED_QUEUES.join(", ")} halted, " \
          "auto-resuming at #{status.expires_at&.strftime("%H:%M UTC")}."
        redirect_to health_dashboard_path
      end
      format.json { render json: status.as_json }
    end
  rescue QueueRecoveryMode::NotAvailable => e
    respond_to do |format|
      format.html do
        flash[:alert] = e.message
        redirect_to health_dashboard_path
      end
      format.json { render json: { error: "Queue recovery mode unavailable", message: e.message }, status: :service_unavailable }
    end
  end

  # POST /health/exit_queue_recovery_mode
  #
  # Resumes normal processing. Idempotent, and never rate-limited or gated: the
  # way out of a halt must always be available.
  def exit_queue_recovery_mode
    status = QueueRecoveryMode.exit!(actor: "web UI")

    respond_to do |format|
      format.html do
        flash[:notice] = "Queue recovery mode OFF — background job processing resumed."
        redirect_to health_dashboard_path
      end
      format.json { render json: status.as_json }
    end
  end

  def export_diagnostics
    @health_service = HealthMonitorService.new
    @health_report = @health_service.full_health_report

    respond_to do |format|
      format.json do
        render json: {
          health_report: @health_report,
          exported_at: Time.current,
          rails_env: Rails.env,
          ruby_version: RUBY_VERSION
        }
      end
    end
  end

  private

  # Report every bucket of a retry, not just the two that used to be flashed.
  #
  # `skipped` carries a reason per session — a missing working directory, or a
  # recovery turn `Session#claim_system_recovery_turn!` refused because the row is
  # in the trash, already running, or superseded by the session that replaced it.
  # Flashing counts and dropping that list left
  # the dashboard saying "No sessions to retry" to an operator who had just asked
  # for one specific session by id, which is indistinguishable from a bug. The
  # JSON surfaces have always returned the whole hash; this is the HTML one
  # catching up.
  #
  # @param results [Hash] from HealthMonitorService#retry_failed_sessions
  def flash_for_retry(results)
    parts = []
    parts << "Retry initiated for #{results[:retried].size} session(s)" if results[:retried].any?
    parts << "Failed to retry #{results[:failed].size} session(s)" if results[:failed].any?
    if results[:skipped].any?
      reasons = results[:skipped].map { |entry| entry[:reason] }.uniq.join(" ")
      parts << "Skipped #{results[:skipped].size} session(s). #{reasons}"
    end

    return flash[:notice] = "No sessions to retry" if parts.empty?

    # Only a genuine failure is an alert. A skip is not one: the bulk "retry all
    # recent failures" flow legitimately passes over sessions whose clone is gone,
    # and colouring that red would page the dashboard on every ordinary sweep. The
    # reason still rides along in the message, which is the part that was missing.
    if results[:failed].any?
      flash[:alert] = parts.join(". ")
    else
      flash[:notice] = parts.join(". ")
    end
  end

  # Minutes from the form, converted to a Duration. Blank means the default;
  # QueueRecoveryMode clamps whatever arrives into MIN_TTL..MAX_TTL, so a hand-typed
  # "9999" becomes the cap rather than an error.
  def recovery_mode_ttl
    minutes = params[:ttl_minutes]
    return nil if minutes.blank?

    minutes.to_i.minutes
  end

  # The same cooldown Api::V1::HealthController and the MCP action_health tool
  # enforce — the same object, so a caller cannot get a second run out of one
  # cooldown by switching surfaces.
  #
  # This surface has no key to fingerprint: the web UI has no authentication at
  # all, so every visitor lands in the one anonymous bucket. That is the global
  # cooldown this controller has always had. What is new is that it fails closed
  # when the cache cannot enforce it, instead of silently waving every action
  # through.
  def cooldown
    @cooldown ||= HealthActionCooldown.new(nil)
  end

  def rate_limited?(action)
    cooldown.limited?(action)
  end

  def record_action(action)
    cooldown.record(action)
  end

  def render_rate_limited
    if cooldown.store_usable?
      render_cooldown_pending
    else
      render_cooldown_unenforceable
    end
  end

  def render_cooldown_pending
    respond_to do |format|
      format.html do
        flash[:alert] = "Please wait #{HealthActionCooldown::COOLDOWN.to_i} seconds between cleanup actions"
        redirect_to health_dashboard_path
      end
      format.json do
        render json: { error: "Rate limited", retry_after: HealthActionCooldown::COOLDOWN.to_i }, status: :too_many_requests
      end
    end
  end

  def render_cooldown_unenforceable
    Rails.logger.error("[health] refusing #{action_name}: the cache cannot enforce the cooldown")
    message = "The cache is unavailable, so the #{HealthActionCooldown::COOLDOWN.to_i}-second cooldown cannot be enforced. " \
      "Maintenance actions are disabled until it is back."

    respond_to do |format|
      format.html do
        flash[:alert] = message
        redirect_to health_dashboard_path
      end
      format.json do
        render json: { error: "Rate limiting unavailable", message: message }, status: :service_unavailable
      end
    end
  end
end
