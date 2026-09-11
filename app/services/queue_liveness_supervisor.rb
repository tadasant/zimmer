# frozen_string_literal: true

# Runs QueueLivenessWatchdog on a background thread inside the web (Puma) process.
#
# This is the out-of-band execution path #427 asks for: a single lightweight thread,
# started only in the web server process (see
# config/initializers/queue_liveness_watchdog.rb), that ticks the watchdog on an
# interval. It is modelled on the shape the deleted PeriodicCatalogRefresher used --
# `Concurrent::Event` for "sleep interval, but wake immediately on stop!", cooperative
# shutdown rather than `Thread#kill`, idempotent `start!` -- because that shape was
# proven at runtime in production for the same web-process-thread purpose.
#
# It does NOT run in the worker (the worker's cron already runs SystemHealthMonitorJob,
# and the worker is the failure domain this exists to escape), nor in rake / console /
# runner / agent-session processes. The single watchdog instance is retained across
# ticks so its consecutive-stall streak (the hysteresis) persists.
class QueueLivenessSupervisor
  # How often the web process asks "is the queue executing anything?". 60 seconds keeps
  # detection latency to about a minute past the ten-minute silence `execution_stall`
  # requires, while a single tick is one HealthMonitorService#system_health read.
  DEFAULT_INTERVAL_SECONDS = Integer(ENV.fetch("QUEUE_LIVENESS_WATCHDOG_INTERVAL_SECONDS", 60))

  # How long `stop!` waits for an in-flight tick to finish before giving up and leaving
  # the thread to exit on its own. A tick is a handful of database reads, so this is
  # comfortable headroom.
  STOP_TIMEOUT = 5

  class << self
    # Start the background watchdog thread. Idempotent: a second call while a thread is
    # already alive is a no-op and returns the existing thread.
    #
    # @param interval [Numeric] seconds between checks
    # @param watchdog [QueueLivenessWatchdog] injectable for tests
    # @return [Thread] the (new or existing) supervising thread
    def start!(interval: DEFAULT_INTERVAL_SECONDS, watchdog: QueueLivenessWatchdog.new)
      return @thread if @thread&.alive?

      @watchdog = watchdog
      stop_event = @stop_event = Concurrent::Event.new

      @thread = Thread.new do
        Thread.current.name = "queue-liveness-watchdog"
        # Event#wait returns true the instant the event is set and false on timeout,
        # so this is "sleep for `interval`, but wake immediately on stop!".
        check_once until stop_event.wait(interval)
      end
    end

    # True while the supervising thread is alive.
    def running?
      @thread&.alive? || false
    end

    # Stop the background thread. Primarily a test hook; in production the thread lives
    # for the life of the process and dies with it on SIGTERM. Cooperative rather than
    # `Thread#kill`: the tick talks to the database, and an asynchronous kill inside
    # ActiveRecord's connection handling can return a half-configured adapter to the
    # pool (the reason PeriodicCatalogRefresher#stop! was written this way, zimmer#706).
    #
    # @return [Boolean] true if the thread finished within the timeout
    def stop!(timeout: STOP_TIMEOUT)
      @stop_event&.set

      if @thread && !@thread.join(timeout)
        Rails.logger.warn(
          "[QueueLivenessSupervisor] Watchdog tick still running #{timeout}s after stop!; " \
          "leaving the thread to finish rather than killing it"
        )
        return false
      end

      @thread = nil
      @stop_event = nil
      @watchdog = nil
      true
    end

    private

    # One watchdog tick. Wrapped in the Rails executor so ActiveRecord connections are
    # checked out and returned correctly for this background thread, and rescue-all so
    # nothing a tick can throw ever kills the supervising thread -- the watchdog already
    # rescues its own read failures, this is the belt to that braces.
    def check_once
      Rails.application.executor.wrap do
        @watchdog.check!
      end
    rescue => e
      Rails.logger.error(
        "[QueueLivenessSupervisor] Watchdog tick raised (thread continues): #{e.class}: #{e.message}"
      )
    end
  end
end
