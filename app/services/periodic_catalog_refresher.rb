# frozen_string_literal: true

# Keeps the web (Puma) container's on-disk AIR catalog cache fresh between deploys.
#
# In production the web (Puma) and worker (GoodJob) run in SEPARATE containers with
# SEPARATE ephemeral filesystems, so ~/.air/cache is per-container state.
# CatalogRefreshJob (the */15 cron that runs `air update` to re-fetch the github
# provider clones) executes ONLY in the worker, so it keeps only the WORKER cache
# fresh. The web container's cache is otherwise refreshed just once, at boot, by
# config/initializers/air_catalog.rb. Between web deploys nothing re-fetches the web
# cache, so everything the web serves from the catalog — AirCatalogService.entries_for
# (get_configs, the Zimmer UI's view of available MCP servers / agent roots / skills) and
# start_session MCP-name validation — drifts stale for up to a full deploy cycle after
# a harness change merges to tadasant/zimmer-catalog main.
#
# This supervisor runs a single lightweight background thread inside the web process
# that periodically calls AirCatalogService.refresh! (the same operation the worker's
# cron performs), so the web keeps its OWN cache fresh on a schedule. Each container
# refreshes its own cache independently; there is no shared mutable git cache and thus
# no cross-container writer race.
#
# It is started only from the web server process (see config/initializers/air_catalog.rb),
# so it never runs alongside the worker's cron (which already covers the worker cache)
# or in short-lived rake / console / runner processes.
class PeriodicCatalogRefresher
  # How often the web re-fetches provider caches. 5 minutes keeps the read surface
  # (get_configs / MCP-name validation) fresher than the worker's own 15-minute cron
  # while an `air update` (a git fetch of a few small repos) stays cheap.
  DEFAULT_INTERVAL_SECONDS = Integer(ENV.fetch("WEB_CATALOG_REFRESH_INTERVAL_SECONDS", 300))

  # How long `stop!` waits for an in-flight refresh to finish. A bound on the
  # caller's wait, not on the thread — see `stop!`.
  STOP_TIMEOUT = 5

  class << self
    # Start the background refresh thread. Idempotent: a second call while a thread
    # is already alive is a no-op and returns the existing thread.
    #
    # @param interval [Numeric] seconds between refreshes
    # @return [Thread] the (new or existing) supervising thread
    def start!(interval: DEFAULT_INTERVAL_SECONDS)
      return @thread if @thread&.alive?

      stop_event = @stop_event = Concurrent::Event.new

      @thread = Thread.new do
        Thread.current.name = "web-catalog-refresher"
        # Event#wait returns true the moment the event is set and false on
        # timeout, so this is "sleep for `interval`, but wake immediately on
        # stop!" — the refresh interval never becomes the shutdown latency.
        refresh_once until stop_event.wait(interval)
      end
    end

    # True while the supervising thread is alive.
    def running?
      @thread&.alive? || false
    end

    # Stop the background thread. Primarily a test hook; in production the thread
    # lives for the life of the process and dies with it on SIGTERM.
    #
    # Cooperative rather than `Thread#kill`: refresh_once talks to the database
    # (AirCatalogService persists a catalog snapshot), and an asynchronous kill
    # inside ActiveRecord's connection setup can return a half-configured adapter
    # to the pool — see AgentSessionJob::LogStream and zimmer#706.
    #
    # A refresh already in flight is `air update`, a git fetch of several repos, so
    # it can outlast the join. When it does we keep the ivars: dropping them would
    # make `running?` report false while a thread is still alive, defeat `start!`'s
    # idempotency guard (spawning a SECOND refresher alongside the first), and throw
    # away the only handle that could ever stop it. The event stays set, so the
    # thread still exits as soon as its refresh returns, and a later `stop!` — or the
    # `start!` that would otherwise have doubled up — sees it gone.
    #
    # @return [Boolean] true if the thread finished within the timeout
    def stop!(timeout: STOP_TIMEOUT)
      @stop_event&.set

      if @thread && !@thread.join(timeout)
        Rails.logger.warn(
          "[PeriodicCatalogRefresher] Refresh still running #{timeout}s after stop!; " \
          "leaving the thread to finish rather than killing it (zimmer#706)"
        )
        return false
      end

      @thread = nil
      @stop_event = nil
      true
    end

    # One refresh tick: pull the latest provider caches into THIS process's on-disk
    # AIR cache and reload the in-memory tree. Wrapped in the Rails executor so
    # ActiveRecord connections are checked out/in correctly (AirCatalogService
    # persists a catalog snapshot on success), and rescue-all so a transient failure
    # never kills the supervising thread — it simply retries on the next interval.
    #
    # Logged at .info on both success and handled failure: a single failed fetch is
    # transient and self-resolves on retry, so it does not warrant an alert. The
    # genuine "catalog is persistently broken" alerting already lives in
    # AirCatalogService (serve_last_known_good! escalates on the healthy→degraded
    # transition), so escalating here too would only duplicate it.
    def refresh_once
      Rails.application.executor.wrap do
        AirCatalogService.refresh!
        Rails.logger.info "[PeriodicCatalogRefresher] Refreshed web catalog cache"
      end
    rescue => e
      Rails.logger.info "[PeriodicCatalogRefresher] Refresh failed (will retry next interval): #{e.class}: #{e.message}"
    end
  end
end
