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
  #
  # Read through ConnectionBudget.int_env rather than `Integer(ENV.fetch(...))`: this
  # constant is evaluated at eager-load, so a malformed value takes the whole web
  # container down before it can pass a health check. That helper treats blank as
  # absent (Kamal renders an unset `env: clear:` variable to ""), parses base 10 (so
  # "060" is 60 rather than octal 48), and refuses a non-positive value instead of
  # booting on a zero interval that would spin the thread against the database.
  DEFAULT_INTERVAL_SECONDS = ConnectionBudget.int_env("QUEUE_LIVENESS_WATCHDOG_INTERVAL_SECONDS", 60)

  # How long `stop!` waits for an in-flight tick to finish before giving up and leaving
  # the thread to exit on its own. A tick is a handful of database reads, so this is
  # comfortable headroom.
  STOP_TIMEOUT = 5

  # The escape hatch, honoured by `should_start?`.
  DISABLE_ENV_VAR = "QUEUE_LIVENESS_WATCHDOG_DISABLED"

  class << self
    # Should THIS process start a watchdog thread? The initializer's whole gate, in one
    # testable predicate rather than inline in the initializer body, because a gate that
    # silently stops being true puts Zimmer back in the #427 hole with nothing to show
    # for it. `system_health` reports this alongside `running?` for the same reason.
    #
    # Every input is injectable so the four combinations can be tested from a process
    # that is none of them.
    #
    # @param server [Boolean] is this the web server process? `Rails::Server` is defined
    #   under `bin/rails server` (the web container's CMD) but not under
    #   `good_job start` (worker), rake, console, runner, or an agent session.
    # @param env [String] Rails environment. Only the alerting environments have the obs
    #   pipeline this pages through, and only there are web and worker separate
    #   processes -- in development GoodJob runs `:async` inside Puma, so the web IS the
    #   worker and the out-of-band property does not exist.
    # @param disabled [String, nil] the escape hatch's raw value.
    def should_start?(server: defined?(Rails::Server) ? true : false,
                      env: Rails.env.to_s,
                      disabled: ENV[DISABLE_ENV_VAR])
      server && AlertingEnvironments::ALL.include?(env) && disabled != "true"
    end

    # Start the background watchdog thread. Idempotent: a second call while a thread is
    # already alive AND still supposed to be running is a no-op and returns the existing
    # thread.
    #
    # The `@stop_event` half of that guard matters: a `stop!` whose join timed out
    # deliberately leaves a live thread behind with its event already set, and that
    # thread exits as soon as its tick returns. Treating it as "already running" would
    # hand back a dying thread and leave the process with no watchdog at all, silently.
    #
    # @param interval [Numeric] seconds between checks
    # @param watchdog [QueueLivenessWatchdog] injectable for tests
    # @return [Thread] the (new or existing) supervising thread
    def start!(interval: DEFAULT_INTERVAL_SECONDS, watchdog: QueueLivenessWatchdog.new)
      return @thread if @thread&.alive? && !@stop_event&.set?

      stop_event = @stop_event = Concurrent::Event.new

      # Both are captured as locals rather than read off the class on every tick, so a
      # concurrent `stop!` clearing the ivars can never hand a running tick a nil
      # watchdog. The ivars exist for `running?` and `stop!`; the thread uses neither.
      @thread = Thread.new do
        Thread.current.name = "queue-liveness-watchdog"
        # Event#wait returns true the instant the event is set and false on timeout,
        # so this is "sleep for `interval`, but wake immediately on stop!".
        check_once(watchdog) until stop_event.wait(interval)
      end

      # The one line that says this process took up the job. Without it, a gate that
      # quietly stops being true is invisible: no log, no exception, just the #427 hole
      # back again. INFO because it is a lifecycle fact, not a fault.
      Rails.logger.info(
        "[QueueLivenessSupervisor] Out-of-band queue-liveness watchdog started " \
        "(interval=#{interval}s) in this web process"
      )

      @thread
    end

    # True while the supervising thread is alive. Read by `system_health` so "is the
    # out-of-band watchdog actually running?" is answerable without a shell on the box.
    # Necessarily a fact about THIS process -- the thread lives in one web process, and
    # `/health` is served by the same one.
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
        # Keep the handles: dropping them would make `running?` report false while a
        # thread is still alive. The event stays set, so the thread exits as soon as its
        # tick returns, and `start!`'s event check above will correctly build a fresh
        # one rather than adopting this dying thread.
        Rails.logger.warn(
          "[QueueLivenessSupervisor] Watchdog tick still running #{timeout}s after stop!; " \
          "leaving the thread to finish rather than killing it"
        )
        return false
      end

      @thread = nil
      @stop_event = nil
      true
    end

    private

    # One watchdog tick. Wrapped in the Rails executor so ActiveRecord connections are
    # checked out and returned correctly for this background thread -- without it the
    # thread leases a connection out of the web's 5-slot pool and never gives it back --
    # and rescue-all so nothing a tick can throw ever kills the supervising thread. The
    # watchdog already rescues its own read failures; this is the belt to that braces.
    def check_once(watchdog)
      Rails.application.executor.wrap do
        watchdog.check!
      end
    rescue => e
      # .error, not .warn: a supervisor whose every tick raises is a watchdog that is
      # not watching, which is the condition this whole class exists to make loud.
      Rails.logger.error(
        "[QueueLivenessSupervisor] Watchdog tick raised (thread continues): #{e.class}: #{e.message}"
      )
    end
  end
end
