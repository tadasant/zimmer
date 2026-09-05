# frozen_string_literal: true

# The single source of truth for how many PostgreSQL connections Zimmer commits to,
# and therefore how many the database has to be able to serve.
#
# WHY THIS FILE EXISTS
# --------------------
# Zimmer runs two Rails processes (the Kamal `web` and `worker` roles) against two
# databases (`primary` and `cable`), which is four ActiveRecord pools -- and a managed
# Postgres cluster hands out a hard, small number of connection slots. A pool is a
# promise the database has to be able to keep, and ActiveRecord pools are lazy, so an
# overcommitted app looks healthy right up until real traffic asks for the connections
# it was promised and Postgres answers "remaining connection slots are reserved for
# roles with the SUPERUSER attribute" (a 500, not a queue).
#
# The four pools have four different right answers, so they are derived here rather
# than guessed, and no single flat number may be substituted for them:
#
#   web primary     Puma request threads. Small: RAILS_MAX_THREADS is 3.
#   worker primary  One connection per *executing* GoodJob job, held for the whole
#                   job. GoodJob leases it stickily on purpose -- its advisory locks
#                   are session-scoped and "must outlive this query"
#                   (good_job/app/models/concerns/good_job/advisory_lockable.rb) --
#                   and Zimmer's agent jobs run for hours. So this pool, alone among
#                   the four, must cover every scheduler thread.
#   cable (both)    solid_cable writes take NO advisory lock, so Rails 8.1 leases a
#                   connection per query and returns it immediately. A broadcast from
#                   an hours-long agent job holds a cable connection for the
#                   millisecond the INSERT takes, not for the job. This pool only has
#                   to cover concurrent in-flight broadcasts.
#
# Loaded from config/database.yml, so it must stay plain Ruby with no Rails
# dependencies. config/application.rb requires it.
module ConnectionBudget
  module_function

  # GoodJob runs internal utility threads (GoodJob::SharedExecutor::MAX_THREADS) on
  # top of its schedulers, and they issue queries like any other thread. Mirrored
  # rather than referenced because this file is loaded before the gem is.
  GOOD_JOB_UTILITY_THREADS = 2

  # GoodJob's Notifier checks a LISTEN connection out and then *removes* it from the pool
  # (good_job/lib/good_job/notifier.rb), so it is a real backend on the server that NO
  # pool size accounts for and the budget has to add back by hand.
  #
  # Three of them, not one. Measured on the staging worker -- three concurrent backends
  # with `application_name = 'GoodJob::Notifier'`, all from the worker container's IP,
  # stable, idle on their keepalive `SELECT 1`. The web process runs none, which is
  # `:external` mode doing what it says. Guessing 1 here would have quietly under-budgeted
  # the server by 2 per worker, which is the same kind of error this file exists to end.
  GOOD_JOB_NOTIFIER_CONNECTIONS = 3

  # Kamal's cutover deliberately runs the old and new containers together until the
  # new one passes its health check -- measured at ~17s on 2026-07-13 -- so every
  # process's connections exist twice for that window.
  DEPLOY_CUTOVER_MULTIPLIER = 2

  # Backends that belong to no pool: `bin/rails db:prepare` in the image entrypoint,
  # a `kamal app exec` console, an operator's psql.
  OPERATOR_RESERVE = 5

  # --- Process shape ----------------------------------------------------------

  # GoodJob's execution mode, which decides *which* process runs job threads.
  # `:external` (staging, production) means the web process runs none of them and a
  # dedicated `good_job start` process runs all of them; `:async` (development) runs
  # them inside the web process, so there the two budgets stack.
  # config/environments/*.rb read this so the mode and the pool sized for it cannot
  # drift apart.
  EXECUTION_MODES = {
    "development" => :async,
    "test" => :inline,
    "staging" => :external,
    "production" => :external
  }.freeze

  # database.yml is the one file that must never raise: a process that cannot render it
  # cannot boot at all. An env var set to EMPTY is a routine accident -- Kamal's
  # `env: clear:` renders `<%= ENV["X"] %>` to "" whenever X is unset on the deploy
  # runner -- and `Integer("")` raises, so blank means absent.
  #
  # A value that is present but not a positive integer is a different thing: a config
  # error, not an accident. That fails loudly, naming the variable, rather than booting
  # on a number nobody chose. Base 10 is explicit because `Integer("010")` is otherwise
  # 8, and a zero-padded thread count silently shrinking the pool is exactly the class of
  # surprise this file exists to end.
  def int_env(key, default)
    raw = ENV[key]
    return default if raw.nil? || raw.strip.empty?

    value = begin
      Integer(raw.strip, 10)
    rescue ArgumentError
      raise ArgumentError, "#{key}=#{raw.inspect} is not an integer"
    end
    raise ArgumentError, "#{key}=#{raw.inspect} must be a positive integer" unless value.positive?

    value
  end

  def rails_env
    ENV["RAILS_ENV"] || ENV["RACK_ENV"] || "development"
  end

  def execution_mode
    EXECUTION_MODES.fetch(rails_env, :external)
  end

  # True when this process is `bundle exec good_job start` -- the Kamal `worker` role.
  # Detected from the program name rather than a role env var so that it is also right
  # for a local worker, a `kamal app exec`, and any future destination, none of which
  # would have remembered to set the var.
  def good_job_worker?
    File.basename($PROGRAM_NAME, ".*") == "good_job"
  end

  # --- Threads ----------------------------------------------------------------

  def puma_threads
    return 0 if good_job_worker?

    int_env("RAILS_MAX_THREADS", 3)
  end

  # The GoodJob scheduler threads, one per queue. Each one can be executing a job, and
  # each executing job holds a primary connection for its whole duration.
  #
  # `auth` is small on purpose, and it is the one lane whose size is a policy
  # decision rather than a throughput one. RuntimeLoginJob holds its thread for as
  # long as the login CLI is open -- up to RuntimeLoginJob::MAX_DURATION, twelve
  # minutes -- so these threads are concurrent *interactive logins*, not jobs per
  # second. InferenceController#login supersedes an account's previous attempt before
  # enqueuing a new one, so a human re-authenticating six accounts one after
  # another needs one thread, not six; two covers a second browser tab and leaves
  # the budget below room to breathe. Raise GOOD_JOB_AUTH_THREADS and
  # app_required_backends in infra/terraform/main.tf moves with it.
  def good_job_queue_threads
    {
      # THE BINDING CONSTRAINT ON THIS NUMBER IS MEMORY, NOT CONNECTIONS.
      #
      # Every other queue here is sized by what its jobs do. This one is sized
      # by what the worker's cgroup can hold, because an `agents` thread runs an
      # agent session and an agent session is the largest thing on the box.
      #
      # The 10 GiB `memory.max` on the worker role (config/deploy.production.yml)
      # is the ceiling, and the sessions run UNDERNEATH it: cgroup v2 is
      # hierarchical, so the per-session cgroups SessionMemoryCgroup creates at
      # /sys/fs/cgroup/zimmer.sessions/sessions/session-<id> are DESCENDANTS of
      # the container's cgroup and every byte they charge is charged to the
      # 10 GiB too. ZIMMER_SESSION_MEMORY_MAX_MB bounds ONE runaway session, and
      # ZIMMER_SESSIONS_MEMORY_MAX_MB bounds the pool they all sit in -- but
      # NEITHER gives the sessions a separate budget. Do not read either as
      # headroom: the pool's cap is carved OUT of the 10 GiB, not added to it.
      #
      # Measured on production over the 24h to 2026-09-05T14:16Z, at this value
      # of 8 (VictoriaMetrics, `role="worker"`), strongest evidence first:
      #
      #   memory.stat     anon peak 9.07 GiB against a 10 GiB memory.max;
      #                   p95 5.68 GiB. Anonymous memory is unreclaimable, so
      #                   this is the number that decides whether N fits.
      #   memory.events   `oom_kill` 5. Per-container maxima -- the counter
      #                   resets when a deploy recreates the container, and the
      #                   window spans ~23 of them, so the true total is higher.
      #   memory.current  peak 10,737,324,032 B against a memory.max of
      #                   10,737,418,240 B, 94 KB short. Weaker than it looks:
      #                   memory.current includes reclaimable page cache (`file`
      #                   peaked at 7.28 GB), and a cgroup doing heavy file I/O
      #                   fills toward its limit with cache as a matter of
      #                   course. Corroboration, not proof.
      #   memory.events   `max` (allocation stalled into reclaim) 133,791. Same
      #                   caveat: cache-driven reclaim fires this too.
      #
      # So EIGHT already reaches the ceiling. tadasant/zimmer#981 is the incident
      # for it: on 2026-09-05T09:20:24Z eight in-budget sessions -- no runaway,
      # largest process 943 MB -- summed to 8.7 GB of anon and the kernel
      # OOM-killed the GoodJob worker itself, taking every in-flight
      # AgentSessionJob with it.
      #
      # WHAT #981 CHANGED, AND WHAT IT DID NOT. Session cgroups now live in a
      # `sessions` POOL carrying its own memory.max (ZIMMER_SESSIONS_MEMORY_MAX_MB,
      # 6144), and the pool does NOT contain the Rails worker -- so a pile-up now
      # declares its OOM in a cgroup the worker is outside of, and the victim is a
      # session process rather than the worker that runs all of them. That is a
      # blast-radius bound, not a demand reduction: the pile-up still happens and a
      # session still dies. The per-session PARALLEL_WORKERS cap (2) cuts the
      # dominant term, but it is a mitigation and not a bound either.
      #
      # So THIS number is still the admission control, and the measurements above
      # are still the reason it is 8. They also predate the fix, which is the next
      # thing to do rather than a reason to move the number now: re-measure `anon`
      # under the pool and the parallelism cap before raising this.
      #
      # And the connection budget is not roomy either: 15 derives 97
      # required_backends, which is the ENTIRE capacity of a db-s-2vcpu-4gb
      # cluster (97), so that side has zero margin and the production cluster's
      # plan slug has not been confirmed. Check `terraform output
      # managed_db_usable_backends` before relying on it.
      #
      # Eight is not a number that has been shown to fit. It is the number that
      # has been measured, and the measurement says it is at the edge: excess
      # sessions stay durable queued rows, which resume, rather than becoming a
      # worker kill, which does not. A higher number here buys no throughput,
      # because it trades queued rows for the loss of the sessions already
      # running.
      #
      # To go above 8: re-measure the peak above under #981's fix, raise this, and
      # move infra/terraform/main.tf's app_required_backends with it
      # (test/config/connection_budget_test.rb fails the build otherwise).
      agents: int_env("GOOD_JOB_AGENTS_THREADS", 8),
      pollers: int_env("GOOD_JOB_POLLERS_THREADS", 3),
      triggers: int_env("GOOD_JOB_TRIGGERS_THREADS", 2),
      auth: int_env("GOOD_JOB_AUTH_THREADS", 2),
      # Blocking one-shot inference used to share `default` and reject work
      # above a GoodJob perform limit. A burst then became a retry storm: every
      # rejected job wrote another future-scheduled row and came back to fight
      # for the same advisory lock. Give the blocking work a real lane instead.
      # The two lanes still total four threads, so this changes scheduling
      # without increasing the database connection promise.
      inference: int_env("GOOD_JOB_INFERENCE_THREADS", 2),
      # Filesystem scans, package installs, transcript archiving and deploy
      # recovery can each hold a thread for minutes. Keep them off `default` so
      # ordinary callbacks and control work continue while maintenance drains.
      maintenance: int_env("GOOD_JOB_MAINTENANCE_THREADS", 2),
      default: int_env("GOOD_JOB_DEFAULT_THREADS", 2)
    }
  end

  # The `agents:8;pollers:3;...` string GoodJob wants.
  def good_job_queues
    good_job_queue_threads.map { |queue, threads| "#{queue}:#{threads}" }.join(";")
  end

  def good_job_scheduler_threads
    good_job_queue_threads.values.sum
  end

  # GoodJob's per-scheduler fallback, used only for queues with no explicit count. Every
  # Zimmer queue has one, so this is belt-and-braces -- and it is deliberately NOT an ENV
  # knob. A GOOD_JOB_MAX_THREADS override could authorize more threads than the pool it
  # does not move, which is the exact class of drift this file exists to prevent. Size
  # the queues (GOOD_JOB_AGENTS_THREADS and friends) and the pool follows.
  def good_job_max_threads
    good_job_scheduler_threads
  end

  # GoodJob threads *in this process*: all of them in the worker, all of them in
  # development (`:async` runs them inside the web process), none in the web process
  # under `:external`, none under `:inline`.
  def good_job_threads
    return 0 unless good_job_worker? || execution_mode == :async

    good_job_scheduler_threads + GOOD_JOB_UTILITY_THREADS
  end

  # --- Pools ------------------------------------------------------------------

  # The main thread, GoodJob's cron manager, and `db:prepare` at boot all issue queries
  # from outside the thread pools above.
  PROCESS_OVERHEAD = 2

  # Tests need more slack: Rails' system-test Puma runs its own thread pool inside the
  # test process. This is pool-only headroom against a local throwaway database -- it
  # deliberately does NOT feed the server-side budget below, which describes the
  # deployed web+worker pair and must be the same number everywhere it is read.
  TEST_PROCESS_OVERHEAD = 6

  def pool_overhead
    rails_env == "test" ? TEST_PROCESS_OVERHEAD : PROCESS_OVERHEAD
  end

  def primary_pool
    int_env("DB_POOL", puma_threads + good_job_threads + pool_overhead)
  end

  # solid_cable leases per query and gives the connection straight back, so this covers
  # concurrent in-flight broadcasts (plus the web process's polling listener), not the
  # thread count.
  #
  # The work behind one broadcast: an INSERT, plus -- on ~2% of them -- solid_cable's
  # autotrim, a SKIP-LOCKED delete of at most 100 rows in a transaction
  # (SolidCable::TrimJob, trim_chance / trim_batch_size). Call it a couple of
  # milliseconds. For a 3-wide pool to hit ActiveRecord's 5s checkout timeout, the worker
  # would have to sustain thousands of broadcasts a second; eight agent sessions
  # streaming transcript updates produce single or double digits.
  #
  # Worth knowing if that estimate is ever wrong: BroadcastService rescues and does not
  # re-raise (broadcast failures must not kill a job), so a saturated cable pool would
  # surface as dropped UI updates and an open circuit breaker, not as an exception.
  def cable_pool
    int_env("CABLE_DB_POOL", 3)
  end

  # --- Server-side budget -----------------------------------------------------
  #
  # The pool methods above answer "how many connections may *this* process hold", which
  # is all database.yml can ask -- a process cannot size a pool for a role it is not.
  # The budget below answers the other question, the one nobody was asking on
  # 2026-07-13: how many connections does the whole deployment commit to, and can the
  # server actually serve them? It has to reason about both roles at once, so it works
  # from the config rather than from this process's shape.

  # The primary pool each DEPLOYED role opens. These honour DB_POOL for the same reason
  # `primary_pool` does: DB_POOL is the knob an operator reaches for while connections are
  # the thing going wrong, and a budget that could not see it would keep reporting a
  # comfortable 91 while the worker quietly promised 60. The override that hides from the
  # check is worse than no override.
  #
  # Deliberately the `:external` shape (web runs Puma only, worker runs the schedulers),
  # not this process's shape: the budget describes the deployment, and development's
  # `:async` single-process mode is not a deployment.
  def deployed_web_primary_pool
    int_env("DB_POOL", int_env("RAILS_MAX_THREADS", 3) + PROCESS_OVERHEAD)
  end

  def deployed_worker_primary_pool
    int_env("DB_POOL", good_job_scheduler_threads + GOOD_JOB_UTILITY_THREADS + PROCESS_OVERHEAD)
  end

  # Connections a single `web` process costs the server. One web process is all there is:
  # config/puma.rb never calls `workers`, so Puma runs in single mode and WEB_CONCURRENCY
  # is inert. Turning on cluster mode multiplies this term, and the budget with it.
  def web_connections
    deployed_web_primary_pool + cable_pool
  end

  # Connections a single `worker` process (`good_job start`) costs the server: its primary
  # pool, its cable pool, and the Notifier's LISTEN connections, which live outside every
  # pool.
  def worker_connections
    deployed_worker_primary_pool + cable_pool + GOOD_JOB_NOTIFIER_CONNECTIONS
  end

  # What one web + one worker commit to at steady state.
  def committed_connections
    web_connections + worker_connections
  end

  # The number of client backends the database must be able to serve for a deploy of
  # this configuration to be safe. Terraform enforces it against the managed cluster's
  # plan (infra/terraform/main.tf); test/config/connection_budget_test.rb asserts the
  # two agree.
  def required_backends
    (committed_connections * DEPLOY_CUTOVER_MULTIPLIER) + OPERATOR_RESERVE
  end
end
