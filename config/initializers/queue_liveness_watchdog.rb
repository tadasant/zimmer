# frozen_string_literal: true

# Start the out-of-band queue-liveness watchdog (tadasant/zimmer#427).
#
# Every other health-and-recovery check in Zimmer runs as a GoodJob job on the queue it
# watches, so a queue that executes nothing at all silences all of them at once. This
# watchdog runs on a thread inside the WEB (Puma) process instead -- a separate process,
# in a separate container, from the worker -- so it keeps checking even when the queue
# is dead. See QueueLivenessWatchdog for the full rationale.
#
# Started ONLY in the web server process. `Rails::Server` is defined under
# `bin/rails server` (the web container's CMD) but not under `good_job start` (worker),
# rake, console, runner, or an agent session -- the same gate the deleted
# PeriodicCatalogRefresher used, proven in production. The worker already runs
# SystemHealthMonitorJob on its cron, and the worker is the failure domain this exists
# to escape, so a watchdog thread there would add nothing.
#
# Scoped to the alerting environments (production, staging): those are the only ones
# with the obs pipeline this pages through, and the only ones where web and worker are
# genuinely separate processes. In development GoodJob runs `:async` inside Puma, so the
# web IS the worker and the out-of-band property does not exist; test drives the
# watchdog directly. QUEUE_LIVENESS_WATCHDOG_DISABLED=true is an escape hatch.
if defined?(Rails::Server) &&
   AlertingEnvironments::ALL.include?(Rails.env.to_s) &&
   ENV["QUEUE_LIVENESS_WATCHDOG_DISABLED"] != "true"
  Rails.application.config.after_initialize do
    QueueLivenessSupervisor.start!
  end
end
