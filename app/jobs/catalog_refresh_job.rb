# frozen_string_literal: true

# Background job to refresh AIR catalog sources (skills, servers, agent roots, etc.)
#
# Runs every 15 minutes via cron. Calls AirCatalogService.refresh!, which fetches
# the latest commits for any github sources declared in air.json (refreshing the
# on-disk ~/.air/cache provider clones) and reloads the in-memory entries cache.
#
# This job is ALSO the execution unit behind the manual "Refresh catalogs" button
# (CatalogsController#refresh). The button cannot just call AirCatalogService.refresh!
# inline: ~/.air/cache is per-process on-disk state, and in production the web
# (Puma) and worker (GoodJob) run in separate containers with separate
# filesystems. A web-process refresh never touches the worker's cache — the cache
# AirPrepareService reads during session preparation — so the button felt
# ineffective while only the worker-resident cron made session creation healthy.
# Routing the button through this job runs the refresh in the worker, the same
# place `air prepare` consumes the cache, so the two paths converge on one
# operation rather than diverging by process.
class CatalogRefreshJob < ApplicationJob
  queue_as :pollers

  # Shared key for both the cron run and button-triggered runs, so a button click
  # while the cron is mid-refresh latches onto the in-flight run instead of
  # queuing a duplicate (see .enqueue_or_find_inflight).
  CONCURRENCY_KEY = "catalog_refresh"

  good_job_control_concurrency_with(
    key: -> { CONCURRENCY_KEY },
    total_limit: 1
  )

  WAIT_POLL_INTERVAL_SECONDS = 1.0

  # Outcome of a synchronous wait (see .perform_and_wait). status is one of
  # :ok, :failed, :timeout.
  WaitResult = Struct.new(:status, :error_message, keyword_init: true) do
    def ok? = status == :ok
    def failed? = status == :failed
    def timed_out? = status == :timeout
  end

  def perform
    AirCatalogService.refresh!
    Rails.logger.info "[CatalogRefreshJob] Catalog refresh completed"
  rescue AirCatalogService::CatalogError => e
    # Re-raise after logging so the persisted GoodJob record reflects the failure.
    # The manual /catalogs/refresh endpoint enqueues this job and waits on that
    # record to report a truthful result to the user; a swallowed error would
    # surface as a false "refreshed successfully". The .error log is preserved
    # (per logging philosophy) because a refresh failure does not self-resolve —
    # it requires a fixed upstream catalog before the next run succeeds.
    Rails.logger.error "[CatalogRefreshJob] Catalog refresh failed: #{e.message}"
    raise
  end

  class << self
    # Enqueue a refresh onto the worker (where AirPrepareService consumes the
    # cache) and block until it finishes, so the caller can trust the worker's
    # on-disk catalog cache is current on return. Because the job runs in a
    # different process/container than the caller, completion is observed by
    # polling the persisted GoodJob record rather than any in-memory state.
    #
    # @param timeout [Numeric] max seconds to wait before returning :timeout
    # @param poll_interval [Numeric] seconds between record polls
    # @param clock [#clock_gettime] injectable monotonic clock (tests)
    # @param sleeper [#call] injectable sleeper (tests)
    # @return [WaitResult]
    def perform_and_wait(timeout:, poll_interval: WAIT_POLL_INTERVAL_SECONDS, clock: Process, sleeper: method(:sleep))
      job_id = enqueue_or_find_inflight
      # Nothing to wait on: the enqueue was rejected by concurrency control and no
      # in-flight run exists (it finished in the race window). Report timeout so
      # the caller surfaces "still settling" rather than a false success.
      return WaitResult.new(status: :timeout, error_message: nil) if job_id.nil?

      deadline = clock.clock_gettime(Process::CLOCK_MONOTONIC) + timeout

      # Bypass the ActiveRecord per-request query cache for the polling loop. This
      # method is invoked from a web request (CatalogsController#refresh), where the
      # query cache is active for the duration of the request. Without uncached, the
      # first find_by snapshot (finished_at: nil) is cached and every subsequent
      # identical poll returns that same stale row — so the loop never observes the
      # job finishing in another process and always runs to the timeout, reporting a
      # false "still running in the background" even when the refresh succeeded in
      # seconds. uncached forces each poll to hit the database.
      GoodJob::Job.uncached do
        loop do
          record = GoodJob::Job.find_by(id: job_id)

          # A vanished record means the job ran to completion and was reaped without
          # leaving an error behind: treat as success.
          return WaitResult.new(status: :ok, error_message: nil) if record.nil?

          if record.finished_at.present?
            return WaitResult.new(status: :failed, error_message: record.error) if record.error.present?

            return WaitResult.new(status: :ok, error_message: nil)
          end

          if clock.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
            return WaitResult.new(status: :timeout, error_message: nil)
          end

          sleeper.call(poll_interval)
        end
      end
    end

    # Enqueue a fresh run and return its provider job id. If concurrency control
    # rejected the enqueue (a refresh is already in flight — typically the cron
    # run), latch onto that in-flight job so we wait on the work already happening
    # rather than failing or duplicating it. Returns nil when neither a new nor an
    # in-flight job is available to wait on.
    def enqueue_or_find_inflight
      enqueued = perform_later
      if enqueued.respond_to?(:successfully_enqueued?) && enqueued.successfully_enqueued?
        return enqueued.provider_job_id
      end

      # total_limit: 1 means there is at most one unfinished row for this key, so
      # the ordering is academic in practice; oldest-first is chosen so that if an
      # earlier run is somehow still settling we wait on it rather than a newer one.
      GoodJob::Job.where(concurrency_key: CONCURRENCY_KEY, finished_at: nil)
                  .order(created_at: :asc)
                  .pick(:id)
    end
  end
end
