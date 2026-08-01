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

  def retry_sessions
    return render_rate_limited if rate_limited?(:retry_sessions)

    session_ids = params[:session_ids]&.map(&:to_i)

    @health_service = HealthMonitorService.new
    results = @health_service.retry_failed_sessions(session_ids: session_ids)

    record_action(:retry_sessions)

    respond_to do |format|
      format.html do
        if results[:retried].any?
          flash[:notice] = "Retry initiated for #{results[:retried].size} session(s)"
        elsif results[:failed].any?
          flash[:alert] = "Failed to retry #{results[:failed].size} session(s)"
        else
          flash[:notice] = "No sessions to retry"
        end
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
