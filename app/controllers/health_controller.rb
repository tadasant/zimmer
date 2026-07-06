# frozen_string_literal: true

# Controller for the health check dashboard
#
# Provides system health monitoring, diagnostics, and cleanup actions.
# All actions require user interaction for safety (no automated cleanup).
class HealthController < ApplicationController
  # Rate limiting cooldown period
  CLEANUP_COOLDOWN = 30.seconds
  # Maximum days for archive operation (security bound)
  MAX_ARCHIVE_DAYS = 365
  # Minimum days for archive operation
  MIN_ARCHIVE_DAYS = 1

  def dashboard
    @health_service = HealthMonitorService.new
    @health_report = @health_service.full_health_report
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

  # Rate limiting using Rails cache for thread-safety and persistence
  def rate_limited?(action)
    cache_key = "health_controller_rate_limit:#{action}"
    last_time = Rails.cache.read(cache_key)
    return false unless last_time

    Time.current - last_time < CLEANUP_COOLDOWN
  end

  def record_action(action)
    cache_key = "health_controller_rate_limit:#{action}"
    Rails.cache.write(cache_key, Time.current, expires_in: CLEANUP_COOLDOWN + 1.second)
  end

  def render_rate_limited
    respond_to do |format|
      format.html do
        flash[:alert] = "Please wait #{CLEANUP_COOLDOWN.to_i} seconds between cleanup actions"
        redirect_to health_dashboard_path
      end
      format.json do
        render json: { error: "Rate limited", retry_after: CLEANUP_COOLDOWN.to_i }, status: :too_many_requests
      end
    end
  end
end
