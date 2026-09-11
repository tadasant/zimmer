# frozen_string_literal: true

# Start the out-of-band queue-liveness watchdog (tadasant/zimmer#427).
#
# Every other health-and-recovery check in Zimmer runs as a GoodJob job on the queue it
# watches, so a queue that executes nothing at all silences all of them at once. This
# watchdog runs on a thread inside the WEB (Puma) process instead -- a separate process,
# in a separate container, from the worker -- so it keeps checking even when the queue
# is dead. See QueueLivenessWatchdog for the full rationale.
#
# The gate lives in QueueLivenessSupervisor.should_start? rather than inline here, so it
# can be tested from a process that is none of the things it asks about, and so
# `system_health` can report the same predicate beside `running?`. In short: the web
# server process only, in the alerting environments only, unless the escape hatch is set.
#
# BOTH the gate call and the start MUST stay inside `after_initialize`. Rails runs
# config/initializers/*.rb from `:load_config_initializers`, which is BEFORE
# `:setup_main_autoloader`, so an `app/` constant referenced from an initializer body
# raises `NameError: uninitialized constant` every time -- that is what #1121 shipped,
# and it broke every production deploy. `QueueLivenessSupervisor` is an `app/` constant.
# See config/alerting_environments.rb's header for the full account.
Rails.application.config.after_initialize do
  QueueLivenessSupervisor.start! if QueueLivenessSupervisor.should_start?
end
