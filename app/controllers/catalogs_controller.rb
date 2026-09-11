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
    # The refresh runs once, in the worker, as the same CatalogRefreshJob the
    # 15-minute cron runs: it fetches the worker's ~/.air/cache — the one
    # `air prepare` reads during session creation — and stores the result as the
    # newest CatalogSnapshot. This web process does not fetch or resolve; it
    # serves that snapshot, so once the job finishes it picks the snapshot up
    # immediately rather than on its next TTL tick. Synced whatever the outcome:
    # a failed refresh is recorded on the snapshot, and that is what puts the
    # failure banner on the page this redirects to.
    worker_result = CatalogRefreshJob.perform_and_wait(timeout: WORKER_REFRESH_TIMEOUT_SECONDS)
    AirCatalogService.sync_from_snapshot!

    redirect_with_refresh_result(worker_result)
  end

  private

  def redirect_with_refresh_result(worker_result)
    # Scrubbed for the same reason the banner's message is (#319): this flash is
    # `air update`'s own text, produced by a process holding AIR_GITHUB_TOKEN,
    # and redirect_back lands it on /sessions/new — which has no Rails-layer
    # authentication (#312).
    error = AirCatalogService.redact_secrets(normalize_worker_error(worker_result.error_message))

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

  # GoodJob records a failed job's error as "ExceptionClass: message". Strip the
  # leading class prefix so the flash reads "Catalog refresh failed: <message>",
  # the same wording the failure banner uses.
  def normalize_worker_error(message)
    return message if message.nil?

    message.sub(/\A[A-Z]\w*(::[A-Z]\w*)*: /, "")
  end
end
