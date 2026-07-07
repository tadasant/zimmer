# frozen_string_literal: true

class CatalogsController < ApplicationController
  # How long the request blocks waiting for the worker-side refresh before
  # reporting that it is still settling. `air update` is an incremental git fetch
  # of a few catalog repos — normally a few seconds — but the ceiling is generous
  # to absorb a cold/slow github.com fetch. Overridable via ENV for ops tuning.
  #
  # Keep this safely UNDER the Cloudflare edge proxy timeout (~100s; Zimmer is served
  # Cloudflare → Hatchbox → Rails). If the wait can outlast the edge, a genuinely
  # slow refresh is cut off with a generic 524 page instead of the "still running
  # in the background" alert below — and the request also pins a Puma thread (only
  # RAILS_MAX_THREADS, default 3, in prod) for its whole duration. Do not raise the
  # ENV override to/over ~100s without also raising the Cloudflare timeout.
  WORKER_REFRESH_TIMEOUT_SECONDS = Integer(ENV.fetch("CATALOG_REFRESH_WAIT_SECONDS", "90"))

  def refresh
    # The AIR catalog cache (~/.air/cache) is per-process on-disk state. In
    # production the web (Puma) and worker (GoodJob) run in separate containers
    # with separate filesystems, so refreshing only this web process leaves the
    # worker — where AirPrepareService runs `air prepare` during session
    # creation — on a stale cache, which is why clicking the button used to feel
    # ineffective. Refresh BOTH surfaces so one click leaves catalogs in sync for
    # the next session:
    #   1. this web process, which drives the catalog pickers rendered on the
    #      New Session page, and
    #   2. the worker process, which drives session preparation, via the same
    #      CatalogRefreshJob the 15-minute cron runs.
    web_error = refresh_web_process
    worker_result = CatalogRefreshJob.perform_and_wait(timeout: WORKER_REFRESH_TIMEOUT_SECONDS)

    redirect_with_refresh_result(web_error, worker_result)
  end

  private

  # Refresh this (web) process's cache and in-memory tree. Returns nil on success
  # or the error message on failure.
  def refresh_web_process
    AirCatalogService.refresh!
    nil
  rescue AirCatalogService::CatalogError => e
    e.message
  end

  def redirect_with_refresh_result(web_error, worker_result)
    error = web_error || normalize_worker_error(worker_result.error_message)

    if error
      redirect_back(fallback_location: new_session_path,
                    alert: "Catalog refresh failed: #{error}")
    elsif worker_result.timed_out?
      redirect_back(fallback_location: new_session_path,
                    alert: "Catalog refresh is still running in the background. " \
                           "Wait a moment and check the \"Updated … ago\" indicator before creating a session.")
    else
      last_refreshed = AirCatalogService.last_refreshed_at
      timestamp = last_refreshed ? last_refreshed.strftime("%b %d, %Y %H:%M:%S %Z") : "just now"
      redirect_back(fallback_location: new_session_path,
                    notice: "Catalogs refreshed successfully (#{timestamp})")
    end
  end

  # GoodJob records a failed job's error as "ExceptionClass: message", whereas the
  # web-process path surfaces the bare exception message. Strip the leading class
  # prefix so both paths produce an identical "Catalog refresh failed: <message>"
  # flash for the same underlying failure.
  def normalize_worker_error(message)
    return message if message.nil?

    message.sub(/\A[A-Z]\w*(::[A-Z]\w*)*: /, "")
  end
end
