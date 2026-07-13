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

  # GoodJob's Notifier holds one LISTEN connection, which it checks out and then
  # *removes* from the pool (good_job/lib/good_job/notifier.rb). It is a real backend
  # on the server that no pool size accounts for, so the server-side budget has to add
  # it back by hand.
  GOOD_JOB_NOTIFIER_CONNECTIONS = 1

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

    Integer(ENV.fetch("RAILS_MAX_THREADS", 3))
  end

  # The GoodJob scheduler threads, one per queue. Each one can be executing a job, and
  # each executing job holds a primary connection for its whole duration.
  def good_job_queue_threads
    {
      agents: Integer(ENV.fetch("GOOD_JOB_AGENTS_THREADS", 16)),
      pollers: Integer(ENV.fetch("GOOD_JOB_POLLERS_THREADS", 3)),
      triggers: Integer(ENV.fetch("GOOD_JOB_TRIGGERS_THREADS", 2)),
      default: Integer(ENV.fetch("GOOD_JOB_DEFAULT_THREADS", 4))
    }
  end

  # The `agents:16;pollers:3;...` string GoodJob wants.
  def good_job_queues
    good_job_queue_threads.map { |queue, threads| "#{queue}:#{threads}" }.join(";")
  end

  def good_job_scheduler_threads
    good_job_queue_threads.values.sum
  end

  # A per-scheduler fallback GoodJob only uses for queues with no explicit count. Every
  # Zimmer queue has one, so this is belt-and-braces -- but it is pinned to the real
  # total so it can never authorize more threads than the pool can serve.
  def good_job_max_threads
    Integer(ENV.fetch("GOOD_JOB_MAX_THREADS") { good_job_scheduler_threads })
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
    Integer(ENV.fetch("DB_POOL") { puma_threads + good_job_threads + pool_overhead })
  end

  # solid_cable leases per query and gives the connection straight back, so this covers
  # concurrent in-flight broadcasts (plus the web process's polling listener), not the
  # thread count. A burst of 25 simultaneous broadcasts queues on a 3-wide pool for the
  # milliseconds each INSERT takes, nowhere near the 5s checkout timeout.
  def cable_pool
    Integer(ENV.fetch("CABLE_DB_POOL", 3))
  end

  # --- Server-side budget -----------------------------------------------------
  #
  # The pool methods above answer "how many connections may *this* process hold", which
  # is all database.yml can ask -- a process cannot size a pool for a role it is not.
  # The budget below answers the other question, the one nobody was asking on
  # 2026-07-13: how many connections does the whole deployment commit to, and can the
  # server actually serve them? It has to reason about both roles at once, so it works
  # from the config rather than from this process's shape.

  # Connections a single `web` process (Puma, no job threads) costs the server.
  def web_connections
    Integer(ENV.fetch("RAILS_MAX_THREADS", 3)) + PROCESS_OVERHEAD + cable_pool
  end

  # Connections a single `worker` process (`good_job start`) costs the server: its
  # primary pool, its cable pool, and the Notifier's LISTEN connection, which lives
  # outside every pool.
  def worker_connections
    good_job_scheduler_threads + GOOD_JOB_UTILITY_THREADS + PROCESS_OVERHEAD +
      cable_pool + GOOD_JOB_NOTIFIER_CONNECTIONS
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
