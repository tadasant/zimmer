# Bounds how many `default` threads may sit inside a blocking one-shot inference
# call at once.
#
# **The shape of the problem.** A headless inference call shells out to the
# runtime CLI and blocks its worker thread until the answer lands or the timeout
# expires — 15s for a push-notification blurb, 30s for a title, 90s for a status
# summary. Every job class that makes one runs on `default`, which has four
# threads (ConnectionBudget::GOOD_JOB_DEFAULT_THREADS) and carries three dozen
# other job classes: heartbeat sweeps, cleanup, token bookkeeping. So blocking
# inference and everything else on the queue compete for the same four threads,
# and nothing but this bounds the split.
#
# **Why a shared key rather than one per class.** The resource being rationed is
# `default`'s thread count, and the classes contend for it as one pool. A
# per-class limit of two would let two classes take all four threads and starve
# the queue completely, which is the state this exists to prevent.
#
# **Why this binds hardest during an account-quota outage.** An outage is when
# inference is least likely to answer and most likely to burn its whole timeout,
# and it is simultaneously when the most work is enqueued: every parked session
# takes a `pause` transition, and `pause` enqueues BOTH a status-summary refresh
# and a push notification, each of which makes its own blocking call. So arrival
# peaks exactly when service is worst. Left unbounded, the queue's whole capacity
# goes to calls that cannot succeed while the sweeps behind them age.
#
# **What the bound does to the surplus.** GoodJob answers an exceeded
# `perform_limit` with ConcurrencyExceededError and re-schedules the job, so the
# surplus waits in `scheduled` — future-dated, not ready — instead of holding a
# thread. Summaries, titles and notification blurbs land late during an outage,
# which is the correct trade: they are best-effort, and StatusSummaryBackstopJob
# repairs a generation that never landed.
module BlockingInferenceBounded
  extend ActiveSupport::Concern

  # Shared across every including class — see "Why a shared key" above.
  CONCURRENCY_KEY = "blocking_inference"

  # Half of `default`'s threads, so the other half is always available to the
  # rest of the queue. Derived rather than written as `2`, because the thread
  # count is an ENV knob (GOOD_JOB_DEFAULT_THREADS) and a literal would let a
  # production override erase the guarantee while the suite stayed green.
  PERFORM_LIMIT = [ ConnectionBudget.good_job_queue_threads[:default] / 2, 1 ].max

  # Longest a job may wait between attempts after losing the race for a slot.
  #
  # GoodJob's own handler for ConcurrencyExceededError backs off polynomially and
  # uncapped (`(attempt ** 4) + 2` seconds), which reaches ~10 minutes by the
  # fifth attempt and over an hour by the eighth. That curve suits a job
  # contending with itself; it is wrong for a slot that frees every time an
  # inference call returns. A session whose summary lost the race three times
  # would still be waiting an hour after the queue drained, and an operator's
  # forced Regenerate — a button press, with a human watching the panel — would
  # wear the same delay.
  MAX_RETRY_INTERVAL = 60.seconds

  # The quadratic ramp, jittered, capped. ActiveJob applies its configured
  # `retry_jitter` to the `:polynomially_longer` and Duration forms but NOT to a
  # Proc (ActiveJob::Exceptions#determine_delay), so a Proc that does not jitter
  # itself silently loses it. Without jitter every job that bounced off the same
  # slot retries on the identical offsets and they arrive as a herd, each taking
  # `pg_advisory_xact_lock` on this one key — during exactly the outage this
  # exists for.
  def self.retry_interval(executions)
    base = [ executions**2, MAX_RETRY_INTERVAL.to_i ].min
    (base + (Kernel.rand * base * ActiveJob::Base.retry_jitter)).seconds
  end

  included do
    # `perform_limit` only, deliberately — NOT `enqueue_limit` or `total_limit`.
    # These jobs carry a session id and are not interchangeable, so refusing an
    # enqueue would drop a specific session's work rather than delay it. The
    # limit belongs at perform, where the thread is actually held.
    good_job_control_concurrency_with(
      key: -> { CONCURRENCY_KEY },
      perform_limit: PERFORM_LIMIT
    )

    # Registered AFTER the handler GoodJob installs on ApplicationJob, so it wins:
    # ActiveSupport resolves rescue handlers last-registered-wins, the same
    # mechanism ApplicationJob.discard_interrupt_quietly documents. Attempts stay
    # unbounded — the work should still happen, just not on a held thread — and
    # never reaching `retry_stopped` also keeps this off the ERROR line that
    # ActiveJob::LogSubscriber emits there, which is a Grafana page.
    #
    # This also catches ThrottleExceededError, which subclasses it. Inert today,
    # since nothing here configures a throttle — but a throttle period longer
    # than MAX_RETRY_INTERVAL would be defeated by this cap and needs its own
    # handler registered after this one.
    retry_on(
      GoodJob::ActiveJobExtensions::Concurrency::ConcurrencyExceededError,
      attempts: Float::INFINITY,
      wait: ->(executions) { BlockingInferenceBounded.retry_interval(executions) }
    )
  end
end
