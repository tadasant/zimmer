# frozen_string_literal: true

require "automated_prompts"

# Service for monitoring system health and gathering diagnostic information
#
# This service provides comprehensive health checks for:
# - Process health (active/orphaned Claude CLI processes)
# - Session health (status distribution, recent failures)
# - System health (queue depth, job processing rate)
#
# Usage:
#   service = HealthMonitorService.new
#   health = service.full_health_report
#   health[:process_health][:orphaned_count]  # => 2
#   health[:session_health][:failure_rate]    # => 0.15
#
class HealthMonitorService
  include DatabaseRetry

  # Health status thresholds
  ORPHANED_PROCESS_WARNING_THRESHOLD = 1
  ORPHANED_PROCESS_CRITICAL_THRESHOLD = 5
  # Backlog thresholds are measured against **ready** work only — jobs that are due
  # now and not yet claimed by a worker. They are deliberately not measured against
  # every unfinished row in `good_jobs`, which also holds two populations that are
  # not a backlog by any definition: jobs `scheduled` for a future time (wake-up
  # triggers, scheduled polls, retry backoffs — waiting on the clock, not on a
  # worker) and jobs already `claimed` and executing right now. Counting those meant
  # a healthy instance could page purely because somebody scheduled thirty wake-ups
  # for tomorrow. See #queue_statistics.
  # How far past its retention window the oldest log row may be before
  # log_retention_health says so. Wide enough that a table a few hours past the
  # cutoff between LogRetentionJob ticks reads healthy, narrow enough that "there
  # is more than a week of history nobody is pruning" is still said out loud —
  # including while a deployment that has never had retention works through its
  # first backlog, which really is behind.
  LOG_RETENTION_OVERDUE_GRACE = 7.days

  # How far into the table the verbose half of that check looks. `logs` has no
  # index that answers "the oldest verbose row" — the level index is not ordered
  # by id within a level — so the reading is taken over a bounded pk range at the
  # head, which is where an unpruned verbose row would be.
  VERBOSE_HEAD_PROBE_ROWS = 25_000

  QUEUE_DEPTH_WARNING_THRESHOLD = 50
  QUEUE_DEPTH_CRITICAL_THRESHOLD = 100

  # A deep queue is only an incident if it is also *not moving*. Zimmer's workers
  # clear on the order of a thousand jobs an hour, so a hundred ready jobs is about
  # five minutes of work when everything is healthy — indistinguishable, by count
  # alone, from a hundred ready jobs in front of a wedged worker. The age of the
  # longest-waiting ready job is what separates "busy" from "stuck", so `critical`
  # requires both: depth over the threshold AND the head of the queue waiting longer
  # than this.
  #
  # The two conditions are ANDed rather than ORed on purpose. Age alone says nothing
  # about scale: three jobs that have sat for twenty minutes on an otherwise idle
  # instance is not something to wake anyone for, and paging on it would rebuild the
  # noise this threshold exists to remove. Depth is what makes a stall an incident.
  QUEUE_STALL_CRITICAL_AGE = 10.minutes

  # How long the WHOLE worker fleet may finish nothing at all, with work sitting
  # ready, before that is an incident rather than a quiet patch.
  #
  # Every branch below this one reads a backlog, and a backlog is a lagging
  # indicator of a worker that has stopped: it has to grow past a depth sized in
  # the hundreds before any of them fires. On 2026-08-13 the Tadasant production
  # deployment executed nothing for ten hours — zero triggers, zero polls, zero
  # sessions — and this report said `healthy` for most of that window, escalating
  # only to `warning` ("queue backlog elevated") once the pile got big enough to
  # notice. The condition that was true from minute one is the one measured here:
  # nothing has FINISHED, anywhere, while work was waiting to be picked up.
  #
  # Ten minutes, for the same reason QUEUE_STALL_CRITICAL_AGE is ten minutes: it
  # is the point at which "not moving" stops being a plausible description of a
  # healthy instance. Zimmer's own cron schedule enqueues into the fast lanes
  # every 30 seconds and every minute, so a live worker finishes something several
  # times a minute; ten minutes is more than an order of magnitude of headroom
  # over that, and comfortably longer than a Kamal deploy's worker cutover. It is
  # deliberately not one or two minutes: this is a `critical`, and a signal people
  # are meant to trust cannot fire on a slow deploy.
  EXECUTION_STALL_CRITICAL_AGE = 10.minutes

  # `HealthStatus#code` for the branch above, so SystemHealthMonitorJob can title
  # and throttle it apart from the backlog shapes — it is a different incident with
  # a different response.
  EXECUTION_STALL_CODE = "execution_stalled"

  # Per-lane overrides for the `critical` gate, for the lanes whose designed
  # head-of-line residency is nothing like `default`'s.
  #
  # The two constants above were calibrated when `default` was, in effect, the only
  # lane: a hundred ready jobs was about five minutes of work, so a head of line
  # older than ten minutes behind that depth meant something was wedged. #763 and
  # #770 then carved `inference`, `maintenance`, `agents` and `auth` out of
  # `default` and sized them for jobs that BLOCK — and a threshold describing a lane
  # that turns jobs over in milliseconds says nothing true about a lane running two
  # threads against a ninety-second LLM call.
  #
  # So the lanes that still turn over fast (`default`, `pollers`, `triggers`) are
  # absent here and keep the original numbers; only the lanes that deviate are
  # listed, each sized from its own thread count and its own jobs' durations:
  #
  #   inference    2 threads (GOOD_JOB_INFERENCE_THREADS) against SessionTitleJob
  #                (INFERENCE_TIMEOUT 30s) and SessionStatusSummaryJob
  #                (HEADLESS_TIMEOUT 90s). At the 90s ceiling that is 2 x 3600/90 =
  #                80 jobs/hour, so a hundred-deep lane is over an hour of
  #                legitimate work and a ten-minute head age cannot tell "full"
  #                from "wedged". 150 deep AND an hour at the head can.
  #   maintenance  2 threads against filesystem scans, `bundle install`, docker
  #                prune and transcript archiving — minutes each, same shape.
  #   agents       8 threads, and AgentSessionJob holds its thread for the whole
  #                life of the session. A ready AgentSessionJob waiting hours is
  #                the scheduler's admission control working as designed (see
  #                ConnectionBudget.good_job_queue_threads), not a stall.
  #   auth         2 threads, and RuntimeLoginJob holds one for as long as the
  #                login CLI is open — up to MAX_DURATION, twelve minutes. A third
  #                concurrent login legitimately waits out two of those.
  QUEUE_LANE_CRITICAL_THRESHOLDS = {
    "inference" => { depth: 150, stall_age: 60.minutes },
    "maintenance" => { depth: 100, stall_age: 60.minutes },
    "agents" => { depth: 100, stall_age: 4.hours },
    "auth" => { depth: 100, stall_age: 30.minutes }
  }.freeze

  # How many lanes have to be stalled at once before the stall is readable as a
  # statement about the WORKER rather than about a lane.
  #
  # One lane with an old head says only that that lane is not draining, and
  # QUEUE_LANE_CRITICAL_THRESHOLDS already judges that with the threshold sized for
  # it — an `agents` lane 150 deep and three hours old, with every other lane empty
  # because the worker is emptying them on sight, is admission control, and the
  # cross-lane branch must not overrule that with the fast-lane floor. Two is the
  # smallest number that makes the claim a comparison.
  WORKER_STALL_MIN_LANES = 2

  # How long a job in each lane may hold its scheduler thread before the hold is
  # evidence of a wedge rather than of work.
  #
  # This is a different measurement from QUEUE_LANE_CRITICAL_THRESHOLDS' `stall_age`,
  # and the difference is the whole point. That one ages READY work — how long the
  # head of the line has waited. This one ages CLAIMED work — how long an execution
  # has been running. A lane can produce an old head for two opposite reasons, and
  # the ready side cannot express which:
  #
  # - Its pool is full of executions that are not returning. Every thread is held,
  #   so nothing can be claimed, so the head ages. Claims exist and are old.
  # - The worker has stopped polling the lane at all. The head ages identically.
  #   Claims are absent, or fresh.
  #
  # Each ceiling is the longest a job in that lane is DESIGNED to hold a thread,
  # with headroom, read off the bounds in the code rather than guessed:
  #
  #   inference    HeadlessInferenceService::DEFAULT_TIMEOUT (30s) and
  #                SessionStatusSummaryGenerator::HEADLESS_TIMEOUT (90s).
  #   default      Ordinary callback and control work — milliseconds to seconds.
  #                The longest designed hold is PostDeployTaskJob::SLICE_BUDGET,
  #                90 seconds, after which the task returns and is resumed from
  #                its cursor on the next tick.
  #   pollers      One poll of an external API per tick.
  #   triggers     The same shape as `pollers`.
  #   maintenance  Sized from its worst designed case rather than from a typical
  #                one, which is now BundleInstallJob: an install is bounded by
  #                nothing but the network and the Gemfile, and it retries. The
  #                two clone sweeps used to be worse — OrphanCloneFilesystemCleanupJob's
  #                scheduled path removed up to BATCH_LIMIT (20) directories with
  #                no wall-clock budget, each tearing down Docker Compose bounded
  #                at DockerComposeCleanupService::COMPOSE_DOWN_TIMEOUT (120s), so
  #                40 minutes of entirely correct work, and StaleCloneCleanupJob's
  #                ORPHAN_SWEEP_LIMIT (200 recursive deletes) had no bound at all.
  #                Both now hold a thread for at most SWEEP_BUDGET_SECONDS and
  #                resume on their next tick (see SweepBudget), so the ceiling no
  #                longer has to cover them.
  #   auth         RuntimeLoginJob::MAX_DURATION is twelve minutes.
  #
  # `agents` is deliberately ABSENT, and the absence is the rule rather than an
  # omission: AgentSessionJob holds its thread for the whole life of the session,
  # which is unbounded by design, so no execution age in that lane means anything.
  # A lane with no ceiling here is never judged wedged — which is also what a queue
  # nobody has sized yet gets, the safe direction for a gate that pages.
  LANE_EXECUTION_CEILINGS = {
    "inference" => 15.minutes,
    "maintenance" => 90.minutes,
    "auth" => 30.minutes,
    "default" => 15.minutes,
    "pollers" => 15.minutes,
    "triggers" => 15.minutes
  }.freeze

  # The `code` prefix a wedged-lane status carries. Shared with
  # SystemHealthMonitorJob so the page can title itself after the incident it is
  # reporting rather than after the gate that noticed it, without either side
  # matching on prose.
  WEDGED_LANE_CODE_PREFIX = "wedged_lane"

  # How many entries `ready_backlog_breakdown` keeps from each breakdown. Enough
  # to cover every Zimmer queue and still name the job classes that matter, short
  # enough that the alert body stays readable in Slack. Whatever the limit cuts is
  # reported as a remainder entry rather than dropped.
  READY_BREAKDOWN_LIMIT = 5

  # What a row with no `job_class` (or no `queue_name`) is called in a breakdown.
  UNKNOWN_LABEL = "(unknown)"

  # How many recent errors `recent_error_logs` returns, across all of its sources.
  RECENT_ERROR_LIMIT = 20

  # The AgentProcessLiveness classifications that mean "this process was able to ask
  # about that pid" — same kernel, same PID namespace, identity resolved. The two it
  # omits, `:unknown` and `:none`, are both "cannot tell" rather than an answer.
  PROBEABLE_LIVENESS = %i[alive dead recycled].freeze
  FAILURE_RATE_WARNING_THRESHOLD = 0.1
  FAILURE_RATE_CRITICAL_THRESHOLD = 0.25

  # Display limits
  RECENT_EVENTS_DISPLAY_LIMIT = 5

  # How recently a GoodJob process must have renewed its heartbeat to count as
  # active. A capsule renews on GoodJob::Process::STALE_INTERVAL + jitter — 30 to
  # 33 seconds — and the renew is gated on holding a lock and runs on the shared
  # 2-thread executor, so it slips further under load. Anything at or below the
  # renew cadence reports a healthy worker as inactive a meaningful fraction of
  # the time. EXPIRED_INTERVAL is the interval after which GoodJob itself gives
  # up on a process, deletes the row and releases its jobs, so a worker that is
  # inactive by this measure is one GoodJob is about to reap.
  WORKER_ACTIVE_INTERVAL = GoodJob::Process::EXPIRED_INTERVAL

  # The scheduler threads each lane actually runs, from the one place that decides
  # them. A lane's pool is "full" once it holds this many executions at the same
  # time, and a full pool is the difference between a lane that is busy and a lane
  # with no thread left to claim a job with — including a deploy gate's canary.
  #
  # Keyed by string to match the queue names `good_jobs` stores, since every caller
  # here joins this against a lane read out of the database.
  def self.lane_thread_counts
    ConnectionBudget.good_job_queue_threads.transform_keys(&:to_s)
  end

  # Compact human-readable wait ("45s", "12m", "2h 5m"). Public because the Slack page
  # `SystemHealthMonitorJob` sends is the one surface where a human, not a parser,
  # reads this number — "oldest waiting 18000s" is worse there than "5h 0m".
  def self.format_wait(seconds)
    seconds = seconds.to_i
    return "#{seconds}s" if seconds < 60
    return "#{seconds / 60}m" if seconds < 3600

    "#{seconds / 3600}h #{(seconds % 3600) / 60}m"
  end

  # Two waits as a range ("1h 16m–1h 17m"), collapsing to one when they round to
  # the same thing. A wedge usually goes still all at once, so the honest range is
  # routinely "X–X" — and printing that twice reads like a bug rather than like the
  # fact it is.
  def self.format_wait_range(from_seconds, to_seconds)
    low = format_wait(from_seconds)
    high = format_wait(to_seconds)

    low == high ? low : "#{low}–#{high}"
  end

  # One breakdown as a line of "<name> <count>" pairs. Lives here rather than in
  # each caller: the Slack page and the `get_system_health` MCP tool render the
  # same data and must not drift into two spellings of it.
  #
  # Three distinct answers, because they mean different things to whoever is
  # reading: `nil` is "the query failed", an empty breakdown is "nothing is
  # waiting", and anything else is the split itself.
  def self.format_breakdown(counts)
    return "unavailable" if counts.nil?
    return "none" if counts.empty?

    counts.map { |name, count| "#{name} #{count}" }.join(", ")
  end

  # One head-of-line-age breakdown as a line of "<queue> <age>" pairs, in the
  # order it was built — oldest queue first, so the lane holding the backlog is
  # the first thing read.
  #
  # Same three answers as `format_breakdown`, and for the same reason: `nil` is
  # "the query failed", empty is "nothing is waiting", anything else is the split.
  def self.format_ages(ages)
    return "unavailable" if ages.nil?
    return "none" if ages.empty?

    ages.map { |queue, seconds| "#{queue} #{format_wait(seconds)}" }.join(", ")
  end

  # Structured result for health status
  # `code` is optional and nil for every status that does not need one. It exists so
  # SystemHealthMonitorJob can throttle the two critical backlog shapes separately:
  # they are different incidents with different responses, and collapsing them onto
  # one dedup key means a starved-lane page silences a worker-wide stall for the
  # rest of AlertService::DEDUP_WINDOW.
  HealthStatus = Struct.new(:status, :message, :code, keyword_init: true) do
    def healthy?
      status == :healthy
    end

    def warning?
      status == :warning
    end

    def critical?
      status == :critical
    end

    # A check that could not be evaluated from here — not a claim that the thing
    # it watches is fine. It is deliberately none of the three above: an
    # unevaluated check must not colour the overall status green, and it must not
    # page anyone either. `calculate_overall_status` names it instead.
    def unknown?
      status == :unknown
    end
  end

  def initialize(process_manager: nil)
    @process_manager = process_manager || SystemProcessManager.new
    @logger = StructuredLogger.new({ service: "HealthMonitorService" })
  end

  # Generate a complete health report
  #
  # The six sections `overall_status` summarizes are computed ONCE and handed to it,
  # rather than recomputed inside it. Two reasons, and the second is the one that
  # matters. Cost: each is several queries against `sessions` and `good_jobs`, and
  # /health auto-refreshes every thirty seconds. Consistency: recomputing means the
  # summary is taken over a second, later reading of a moving system, so a report
  # could carry a `critical` section under an `All systems operational` headline —
  # a health surface disagreeing with itself is the class of defect this whole file
  # is being corrected for.
  #
  # @return [Hash] Full health report with all sections
  def full_health_report
    process = process_health
    session = session_health
    system = system_health
    egress = egress_health
    auth = auth_health
    post_deploy = post_deploy_task_health

    {
      process_health: process,
      session_health: session,
      system_health: system,
      egress_health: egress,
      auth_health: auth,
      retry_budget_health: retry_budget_health,
      sigterm_retry_health: sigterm_retry_health,
      api_error_retry_health: api_error_retry_health,
      post_deploy_task_health: post_deploy,
      # Absent from the status list below on purpose — see #log_retention_health
      # for why a draining backlog must not turn the whole report yellow.
      log_retention_health: log_retention_health,
      overall_status: calculate_overall_status(
        [ process, session, system, egress, auth, post_deploy ].map { |section| section[:status] }
      ),
      generated_at: Time.current
    }
  end

  # Get process health information
  #
  # Every count here is taken from THIS operating-system process, and two of them
  # structurally cannot see an agent process in production:
  #
  #   `tracked_count` reads `@process_manager.tracked_processes`, and a
  #   SystemProcessManager's ProcessRegistry is a plain in-memory Hash owned by the
  #   manager instance. `#initialize` builds a fresh one for every health report, so
  #   it holds the processes THIS report spawned — which is none, always.
  #
  #   `active_count` is a `pgrep` of the current user's processes, which sees only
  #   the current container. ConnectionBudget puts GoodJob in `:external` mode in
  #   production, so agent CLIs are children of the *worker* container while this
  #   report is served from *web*.
  #
  # `orphaned_count` is derived from `active_count`, so it inherits both. That is
  # how this section reported `0/0/0` and "No orphaned processes" beside five live
  # sessions on 2026-08-13 (zimmer#428): a counter that cannot observe the
  # processes it counts can never report one, and its zero is "not knowable from
  # here", not "none exist". Only the second of those justifies `healthy`.
  #
  # `recorded_count` is the fact that IS durable and cross-container — sessions
  # carrying an agent process in their metadata, written by whoever spawned it —
  # and it is what tells the two zeros apart.
  #
  # @return [Hash] Process health data
  def process_health
    active_processes = find_active_claude_processes
    orphaned_processes = find_orphaned_processes(active_processes)
    tracked_processes = @process_manager.tracked_processes
    recorded_processes = recorded_agent_processes
    observable = orphan_detection_observable?(active_processes, tracked_processes, recorded_processes)

    {
      active_count: active_processes.size,
      active_processes: active_processes,
      orphaned_count: orphaned_processes.size,
      orphaned_processes: orphaned_processes,
      tracked_count: tracked_processes.size,
      tracked_processes: tracked_processes.values,
      # Sessions the database says have a live agent process, whoever spawned it.
      recorded_count: recorded_processes.size,
      recorded_processes: recorded_processes,
      # Whether the three counts above are evidence about anything.
      observable: observable,
      status: process_health_status(
        orphaned_processes.size,
        observable: observable,
        recorded_count: recorded_processes.size
      )
    }
  end

  # Get session health information
  # @return [Hash] Session health data
  def session_health
    sessions_by_status = Session.group(:status).count
    # Eager load logs to avoid N+1 queries when categorizing failures
    recent_failures = Session.where(status: :failed)
                             .where("updated_at > ?", 24.hours.ago)
                             .includes(:logs)
                             .order(updated_at: :desc)
                             .limit(10)

    total_sessions = sessions_by_status.values.sum
    failed_count = sessions_by_status["failed"] || 0
    failure_rate = total_sessions.positive? ? failed_count.to_f / total_sessions : 0.0

    error_categories = categorize_failures(recent_failures)
    failure_reasons = failure_reason_distribution
    avg_duration = calculate_average_session_duration

    {
      sessions_by_status: sessions_by_status,
      total_sessions: total_sessions,
      recent_failures: recent_failures.map { |s| session_summary(s) },
      failure_rate: failure_rate.round(3),
      error_categories: error_categories,
      failure_reasons: failure_reasons,
      average_duration_seconds: avg_duration,
      status: session_health_status(failure_rate)
    }
  end

  # Every retry budget, as one uniform section.
  #
  # Built by enumerating RetryBudget.all rather than by naming metadata keys in SQL,
  # so a budget appears here because it was declared. Before this existed the health
  # surface covered the two budgets somebody had remembered to wire (SIGTERM and API
  # error) and read as complete, while every other budget was invisible to /health, to
  # get_system_health and to SystemHealthMonitorJob — so "why did this session stop"
  # could not be answered from any health surface for most of the ways it can happen.
  #
  # The two sections below stay: they carry rate-limit and quota detail this generic
  # one has no equivalent of, and the /health page renders them as their own panels.
  # They read their numbers from the same #retry_budget_stats, so there is one query
  # per fact rather than one per surface.
  #
  # @return [Hash] one entry per declared budget, keyed by the budget's name
  def retry_budget_health
    {
      budgets: RetryBudget.all.map { |budget| retry_budget_stats(budget) }
    }
  end

  # Get SIGTERM retry health information
  # Tracks sessions that have experienced SIGTERM exits and their retry behavior
  # @return [Hash] SIGTERM retry health data
  # Which one-time post-deploy tasks have run, which are pending, and which
  # failed — the answer to that question on a surface a human can reach without a
  # shell on the box, which is the whole point of the mechanism (AGENTS.md, "No
  # production box access").
  #
  # Folded into the health report rather than given its own endpoint so that the
  # /health page, GET /api/v1/health and the `get_system_health` MCP tool all
  # read the same object and cannot drift.
  #
  # Rescued rather than raised: a broken task file — a duplicate version, a class
  # that is not a PostDeployTask — must not take down the whole health report,
  # which is the thing an operator reaches for when something is wrong. The
  # degraded reading says so in its own message.
  def post_deploy_task_health
    PostDeployTaskRun.summary
  rescue StandardError => e
    @logger.warn("Post-deploy task health could not be read", error: e.message)
    {
      status: HealthStatus.new(status: :warning, message: "Post-deploy task status could not be read: #{e.message}"),
      total: 0, pending: 0, running: 0, succeeded: 0, failed: 0, blocked: 0,
      awaiting_first_tick: 0, tasks: []
    }
  end

  # How big `logs` is, and whether LogRetentionJob is keeping up.
  #
  # This exists because the size of that table was, until now, unmeasurable
  # without a shell on the database host — and on production there is no such
  # shell: Postgres is DigitalOcean Managed, the SSH server is withheld from the
  # catalog baked onto the droplet, and managed-cluster storage is not scraped
  # into VictoriaMetrics (tadasant/zimmer#181). tadasant/zimmer#437 was filed with
  # production's exposure unknown for exactly that reason. Carried here, it
  # reaches /health, `GET /api/v1/health` and `get_system_health` at once.
  #
  # The size readings are O(1): `reltuples` and the relation sizes come from the
  # catalog, so nothing here scans the table it is reporting on. The two age
  # readings walk the leftmost end of `logs_pkey` — the first live entry, and the
  # first verbose one within VERBOSE_HEAD_PROBE_ROWS of it — which is cheap except
  # immediately after a large batch delete has left dead entries there for
  # autovacuum. That is bounded, not free, which is why the probe is bounded too.
  #
  # `oldest_log_at` is the lowest-id row's timestamp rather than a true
  # `MIN(created_at)`, which without a `created_at` index would be a sequential
  # scan of the table this panel exists to say is too big. It reads the same under
  # the ordering LogRetentionJob assumes, and it inherits the same blind spot: a
  # recent row with a low id makes this look younger than the table really is.
  #
  # Deliberately NOT folded into `overall_status`. The first deployment to run
  # retention really is behind for as long as its initial drain takes, and this
  # panel says so — but `overall_status` is what SystemHealthMonitorJob and the
  # alerting read, and turning the whole report yellow for a day while a backlog
  # drains exactly on schedule is how people learn to ignore it.
  def log_retention_health
    stats = ActiveRecord::Base.connection.select_one(<<~SQL.squish) || {}
      SELECT c.reltuples::bigint AS estimated_rows,
             pg_total_relation_size(c.oid) AS total_bytes,
             pg_indexes_size(c.oid) AS index_bytes
      FROM pg_class c
      JOIN pg_namespace n ON n.oid = c.relnamespace
      WHERE c.relname = 'logs' AND n.nspname = current_schema()
    SQL

    oldest = Log.order(:id).limit(1).pick(:created_at)
    oldest_verbose = oldest_verbose_log_at

    {
      # `reltuples` is -1 on a table Postgres has never analyzed (PG14+), which is
      # not "no rows" — report it as unknown rather than as zero.
      estimated_rows: estimated_rows(stats["estimated_rows"]),
      total_bytes: stats["total_bytes"].to_i,
      index_bytes: stats["index_bytes"].to_i,
      oldest_log_at: oldest,
      oldest_verbose_log_at: oldest_verbose,
      retention_days: (Log::RETENTION / 1.day).to_i,
      verbose_retention_days: (Log::VERBOSE_RETENTION / 1.day).to_i,
      status: log_retention_status(oldest, oldest_verbose)
    }
  rescue StandardError => e
    @logger.warn("Log retention health could not be read", error: e.message)
    {
      estimated_rows: nil, total_bytes: 0, index_bytes: 0,
      oldest_log_at: nil, oldest_verbose_log_at: nil,
      retention_days: (Log::RETENTION / 1.day).to_i,
      verbose_retention_days: (Log::VERBOSE_RETENTION / 1.day).to_i,
      status: HealthStatus.new(status: :warning, message: "Log retention status could not be read: #{e.message}")
    }
  end

  # The oldest verbose row within the first VERBOSE_HEAD_PROBE_ROWS rows by id.
  #
  # Checked separately because verbose rows are the bulk of the table and have the
  # tighter window: a verbose pass that had stopped while the general one kept
  # running would refill a disk, and `oldest_log_at` alone would read healthy
  # throughout — every surviving row would be inside the 90-day window.
  def oldest_verbose_log_at
    head = Log.order(:id).offset(VERBOSE_HEAD_PROBE_ROWS).limit(1).pick(:id)
    scope = Log.where(level: Log::VERBOSE_LEVEL)
    scope = scope.where(id: ..head) if head

    scope.order(:id).limit(1).pick(:created_at)
  end

  def estimated_rows(reltuples)
    return nil if reltuples.nil?

    count = reltuples.to_i
    count.negative? ? nil : count
  end

  def log_retention_status(oldest, oldest_verbose)
    return HealthStatus.new(status: :healthy, message: "No log rows") if oldest.nil?

    age_days = ((Time.current - oldest) / 1.day).round
    overdue = overdue_window(oldest, Log::RETENTION) || overdue_window(oldest_verbose, Log::VERBOSE_RETENTION)

    if overdue
      HealthStatus.new(
        status: :warning,
        message: "Oldest #{overdue[:label]}log row is #{overdue[:age_days]} days old, past the " \
                 "#{overdue[:window_days]}-day retention window — LogRetentionJob is behind, or still " \
                 "draining a pre-retention backlog"
      )
    else
      HealthStatus.new(status: :healthy, message: "Oldest log row is #{age_days} days old")
    end
  end

  # The same grace for both windows: a reading is only "overdue" once there is more
  # than a week of history past the window nobody has pruned.
  def overdue_window(oldest, window)
    return nil if oldest.nil? || oldest >= (window + LOG_RETENTION_OVERDUE_GRACE).ago

    {
      label: window == Log::VERBOSE_RETENTION ? "verbose " : "",
      age_days: ((Time.current - oldest) / 1.day).round,
      window_days: (window / 1.day).to_i
    }
  end

  def sigterm_retry_health
    rate_limit_tracker = GlobalRateLimitTracker.new
    stats = retry_budget_stats(RetryBudget::SIGTERM)

    {
      total_sigterm_sessions: stats[:total_sessions],
      total_retries_attempted: stats[:total_retries_attempted],
      successful_recovery_count: stats[:successful_recovery_count],
      exhausted_retry_count: stats[:exhausted_retry_count],
      recent_sigterm_count: stats[:recent_count],
      rate_limit_pressure: rate_limit_tracker.under_pressure?,
      rate_limit_events_5min: rate_limit_tracker.recent_event_count,
      current_delay_mode: rate_limit_tracker.under_pressure? ? "escalated" : "normal",
      max_retries: stats[:max_retries],
      recent_sigterm_sessions: stats[:recent_sessions].map do |summary|
        summary.except(:last_attempt_at).merge(last_sigterm_at: summary[:last_attempt_at])
      end
    }
  end

  # Get API error retry health information
  # Tracks sessions that have experienced API errors (server errors + rate limits)
  # and their retry behavior. Shares the same GlobalRateLimitTracker as SIGTERM retries.
  # @return [Hash] API error retry health data
  def api_error_retry_health
    rate_limit_tracker = GlobalRateLimitTracker.new
    stats = retry_budget_stats(RetryBudget::API_ERROR)
    threshold = 24.hours.ago

    # Count sessions that hit account quota limits (daily/weekly limits, not transient 429s)
    quota_limit_sessions_count = Session
      .where("metadata->>'last_quota_limit_at' IS NOT NULL")
      .count

    recent_quota_limit_count = Session
      .where("metadata->>'last_quota_limit_at' IS NOT NULL")
      .where("(metadata->>'last_quota_limit_at')::timestamp > ?", threshold)
      .count

    {
      total_api_error_sessions: stats[:total_sessions],
      total_retries_attempted: stats[:total_retries_attempted],
      successful_recovery_count: stats[:successful_recovery_count],
      exhausted_retry_count: stats[:exhausted_retry_count],
      recent_api_error_count: stats[:recent_count],
      quota_limit_sessions_count: quota_limit_sessions_count,
      recent_quota_limit_count: recent_quota_limit_count,
      rate_limit_pressure: rate_limit_tracker.under_pressure?,
      rate_limit_events_5min: rate_limit_tracker.recent_event_count,
      current_delay_mode: rate_limit_tracker.under_pressure? ? "escalated" : "normal",
      max_retries: stats[:max_retries],
      recent_api_error_sessions: stats[:recent_sessions].map do |summary|
        summary.except(:last_attempt_at).merge(last_api_error_at: summary[:last_attempt_at])
      end
    }
  end

  # Get system health information
  # @return [Hash] System health data
  def system_health
    queue_stats = queue_statistics
    worker_stats = worker_statistics
    recent_errors = recent_error_logs

    {
      # Ready work, not every unfinished row — the number an operator means when they
      # ask "how deep is the queue?". `queue_stats` still carries the full breakdown.
      queue_depth: queue_stats[:ready_count],
      queue_stats: queue_stats,
      worker_stats: worker_stats,
      recent_errors: recent_errors,
      database_status: database_health_status,
      status: system_health_status(queue_stats, active_workers: worker_stats[:active_workers])
    }
  end

  # Network-egress (DNS) health, read from the shared cache EgressHealthCheckJob
  # writes. Surfaces the same condition the global "network egress degraded"
  # banner shows, so the dashboard the banner links to actually corroborates it
  # instead of staying silent about the outage.
  # @return [Hash] Egress health data
  def egress_health
    cached = EgressHealthCheck.status
    degraded = cached && cached["status"] == "degraded"

    {
      status:
        if degraded
          HealthStatus.new(status: :critical, message: cached["detail"].presence || "Network egress degraded")
        else
          HealthStatus.new(status: :healthy, message: "DNS egress resolving")
        end,
      resolver: cached&.dig("resolver"),
      detail: cached&.dig("detail"),
      degraded_since: cached&.dig("degraded_since"),
      checked_at: cached&.dig("checked_at")
    }
  end

  # Agent-runtime authentication health: is the worker's shared Claude
  # credentials file usable, and does the pool have an account that can serve a
  # session?
  #
  # A corrupt credentials file used to be invisible here. It logged 126 WARN
  # lines an hour and appeared on no surface at all, so the 2026-08-22 outage was
  # found by a human reading session transcripts three hours in. Corruption is
  # critical because it logs out every session on the worker at once; an empty
  # pool is a warning because sessions park and resume rather than failing.
  # See https://github.com/tadasant/zimmer/issues/618, hole 5.
  #
  # @return [Hash] Auth health data
  def auth_health
    @auth_health ||= build_auth_health
  end

  # Memoised because #full_health_report reads it once for the payload and again
  # through #calculate_overall_status, and unlike the other sections this one
  # touches the filesystem — two reads could also disagree mid-repair and render
  # a card whose badge contradicts its detail.
  def build_auth_health
    credentials = ClaudeCredentialHealth.status
    # Two numbers, because they answer two different questions and the gap
    # between them is itself the diagnostic.
    #
    # `available` is the `status` column: what a session can be spawned on right
    # now, since every path that picks an account reads that column. `serviceable`
    # is ClaudeAccount.serviceable_for — the same predicate
    # AuthRecoveryCoordinator#park_reason_for_pool decides a park on, which looks
    # past a label the account's own newer reading contradicts.
    #
    # Reporting only the column is how this card said "3 Claude accounts
    # available" seven minutes after the parking decision had concluded the pool
    # was empty. Reporting only the evidence would be the mirror image: a healthy
    # card over a pool nothing can spawn against. Reported together, a pool that
    # is recovering-but-not-yet-restored says so.
    available = ClaudeAccount.available.for_runtime(ClaudeAuthProvider::RUNTIME).count
    serviceable = ClaudeAccount.serviceable_for(ClaudeAuthProvider::RUNTIME).count
    needs_reauth = ClaudeAccount.for_runtime(ClaudeAuthProvider::RUNTIME).needs_reauth.count

    status =
      if credentials.corrupt?
        HealthStatus.new(status: :critical, message: credentials.detail)
      elsif serviceable.zero?
        HealthStatus.new(status: :warning, message: "No Claude account is available to serve sessions")
      elsif available.zero?
        HealthStatus.new(status: :warning,
          message: "No Claude account is active yet — #{serviceable} labelled quota_exceeded over a " \
            "clear reading, and the reset checker restores them within 15 minutes")
      else
        HealthStatus.new(status: :healthy, message: "#{available} Claude account#{"s" unless available == 1} available")
      end

    {
      status: status,
      # Which store the card is describing. Under session-scoped credentials the
      # answer to "can a session authenticate" is a DB row, not a file on the
      # worker, and a card that still said "Worker credentials file" would be
      # pointing at something no session reads.
      session_scoped_credentials: AppSetting.session_scoped_credentials_enabled?,
      credentials_state: credentials.state,
      credentials_detail: credentials.detail,
      credentials_owner: credentials.owner_email,
      # What the self-heal path would do about it right now. Only asked when the
      # file is actually corrupt, because it is the one state that has a repair —
      # and the operator needs the REASON a repair is declined, not a promise
      # that one is coming. See issue #618, hole 5.
      repair_outlook: credentials.corrupt? ? repair_outlook : nil,
      available_accounts: available,
      serviceable_accounts: serviceable,
      needs_reauth_accounts: needs_reauth,
      checked_at: credentials.checked_at
    }
  rescue => e
    {
      status: HealthStatus.new(status: :warning, message: "Auth health could not be read: #{e.message}"),
      session_scoped_credentials: false,
      credentials_state: :unknown,
      credentials_detail: e.message,
      credentials_owner: nil,
      repair_outlook: nil,
      available_accounts: nil,
      serviceable_accounts: nil,
      needs_reauth_accounts: nil,
      checked_at: Time.current
    }
  end

  # A read-only dry run of the credential repair: the same decision
  # ClaudeCredentialHealth.self_heal! is about to make on the next sweep, minus
  # the write. `:healed` means the sweep will fix it; anything else carries the
  # reason it will not, which is the part an operator has to act on.
  def repair_outlook
    outcome, detail = ClaudeCredentialHealth.self_heal!(dry_run: true)
    { outcome: outcome, detail: detail }
  end

  # Clean up orphaned processes
  # @return [Hash] Results of cleanup operation
  def cleanup_orphaned_processes
    orphaned = find_orphaned_processes(find_active_claude_processes)
    results = { terminated: [], failed: [], already_dead: [] }

    orphaned.each do |process_info|
      termination_service = ProcessTerminationService.new(
        process_pid: process_info[:pid],
        process_manager: @process_manager
      )
      result = termination_service.terminate

      if result.success?
        if result.status == :already_dead
          results[:already_dead] << process_info[:pid]
        else
          results[:terminated] << process_info[:pid]
        end
      else
        results[:failed] << { pid: process_info[:pid], reason: result.message }
      end

      @logger.info("Process cleanup attempted", pid: process_info[:pid], result: result.status)
    end

    results
  end

  # Retry failed sessions
  # @param session_ids [Array<Integer>] Optional list of session IDs to retry
  # @return [Hash] Results of retry operation
  def retry_failed_sessions(session_ids: nil)
    sessions = if session_ids.present?
      # Operator is targeting specific sessions by id — honor that intent even if
      # one happens to sit in a frozen category.
      Session.where(id: session_ids, status: :failed)
    else
      # Bulk "retry all recent failures" is a recover-all flow, so exclude sessions
      # parked in a frozen category (same contract as refresh_all and the recovery jobs).
      # Qualify updated_at: not_in_frozen_category LEFT JOINs categories, which also
      # has an updated_at column, so an unqualified reference would be ambiguous.
      Session.not_in_frozen_category.where(status: :failed).where("sessions.updated_at > ?", 24.hours.ago).limit(10)
    end

    results = { retried: [], failed: [], skipped: [] }

    sessions.each do |session|
      if can_retry_session?(session)
        begin
          # The enqueue happens under the row lock claim_system_recovery_turn! takes.
          # The relation is read once, above, and the loop then works from those
          # objects: every session past the first waits out a `Dir.exist?` stat on
          # the clone volume and a full resume-and-enqueue for each session ahead of
          # it, so the row can say `archived` by the time this iteration reaches it.
          # Resuming from the loaded object would write `running` straight over the
          # trash (#554). `with_db_retry` re-running the block after a connection
          # blip is the same hazard from a second direction: the retry replays the
          # decision against a row that has moved. See
          # Session#claim_system_recovery_turn!.
          outcome = nil
          with_db_retry do
            ActiveRecord::Base.transaction do
              outcome = session.claim_system_recovery_turn! do
                # Clear stale retry metadata for fresh execution.
                # See Session::STALE_RETRY_METADATA_KEYS for the full list of keys cleared.
                session.remove_metadata!(Session::STALE_RETRY_METADATA_KEYS)
              end

              next unless outcome == :claimed

              AgentSessionJob.enqueue_with_prompt(session.id, AutomatedPrompts::SYSTEM_RECOVERY)
            end
          end

          if outcome == :claimed
            results[:retried] << session.id
            @logger.info("Session retry initiated", session_id: session.id)
          else
            results[:skipped] << { session_id: session.id, reason: refuse_retry(session, outcome) }
          end
        rescue => e
          results[:failed] << { session_id: session.id, reason: e.message }
          @logger.error("Session retry failed", session_id: session.id, error: e.message)
        end
      else
        results[:skipped] << { session_id: session.id, reason: "Missing required metadata" }
      end
    end

    results
  end

  # Archive old sessions
  # @param older_than [ActiveSupport::Duration] Age threshold (default: 7 days)
  # @return [Hash] Results of archive operation
  def archive_old_sessions(older_than: 7.days)
    sessions = Session.where.not(status: :archived)
                      .where("updated_at < ?", older_than.ago)

    results = { archived: [], failed: [] }

    # The sweep archives without consulting Sessions::ArchiveGuard, so every
    # queue it strands pages — correctly, since nobody read those messages. What
    # is not correct is one page per session: the stranded-queue alert dedups per
    # session by design, so a sweep that catches N sessions with queues posts N
    # alerts in one tick, and each of those spawns its own triage session. The
    # batch keeps the count honest inside a single consolidated message.
    AlertBatcher.with_batch do
      sessions.find_each do |session|
        begin
          with_db_retry do
            session.archive_actor = "Zimmer's stale-session sweep (untouched for #{older_than.inspect})"
            session.archive! if session.may_archive?
          end
          results[:archived] << session.id
        rescue => e
          results[:failed] << { session_id: session.id, reason: e.message }
        end
      end
    end

    @logger.info("Old sessions archived", count: results[:archived].size)
    results
  end

  # The backlog split by queue and by job class, and — the part the thresholds
  # actually fire on — the age of each queue's own head of line.
  #
  # `queue_statistics` answers "how deep", which is what the thresholds need. It
  # does not answer "deep with WHAT", and that is the question every triage of a
  # backlog page actually opens with: a ready count alone cannot distinguish a
  # starved queue from a busy one, and Zimmer runs seven queues with very
  # different thread counts and job durations.
  #
  # `oldest_by_queue` exists because `queue_statistics[:oldest_ready_age_seconds]`
  # is a single number over every queue at once. A global head-of-line age
  # stopped being interpretable the moment the lanes were sized apart: two threads
  # against jobs that block for a minute and a half hold their head of line for
  # tens of minutes while the worker is healthy and the depth is flat, and that
  # reads identically to a wedged worker if the only number you have is the
  # maximum across all of them. Per-queue ages separate the two on sight — one old
  # lane beside six fresh ones is that lane starving; every lane old at once is the
  # worker. `system_health_status` now thresholds on that distinction rather than
  # only printing it. The Grafana rule over `zimmer_good_job_oldest_ready_age_seconds`
  # still reads the single global number, but no longer pages on it alone —
  # tadasant-internal#2260 gated it on throughput as well, for the same reason.
  #
  # `oldest_by_queue` is the one breakdown here that is NOT capped. The counts can
  # be, because `top_counts` hands back an `other (N more)` remainder and the
  # reader can still see the total. An age has no such remainder — "other 12m"
  # means nothing — so a cap would leave a lane's absence meaning three different
  # things at once: no ready work there, or cut by the cap. That ambiguity lands
  # squarely on the comparison the line exists for, and the entry count is bounded
  # by the number of distinct queue names anyway.
  #
  # `queue_statistics` carries its own uncapped per-lane depths and head ages,
  # because the `critical` gate cannot evaluate a per-lane conjunction without them.
  # What stays here, and stays off the /health render, is the by-job-class breakdown
  # and the capping: those answer "deep with what" for a human reading a page, not
  # "is this an incident". Cardinality is small either way — seven queues, and job
  # classes bounded by the app's job count.
  #
  # @param limit [Integer] how many entries to keep from each COUNT breakdown
  # @return [Hash] :by_queue and :by_job_class, ordered Hashes of name => count;
  #   :oldest_by_queue, an uncapped ordered Hash of queue => age in seconds,
  #   oldest first; :head_of_line, the longest-waiting ready row, or nil when
  #   nothing is waiting
  def ready_backlog_breakdown(limit: READY_BREAKDOWN_LIMIT)
    ready = ready_scope(GoodJob::Job.where(finished_at: nil, locked_by_id: nil))
    heads = head_of_line_by_queue(ready)

    {
      by_queue: top_counts(ready.group(:queue_name).count, limit),
      by_job_class: top_counts(ready.group(:job_class).count, limit),
      oldest_by_queue: lane_head_ages(heads),
      head_of_line: heads.first
    }
  end

  private

  # Find all active Claude CLI processes on the system
  # Security: Only finds processes owned by the current user
  def find_active_claude_processes
    processes = []

    begin
      # Use pgrep to find Claude CLI processes owned by current user
      # -u restricts to current user's processes for security
      require "open3"
      output, _status = Open3.capture2("pgrep", "-fl", "-u", Process.uid.to_s, "claude")

      output.each_line do |line|
        parts = line.strip.split(/\s+/, 2)
        next if parts.size < 2

        pid = parts[0].to_i
        command = parts[1]

        # Skip if this is our own process
        next if pid == Process.pid
        # Only match processes that look like the actual Claude CLI
        next unless command.match?(/\bclaude\b/)

        processes << {
          pid: pid,
          command: command,
          running: @process_manager.running?(pid)
        }
      end
    rescue => e
      @logger.error("Failed to find active processes", error: e.message)
    end

    processes
  end

  # Find orphaned processes (running but no matching session)
  def find_orphaned_processes(active_processes)
    # Get all running sessions with their process PIDs
    running_sessions = Session.where(status: [ :running, :waiting ])
    session_pids = running_sessions.filter_map { |s| s.metadata&.dig("process_pid")&.to_i }

    # Find processes not associated with any session
    active_processes.select do |process|
      process[:running] && !session_pids.include?(process[:pid])
    end
  end

  # The agent processes the DATABASE knows about — the one record of them that
  # outlives the container that spawned them, and the only one a report served from
  # `web` can read at all.
  #
  # `Session#record_agent_process!` writes `process_pid` and `process_identity` in
  # one statement, so a session with a pid always carries the boot id, PID namespace
  # and start time that make that pid meaningful somewhere. AgentProcessLiveness
  # classifies it: `:alive` / `:dead` / `:recycled` mean this process is in the same
  # kernel and namespace and can therefore answer, `:unknown` means it is not and
  # cannot.
  #
  # Scoped to `running` alone, and that is narrower than it looks. `process_pid` is
  # a single metadata slot that is not cleared when a turn ends, so every parked
  # `waiting` session still names the pid of a process that exited hours ago.
  # Counting those would hold this report at `unknown` for ever on an instance with
  # no agent process anywhere on it — a permanent caveat, which reads as noise and
  # gets ignored exactly like the false `healthy` it replaced. A session in
  # `running` is mid-turn by definition, so its recorded pid should name something
  # alive.
  #
  # Classified from the metadata already loaded rather than through
  # `AgentProcessLiveness.status`, which re-reads each session's metadata to see a
  # write made by another process. That freshness matters on the spawn path it was
  # written for; here it would be one extra SELECT per running session on every
  # /health render, to sharpen a number nobody acts on.
  def recorded_agent_processes
    Session.where(status: :running)
           .where("metadata->>'process_pid' IS NOT NULL")
           .pluck(:id, :metadata)
           .filter_map do |id, metadata|
      pid = metadata&.dig("process_pid")
      next if pid.blank?

      {
        session_id: id,
        pid: pid.to_i,
        liveness: AgentProcessLiveness.classify(metadata[AgentProcessLiveness::IDENTITY_KEY])
      }
    end
  rescue StandardError => e
    @logger.error("Failed to read recorded agent processes", error: e.message)
    []
  end

  # Whether the orphan counts above are evidence about anything.
  #
  # True when there is nothing to see (no session claims an agent process, so "none
  # orphaned" is a true statement about an empty world), or when something WAS seen
  # — a live claude process in this container, a tracked spawn, or a recorded
  # process whose identity resolves in this kernel and namespace and can therefore
  # be probed. False is the production case this exists to name: sessions hold
  # recorded processes, and every one of them was spawned somewhere this report
  # cannot look.
  #
  # PROBEABLE_LIVENESS is a whitelist rather than "anything but `:unknown`", because
  # `AgentProcessLiveness.classify` also answers `:none` — no identity was recorded
  # at all — which is exactly as unobservable as `:unknown` and must not be read as
  # evidence that this process looked and found nothing.
  def orphan_detection_observable?(active_processes, tracked_processes, recorded_processes)
    return true if recorded_processes.empty?
    return true if active_processes.any? || tracked_processes.any?

    recorded_processes.any? { |process| PROBEABLE_LIVENESS.include?(process[:liveness]) }
  end

  # Calculate queue statistics using GoodJob
  #
  # `pending_count` is every unfinished row and is reported for continuity, but it is
  # not the backlog: it sums three populations with different meanings. `ready_count`
  # is the one that means "work waiting on a worker", and it is what the thresholds
  # and the alert read.
  def queue_statistics
    # GoodJob stores jobs in good_jobs table
    pending_jobs = GoodJob::Job.where(finished_at: nil)
    unclaimed_jobs = pending_jobs.where(locked_by_id: nil)
    ready_jobs = ready_scope(unclaimed_jobs)
    # Unclaimed, so the three populations partition `pending_count` exactly rather
    # than counting a locked future-dated row as both claimed and scheduled.
    scheduled_jobs = unclaimed_jobs.where("scheduled_at > ?", Time.current)
    running_jobs = pending_jobs.where.not(locked_by_id: nil)
    failed_jobs = GoodJob::Job.where.not(error: nil).where(finished_at: nil)

    # Calculate processing rate (jobs completed in last hour)
    completed_last_hour = GoodJob::Job.where("finished_at > ?", 1.hour.ago).count

    # When anything last finished, anywhere. A rate is an average over a window and
    # says nothing about *when* inside it: six jobs an hour reads the same whether
    # they were spread evenly or all six landed in the first minute and nothing has
    # run since. This is the instant, and it is what `execution_stall` reads.
    #
    # Both conditions of the partial index `index_good_jobs_jobs_on_finished_at`
    # are spelled out so Postgres can serve this from a backward index scan rather
    # than aggregating the whole retained history on every /health render.
    # Excluding superseded retry rows can only move the answer backwards in time by
    # the rare case where the newest finish was one of them, which is the direction
    # that reports a stall we are not in rather than hiding one we are.
    last_finished_at = GoodJob::Job.finished.where(retried_good_job_id: nil).maximum(:finished_at)

    # One read, two answers. `system_health_status` needs each lane's depth AND each
    # lane's head-of-line age to evaluate its conjunction within a lane, and taking
    # them from separate queries against a moving table would let it threshold one
    # lane's depth against another lane's age. Uncapped, unlike the alert body's
    # breakdown: a lane the cap cut would read as having no depth at all, and the
    # gate would stop seeing the very queue that is starving.
    #
    # This costs the /health render one query net: the `DISTINCT ON` head read and
    # the grouped count, less the single-row `pick` the global age no longer needs.
    # That is a real reversal of `ready_backlog_breakdown`'s decision to keep these
    # scans off the render path, and it is the price of a gate that can tell a
    # starved lane from a stalled worker — the conjunction cannot be evaluated per
    # lane without per-lane numbers. Both reads are bounded by the number of
    # distinct queue names rather than by backlog depth, and both are served by the
    # partial `(queue_name, scheduled_at)` index.
    heads = head_of_line_by_queue(ready_jobs)

    # The same read taken over the claimed population. `claimed_count` is a single
    # integer over every lane, and the two shapes a stalled lane can have are
    # indistinguishable in it: a lane holding a full pool of executions that never
    # return, and a lane the worker is not polling. On 2026-09-04 the production
    # worker held that number at 15 for an hour while `inference`, `default` and
    # `maintenance` picked up nothing — and neither the page nor the deploy gate
    # could say which of the two it was, the gate reporting in as many words that
    # the lane "could not be shown to be draining any other work OR to be holding
    # a full pool of live work". These keys are what settle it.
    #
    # Both ends of each lane's in-flight population, because one of them is not
    # enough to say a pool is stuck: the oldest execution alone is satisfied by a
    # single hung thread beside others turning work over normally. The gate needs
    # the youngest too — "even the most recently started job in this lane is past
    # what the lane's work takes" is the claim that means no thread is free.
    #
    # Bounded by the claimed population rather than by the backlog: at most one
    # row per lane per read, over the rows a worker is executing right now — 21 of
    # them at Zimmer's configured thread counts. The partial `(locked_by_id)`
    # index serves the filter; Postgres sorts the handful of rows that survive it.
    in_flight = in_flight_head_by_queue(running_jobs)
    youngest_in_flight = in_flight_head_by_queue(running_jobs, direction: :youngest)

    {
      pending_count: pending_jobs.count,
      ready_count: ready_jobs.count,
      scheduled_count: scheduled_jobs.count,
      claimed_count: running_jobs.count,
      failed_count: failed_jobs.count,
      # Named for the collector that scrapes them off /health/export_diagnostics
      # (#778): the same units as the flat keys above, per lane. A queue with
      # nothing ready is ABSENT from both rather than present as a zero, matching
      # the `oldest_ready_age_seconds: nil` convention — an idle lane and a
      # draining one are different facts and a metric that flattens them to 0 says
      # the wrong one.
      ready_count_by_queue: lane_counts(ready_jobs),
      oldest_ready_age_seconds_by_queue: lane_head_ages(heads),
      # The claimed side of the same three facts, under the same conventions: a
      # lane holding nothing is absent rather than zero, and the totals above are
      # the sum of these.
      claimed_count_by_queue: lane_counts(running_jobs),
      oldest_claimed_age_seconds_by_queue: lane_head_ages(in_flight),
      # The other end: how long the most recently started execution in each lane
      # has been running. Reported rather than kept private to the gate, because a
      # responder reading "oldest 1h 17m, youngest 1h 16m" learns something a
      # single number cannot say — that the whole pool went still at once.
      youngest_claimed_age_seconds_by_queue: lane_head_ages(youngest_in_flight),
      # What is holding the oldest thread in each lane. The numeric hashes say a
      # pool is stuck; this says what to go and look at, and it is the only part
      # of the answer a responder with no shell on the box and no route to /jobs
      # cannot reconstruct for themselves.
      oldest_claimed_job_class_by_queue: lane_head_job_classes(in_flight),
      # The global head of line is the oldest of the per-lane heads by definition —
      # the oldest ready row anywhere is the head of its own lane — so it comes from
      # the same read rather than a query of its own, and the two can no longer
      # disagree about a row that drained between them.
      oldest_ready_age_seconds: heads.first&.fetch(:age_seconds),
      # The longest-running execution anywhere, derived from the per-lane heads for
      # the same reason the ready-side global is: one read, so the two can never
      # disagree about a job that finished between them.
      oldest_claimed_age_seconds: in_flight.first&.fetch(:age_seconds),
      processing_rate_per_hour: completed_last_hour,
      # `nil` means no job has EVER finished on this deployment — a fresh database,
      # not a stalled one. `execution_stall` reads it as "no baseline" and stands
      # down, because "has never processed anything" and "has stopped processing"
      # are different facts and only the second one is an incident.
      last_finished_at: last_finished_at,
      seconds_since_last_finished: last_finished_at ? [ (Time.current - last_finished_at).round, 0 ].max : nil
    }
  end

  # Rows per lane, biggest first, uncapped, with the same UNKNOWN_LABEL treatment
  # `head_of_line_by_queue` gives a row GoodJob wrote with no queue name — so a lane
  # appears under one key in every half and the gate can join them.
  #
  # Takes whichever population the caller is counting: ready depth from the ready
  # scope, in-flight width from the claimed scope. The two are the same query over
  # different rows, and writing it twice is how they drift into two spellings of a
  # lane name.
  #
  # Ordered rather than left in the adapter's grouping order, so two reads of an
  # unchanged queue serialize identically; and a plain Hash rather than the
  # accumulator's `Hash.new(0)`, so a lane holding nothing reads as absent to a
  # Ruby caller too and not as a zero the default conjured.
  def lane_counts(scope)
    counts = scope.group(:queue_name).count.each_with_object(Hash.new(0)) do |(queue, count), acc|
      acc[queue.presence || UNKNOWN_LABEL] += count
    end

    counts.sort_by { |queue, count| [ -count, queue.to_s ] }.to_h
  end

  # Head age per lane, oldest lane first. `heads` arrives sorted oldest first and
  # two raw queue names can share one label (a NULL and an empty string both render
  # as UNKNOWN_LABEL), so keeping the FIRST sighting keeps the older of them — the
  # age the gate has to see, and the one the alert body means. Writing the label
  # blind would keep the younger and quietly under-report the lane it collapsed.
  def lane_head_ages(heads)
    heads.each_with_object({}) do |head, acc|
      acc[head[:queue]] ||= head[:age_seconds]
    end
  end

  # The job class of each lane's head, under the same first-sighting rule, so the
  # class named always belongs to the row whose age is reported beside it.
  def lane_head_job_classes(heads)
    heads.each_with_object({}) do |head, acc|
      acc[head[:queue]] ||= head[:job_class]
    end
  end

  # Each queue's own longest-waiting ready row, oldest queue first.
  #
  # `DISTINCT ON (queue_name)` with the matching `ORDER BY` is what makes this one
  # row per queue rather than a scan the deepest queue can monopolize. The
  # alternative — read the N oldest ready rows and keep the first sighting of each
  # queue — is wrong in exactly the case the page most needs: a single lane holding
  # more ready rows than the window would fill it entirely, and every other lane
  # would go missing from a line whose whole job is to be compared across lanes.
  # This returns every queue's exact head, and its cost is bounded by the number of
  # distinct queue names rather than by the backlog depth. `good_jobs` has a
  # partial `(queue_name, scheduled_at)` index for it.
  #
  # Postgres-only, which the rest of this application already is (advisory locks,
  # `jsonb`, GoodJob itself). The columns come back adapter-cast because they are
  # real columns; the raw COALESCE only orders, so it never has to infer a type. A
  # `minimum(Arel.sql(...))` over the expression instead would have no column to
  # infer from, leaving the adapter to decide whether you get a Time or a String.
  #
  # `id` breaks ties so two reads of an unchanged queue name the same row.
  #
  # @return [Array<Hash>] one entry per queue: :queue, :job_class, :age_seconds
  def head_of_line_by_queue(ready_jobs)
    now = Time.current

    heads = ready_jobs
      .select(Arel.sql("DISTINCT ON (queue_name) id, queue_name, job_class, scheduled_at, created_at"))
      .order(Arel.sql("queue_name, COALESCE(scheduled_at, created_at) ASC, id ASC"))

    heads.map do |head|
      # "Waiting since" is `scheduled_at` for a job that was future-dated: it only
      # became backlog when its scheduled time arrived, and charging it for the hours
      # it spent correctly parked would make every wake-up trigger look like a stall.
      # `created_at` is NOT NULL on `good_jobs`, so the fallback always resolves and
      # there is no undateable row to guard against. "Nothing is ready" is an empty
      # result here, which is why the caller reads a nil global age off `first`.
      waiting_since = head.scheduled_at || head.created_at

      {
        queue: head.queue_name.presence || UNKNOWN_LABEL,
        job_class: head.job_class.presence || UNKNOWN_LABEL,
        age_seconds: [ (now - waiting_since).round, 0 ].max
      }
    end.sort_by { |head| -head[:age_seconds] }
  end

  # Each queue's longest-RUNNING execution, oldest queue first — the claimed-side
  # mirror of `head_of_line_by_queue`, and the read that makes a wedge legible.
  #
  # Same `DISTINCT ON (queue_name)` shape and the same reasons for it: one row per
  # lane rather than a scan one lane can monopolize, cost bounded by the number of
  # distinct queue names, `id` breaking ties so two reads of an unchanged lane name
  # the same row.
  #
  # "Running since" is `performed_at` — when the worker actually began the job —
  # falling back to `locked_at` for the instant between the claim and the start, and
  # to `created_at` for a row GoodJob left with neither. Dating from `created_at`
  # throughout would charge every execution for the time it spent queued, which is
  # the ready side's measurement and would read every busy lane as wedged.
  #
  # @param direction [Symbol] :oldest for each lane's longest-running execution,
  #   :youngest for its most recently started one. The pair is what makes "every
  #   thread in this lane is held by old work" a statement the gate can check:
  #   the oldest alone is satisfied by one stuck thread beside two healthy ones.
  # @return [Array<Hash>] one entry per queue: :queue, :job_class, :age_seconds
  def in_flight_head_by_queue(running_jobs, direction: :oldest)
    now = Time.current
    sort = direction == :oldest ? "ASC" : "DESC"

    heads = running_jobs
      .select(Arel.sql("DISTINCT ON (queue_name) id, queue_name, job_class, performed_at, locked_at, created_at"))
      .order(Arel.sql("queue_name, COALESCE(performed_at, locked_at, created_at) #{sort}, id ASC"))

    heads.map do |head|
      running_since = head.performed_at || head.locked_at || head.created_at

      {
        queue: head.queue_name.presence || UNKNOWN_LABEL,
        job_class: head.job_class.presence || UNKNOWN_LABEL,
        age_seconds: [ (now - running_since).round, 0 ].max
      }
    end.sort_by { |head| -head[:age_seconds] }
  end

  # Unclaimed work whose time has come — the population every "backlog" number
  # here is taken over. A row with no `scheduled_at` was ready the moment it was
  # created; a future-dated one is not backlog until its time arrives.
  def ready_scope(unclaimed_jobs)
    unclaimed_jobs.where("scheduled_at <= ? OR scheduled_at IS NULL", Time.current)
  end

  # Biggest first, keeping at most `limit` — plus a remainder entry for whatever
  # the limit cut, so the breakdown always adds up against `ready_count`. The
  # remainder is labelled rather than bare because every entry renders as
  # "<name> <count>": "+3 more 10" puts two numbers in different units next to
  # each other, "other (3 more) 10" does not.
  #
  # The remainder is not cosmetic. The alert asks the reader to tell "concentrated
  # in one queue" from "spread across every queue", and there are 50-odd job
  # classes against a limit of five: without it, five names and no total look the
  # same whether they are the whole backlog or a tenth of it, which is exactly the
  # distinction the reader was asked to make.
  #
  # Sorted by count and then by name so equal counts come out in a stable order
  # rather than shuffling between two readings of an unchanged queue. A nil or
  # blank key (a row GoodJob wrote with no job_class) is labelled rather than
  # dropped, and labelled by SUMMING onto any existing entry — `transform_keys`
  # alone would collapse nil and "" onto one label and silently keep only the
  # last of them.
  def top_counts(counts, limit)
    labelled = counts.each_with_object(Hash.new(0)) do |(key, count), acc|
      acc[key.presence || UNKNOWN_LABEL] += count
    end

    ranked = labelled.sort_by { |name, count| [ -count, name.to_s ] }
    kept = ranked.first(limit).to_h
    remainder = ranked.drop(limit).sum { |_name, count| count }

    remainder.zero? ? kept : kept.merge("other (#{ranked.size - limit} more)" => remainder)
  end

  # Calculate worker statistics using GoodJob
  def worker_statistics
    processes = GoodJob::Process.all

    active_processes = processes.select do |p|
      p.updated_at && (Time.current - p.updated_at) < WORKER_ACTIVE_INTERVAL
    end

    {
      total_workers: processes.count,
      active_workers: active_processes.count,
      worker_details: processes.map do |p|
        {
          id: p.id,
          hostname: p.state&.dig("hostname") || "unknown",
          last_heartbeat: p.updated_at,
          seconds_since_heartbeat: p.updated_at ? (Time.current - p.updated_at).round : nil
        }
      end
    }
  end

  # Recent errors from every error stream Zimmer durably records, newest first.
  #
  # `Log belongs_to :session`, so the `logs` table can only ever hold errors that
  # happened INSIDE an agent session. Reading it alone is why this field stayed `[]`
  # through the ten hours of 2026-08-13 while the application log emitted a
  # database-connection error about 36 times a minute (zimmer#428): an empty array
  # reads as "no errors", and it was reporting the coverage of one table.
  #
  # The other stream Zimmer keeps is the job layer: `good_jobs` carries the error
  # of every job that raised, retried or was discarded, and a fault in a background
  # job is an application fault whether or not a session was attached to it. Both
  # are folded together here, each entry naming its `source`.
  #
  # KNOWN BLIND SPOT, and it is why no health STATUS is derived from this field: an
  # error that only ever reaches stdout — a connection failure inside GoodJob's own
  # poller, anything raised before a job row could be written — is recorded by
  # neither table. Zimmer has no queryable store of the Rails log; that is what the
  # observability stack is for. So `[]` here means "no error was RECORDED", never
  # "nothing is wrong", and `execution_stall` is the signal that catches the outage
  # this field cannot see.
  def recent_error_logs
    since = 1.hour.ago

    (session_error_logs(since) + job_error_records(since))
      .sort_by { |entry| entry[:created_at] }
      .reverse
      .first(RECENT_ERROR_LIMIT)
  end

  # Errors logged inside an agent session.
  def session_error_logs(since)
    Log.where(level: "error")
       .where("created_at > ?", since)
       .order(created_at: :desc)
       .limit(RECENT_ERROR_LIMIT)
       .map do |log|
      {
        id: log.id,
        source: "session_log",
        session_id: log.session_id,
        content: log.content.truncate(200),
        created_at: log.created_at
      }
    end
  end

  # Errors raised by background jobs, whether the job then retried or was discarded.
  #
  # Dated by `updated_at` rather than `created_at`: a job that sat in the queue for
  # an hour and failed a second ago is a fresh error, and `created_at` would file it
  # under when it was enqueued — or out of the window entirely.
  def job_error_records(since)
    GoodJob::Job.where.not(error: nil)
                .where("updated_at > ?", since)
                .order(updated_at: :desc)
                .limit(RECENT_ERROR_LIMIT)
                .map do |job|
      {
        id: job.id,
        source: "job",
        session_id: nil,
        content: "#{job.job_class.presence || UNKNOWN_LABEL} (#{job.queue_name.presence || UNKNOWN_LABEL}): " \
                 "#{job.error}".truncate(200),
        created_at: job.updated_at
      }
    end
  rescue StandardError => e
    @logger.error("Failed to read recent job errors", error: e.message)
    []
  end

  # Check database health
  def database_health_status
    begin
      ActiveRecord::Base.connection.execute("SELECT 1")
      {
        connected: true,
        pool_size: ActiveRecord::Base.connection_pool.size,
        connections_in_use: ActiveRecord::Base.connection_pool.connections.count(&:in_use?)
      }
    rescue => e
      {
        connected: false,
        error: e.message
      }
    end
  end

  # Categorize failures by error type
  # Uses regex for robust matching and works with eager-loaded logs
  def categorize_failures(failures)
    categories = Hash.new(0)

    failures.each do |session|
      # Use Ruby's select/max_by to work with eager-loaded logs
      error_logs = session.logs.select { |l| l.level == "error" }
      last_error = error_logs.max_by(&:created_at)

      category = if last_error.nil?
        "unknown"
      elsif last_error.content.match?(/\btimeout\b/i)
        "timeout"
      elsif last_error.content.match?(/\bpermission\b/i)
        "permission"
      elsif last_error.content.match?(/\bconnection\b/i)
        "connection"
      elsif last_error.content.match?(/\bAPI\b|rate.?limit/i)
        "api_error"
      else
        "other"
      end

      categories[category] += 1
    end

    categories
  end

  # Get failure reason distribution from session metadata (last 24 hours)
  # This uses the structured failure_reason field set by AgentSessionJob
  # for more accurate failure categorization than log parsing
  # @return [Hash] Distribution of failure reasons with counts
  def failure_reason_distribution
    failed_sessions = Session.where(status: :failed)
                             .where("updated_at > ?", 24.hours.ago)

    reasons = Hash.new(0)
    failed_sessions.find_each do |session|
      reason = session.metadata&.dig("failure_reason") || "unknown"
      reasons[reason] += 1
    end

    # Sort by count descending for display
    reasons.sort_by { |_k, v| -v }.to_h
  end

  # Calculate average session duration for completed sessions
  #
  # Computes the average in the database via AVG(EXTRACT(EPOCH ...)) rather than
  # materializing every matching sessions.* row into Ruby. Over a 7-day window
  # under concurrent write load the row-loading version blocked >5s and tripped
  # the database-instrumentation .error threshold (see issue pulsemcp/pulsemcp#4357).
  #
  # @return [Integer, nil] Average duration in seconds, or nil when there are no
  #   matching sessions (AVG over an empty set is NULL, so `.pick` returns nil).
  #
  # The average is cast to numeric before ROUND so it rounds half away from zero,
  # matching the prior Ruby `Float#round` exactly (Postgres ROUND on a double uses
  # banker's rounding, which would differ by 1s on a half-second average).
  def calculate_average_session_duration
    Session.where(status: [ :archived, :needs_input ])
           .where("updated_at > ?", 7.days.ago)
           .pick(Arel.sql("ROUND(AVG(EXTRACT(EPOCH FROM (updated_at - created_at)))::numeric)"))
           &.to_i
  end

  # Create a summary of a session for display
  # Works with eager-loaded logs to avoid N+1 queries
  def session_summary(session)
    # Use Ruby's select/max_by to work with eager-loaded logs
    error_logs = session.logs.select { |l| l.level == "error" }
    last_error = error_logs.max_by(&:created_at)

    {
      id: session.id,
      slug: session.slug,
      title: session.title,
      status: session.status,
      git_root: session.git_root,
      updated_at: session.updated_at,
      last_error: last_error&.content&.truncate(100),
      failure_reason: session.metadata&.dig("failure_reason")
    }
  end

  # One budget's numbers, from the budget's own declared metadata keys.
  #
  # The counts are SQL aggregates so no session is loaded to be counted; the recency
  # split is done in Ruby because metadata is not schema-checked and one corrupt
  # timestamp must not take the health page down with it.
  #
  # @param budget [RetryBudget]
  # @param threshold [Time] how far back "recent" reaches
  # @return [Hash]
  def retry_budget_stats(budget, threshold: 24.hours.ago)
    # Memoised per service instance because `full_health_report` asks for the same
    # budget more than once: the generic section walks all seven, and the SIGTERM and
    # API-error panels each read their own again. Unmemoised that is nine passes —
    # ~36 queries plus nine unbounded loads — on a page that refreshes every 30s.
    # A HealthMonitorService is built per request, so the cache cannot go stale.
    @retry_budget_stats ||= {}
    return @retry_budget_stats[budget] if @retry_budget_stats.key?(budget)

    @retry_budget_stats[budget] = compute_retry_budget_stats(budget, threshold: threshold)
  end

  def compute_retry_budget_stats(budget, threshold:)
    total_sessions, total_retries_attempted = budget.sessions
      .pluck(
        Arel.sql("COUNT(*)"),
        Arel.sql("COALESCE(SUM((metadata->>#{Session.connection.quote(budget.key)})::int), 0)")
      ).first

    # Sessions that spent the budget and did NOT come to rest in its terminal status —
    # the recovery worked. Asked of the budget, because the terminal status differs:
    # the empty-turn restart parks rather than fails, and a `:failed` filter would count
    # every abandoned session here as a recovery.
    successful_recovery_count = budget.recovered_sessions.count

    stamped = budget.stamped_sessions.to_a
    recent = stamped.select { |session| within?(budget.last_attempt_at(session), threshold) }

    {
      name: budget.name,
      label: budget.label,
      count_key: budget.key,
      stamp_key: budget.stamp,
      max_retries: budget.max,
      total_sessions: total_sessions.to_i,
      total_retries_attempted: total_retries_attempted.to_i,
      successful_recovery_count: successful_recovery_count,
      exhausted_retry_count: budget.exhausted_sessions.count,
      recent_count: recent.size,
      recent_sessions: recent
        .sort_by { |session| budget.last_attempt_at(session) || Time.at(0) }
        .reverse
        .first(RECENT_EVENTS_DISPLAY_LIMIT)
        .map { |session| retry_budget_session_summary(session, budget) }
    }
  end

  # @return [Boolean] true when `time` is present and newer than `threshold`
  def within?(time, threshold)
    time.present? && time > threshold
  end

  # Create a summary of a session for retry-budget display
  def retry_budget_session_summary(session, budget)
    {
      id: session.id,
      slug: session.slug,
      title: session.title,
      status: session.status,
      git_root: session.git_root,
      retry_count: budget.count_for(session),
      last_attempt_at: budget.last_attempt_at(session),
      updated_at: session.updated_at
    }
  end

  # Check if a session can be retried
  def can_retry_session?(session)
    session.session_id.present? &&
      session.metadata&.dig("working_directory").present? &&
      Dir.exist?(session.metadata["working_directory"])
  end

  # Say why a retry did not happen — loudly enough that an operator who asked for
  # one by id can see the answer.
  #
  # A refused claim is a no-op, and a silent no-op is the failure mode here: the
  # `session_ids:` branch is somebody clicking Retry on a specific session, and
  # "nothing happened" with an empty result is indistinguishable from a bug. The
  # reason goes back to the caller in `results[:skipped]` — rendered by the JSON
  # of `POST /health/retry_sessions` and `POST /api/v1/health/retry_sessions`, by
  # the `action_health` MCP tool, and (since the HTML surface flashed counts and
  # dropped this list entirely) in the health dashboard's flash — and onto the
  # session's own timeline, where "why did nothing happen to this session" is
  # asked from.
  #
  # Neither refusal retries. An archived session is terminal — the trash-cleanup
  # clock on its clone is already running, and starting an agent against it is
  # exactly #554. A `running` session is being driven by somebody else, and a
  # second agent process on one session is its own defect (#400).
  #
  # @param session [Session] the session whose claim was refused; already
  #   reloaded by claim_system_recovery_turn!, so `status` is the row's
  # @param outcome [Symbol] :archived or :not_resumable
  # @return [String] the reason, for results[:skipped]
  def refuse_retry(session, outcome)
    reason =
      if outcome == :archived
        "Not retrying this session: it is in the trash. An archived session takes no turn, " \
        "so no agent was started."
      else
        "Not retrying this session: it is #{session.status} and cannot be resumed. " \
        "Something else is already driving it, so no second agent was started."
      end

    @logger.info("Session retry skipped", session_id: session.id, reason: outcome.to_s)

    begin
      create_log_with_retry(session, reason, level: "info")
    rescue => e
      # A timeline write that fails must not turn a clean refusal into a reported
      # retry failure — the operator still gets the reason in results[:skipped].
      @logger.warn("Could not record retry refusal on the session", session_id: session.id, error: e.message)
    end

    reason
  end

  # Determine process health status based on orphaned count
  #
  # "No orphaned processes" is a positive claim, and it is only true when something
  # was actually looked at. When nothing here can see the agent processes the
  # database says exist, the answer is `:unknown` — a status that is neither
  # healthy nor a page, because "I cannot tell" is not evidence of a fault and must
  # not be reported as the absence of one either.
  def process_health_status(orphaned_count, observable:, recorded_count:)
    if orphaned_count >= ORPHANED_PROCESS_CRITICAL_THRESHOLD
      HealthStatus.new(status: :critical, message: "#{orphaned_count} orphaned processes detected")
    elsif orphaned_count >= ORPHANED_PROCESS_WARNING_THRESHOLD
      HealthStatus.new(status: :warning, message: "#{orphaned_count} orphaned processes detected")
    elsif !observable
      HealthStatus.new(
        status: :unknown,
        code: "process_tracking_unobservable",
        message: "Orphan detection unavailable: #{recorded_count} session(s) have a recorded agent " \
                 "process and none of them is visible from this process. Agent processes belong to " \
                 "the container that spawned them, so a report served from another one counts zero " \
                 "of them — that is not the same as there being none."
      )
    else
      HealthStatus.new(status: :healthy, message: "No orphaned processes")
    end
  end

  # Determine session health status based on failure rate
  def session_health_status(failure_rate)
    if failure_rate >= FAILURE_RATE_CRITICAL_THRESHOLD
      HealthStatus.new(status: :critical, message: "High failure rate: #{(failure_rate * 100).round(1)}%")
    elsif failure_rate >= FAILURE_RATE_WARNING_THRESHOLD
      HealthStatus.new(status: :warning, message: "Elevated failure rate: #{(failure_rate * 100).round(1)}%")
    else
      HealthStatus.new(status: :healthy, message: "Normal failure rate")
    end
  end

  # Determine system health status from the ready backlog and how long its head has
  # been waiting. Critical still needs both — deep *and* stalled — but the two have
  # to be true of the SAME work, which is what the queue-blind version of this could
  # not express.
  #
  # The old gate ANDed a global ready count against the maximum head-of-line age
  # across every lane. With one lane that is the same thing; with seven it is not,
  # because the depth and the age can come from different queues. On 2026-09-02 the
  # Tadasant production deployment paged on exactly that: 109 ready summed from
  # `inference` 68 + `maintenance` 23 + `agents` 18 — no lane within 30 of the
  # hundred-deep threshold — beside a 57-minute head-of-line age contributed by
  # `inference` alone, while `agents` was 4 minutes fresh, the worker's heartbeat was
  # 23 seconds old and it was clearing 1079 jobs an hour. Both operands were true and
  # neither was evidence of a stall. The conjunction the constants describe, "a deep
  # queue that is not moving", was never actually evaluated.
  #
  # So it is evaluated twice, once for each thing a backlog can mean — the same two
  # readings SystemHealthMonitorJob's alert body asks the responder to tell apart:
  #
  #   A lane      One lane is past BOTH its own depth and its own stall age. Checked
  #               first, so the page names the starving lane instead of describing it
  #               in fleet-wide terms that fit it badly.
  #   The worker  Several lanes are stalled at once and their COMBINED backlog is past
  #               the original global depth, even though no one of them is past its own
  #               bar. That is the SlackTriggerPollerJob thread-starvation shape: work
  #               piling up across lanes rather than in one.
  #
  # Ahead of all of them sits `execution_stall`, which reads neither side of the
  # queue but the clock on the last COMPLETION. Every branch below it needs a
  # backlog to have grown before it can speak, and a worker that has simply
  # stopped takes hours to grow one — which is how a ten-hour total outage was
  # reported as `healthy`, and then as "queue backlog elevated". "Nothing has
  # finished anywhere, and work has been waiting" is true from the first minutes
  # and is not a statement about depth at all. See its own comment.
  #
  # Ahead of the two backlog branches sits a third that reads the CLAIMED side
  # instead, and answers the question the ready side is structurally unable to: `wedged_lane`,
  # a lane whose whole thread pool is held by executions past what its own jobs can
  # explain. Both branches above can only observe that ready work is not moving;
  # this one names why, and does it before the ready side has piled up enough depth
  # to trip either threshold. See its own comment for the four conjuncts.
  #
  # Both BACKLOG branches are strict narrowings of the queue-blind rule — every
  # per-lane depth threshold is at least QUEUE_DEPTH_CRITICAL_THRESHOLD and every
  # per-lane stall age at least QUEUE_STALL_CRITICAL_AGE, and the cross-lane branch
  # sums a SUBSET of the ready count — so between them nothing pages that did not
  # page before. (`wedged_lane` and `execution_stall` are each deliberately not
  # narrowings: they exist to fire on shapes the depth thresholds call healthy.
  # Their own comments carry the conjuncts that keep that from being noise.)
  #
  # `oldest_ready_age_seconds_by_queue` holds each lane's OLDEST ready row, and a
  # head only advances when a worker takes the job — so a lane whose head is older
  # than QUEUE_STALL_CRITICAL_AGE has picked up nothing in that window, whatever has
  # arrived behind it. The cross-lane branch is scoped to exactly those lanes and
  # sums only THEIR depth.
  #
  # Deliberately not "the freshest lane head is old", which is the same sentence with
  # the quantifier in the wrong place: it asks every lane to be stalled, so a single
  # lane that was empty a moment ago and has just been handed one job contributes a
  # ~0s head and silences the branch — including for `pollers`, which this monitor
  # itself runs on and which therefore almost always has fresh work at sample time.
  # Scoping to the stalled subset asks the question the branch means: is there enough
  # work sitting still, in enough places, to be the worker rather than a lane?
  # @param active_workers [Integer] how many GoodJob processes are currently live,
  #   which is what turns a per-process thread count into the lane's real capacity.
  #   Required rather than defaulted: a caller that guesses one worker on a
  #   deployment running two would halve every pool the wedge branch measures
  #   against, and the wrong answer would look like a working one.
  def system_health_status(queue_stats, active_workers:)
    depth = queue_stats[:ready_count].to_i

    stall = execution_stall(queue_stats, active_workers: active_workers)
    if stall
      return execution_stall_status(stall, depth: depth, active_workers: active_workers)
    end

    wedged = wedged_lane(queue_stats, active_workers)
    if wedged
      return HealthStatus.new(
        status: :critical,
        code: "#{WEDGED_LANE_CODE_PREFIX}:#{wedged[:queue]}",
        # The range, not just the oldest: every held thread is past the lane's
        # ceiling or this branch would not have fired, and saying so is what
        # separates "the pool went still" from "one job is slow".
        message: "Queue lane wedged: the #{wedged[:queue]} lane is holding #{wedged[:held]}/" \
                 "#{wedged[:threads]} threads on work that has been running " \
                 "#{format_wait_range(wedged[:youngest_age_seconds], wedged[:age_seconds])} " \
                 "(oldest: #{wedged[:job_class]}), with #{wedged[:depth]} jobs ready behind it"
      )
    end

    starved = starved_lane(queue_stats)
    if starved
      return HealthStatus.new(
        status: :critical,
        code: "backlog_lane:#{starved[:queue]}",
        message: "Queue backlog critical: the #{starved[:queue]} lane has #{starved[:depth]} jobs ready, " \
                 "oldest waiting #{format_wait(starved[:age_seconds])}"
      )
    end

    stalled = stalled_lane_backlog(queue_stats)
    if stalled
      return HealthStatus.new(
        status: :critical,
        code: "backlog_cross_lane",
        message: "Queue backlog critical: #{stalled[:depth]} jobs ready across " \
                 "#{stalled[:lanes]} stalled lanes, oldest waiting " \
                 "#{format_wait(queue_stats[:oldest_ready_age_seconds])}; " \
                 "none of them has picked up work in #{format_wait(stalled[:freshest_age_seconds])}"
      )
    end

    if depth >= QUEUE_DEPTH_WARNING_THRESHOLD
      HealthStatus.new(status: :warning, message: "Queue backlog elevated: #{depth} jobs ready")
    else
      HealthStatus.new(status: :healthy, message: "Queue processing normally")
    end
  end

  # Nothing at all is executing: no job has finished anywhere in
  # EXECUTION_STALL_CRITICAL_AGE, and something that should have moved has not.
  #
  # This is the one branch here that does not read a backlog. Every other one asks
  # how much work has piled up and how old the pile is, which is a lagging view of
  # a worker that has stopped — a total outage has to run for hours before any
  # per-lane depth threshold, sized in the hundreds, is crossed. That is exactly
  # what happened on 2026-08-13 (zimmer#428): ten hours with zero jobs executed,
  # and this report saying `healthy` for most of it and `warning — queue backlog
  # elevated` for the rest.
  #
  # Two conjuncts, and the second is a disjunction because a stopped worker has two
  # shapes that no single queue reading covers:
  #
  #   Nothing finished       Global, not per lane, and the first thing checked. A
  #                          lane whose pool is full of long work legitimately
  #                          finishes nothing for a while, and `wedged_lane` judges
  #                          that; the claim here is far stronger — every lane,
  #                          including the ones that turn jobs over in
  #                          milliseconds, has completed nothing.
  #   ...and either a fast   `stalled_fast_lanes` is the ordinary shape: work a
  #   lane has picked        worker should have taken in milliseconds has sat for
  #   nothing up             ten minutes. The age requirement is what keeps a
  #                          worker mid-restart during a deploy, or an instance
  #                          handed its first job of the hour, from reading as an
  #                          outage.
  #   ...or no worker is     The shape the queue cannot express. GoodJob runs cron
  #   alive at all           IN the worker, so when the worker container dies
  #                          nothing enqueues either: a healthy instance clears its
  #                          queue in milliseconds, so `ready_count` at the moment
  #                          of death is routinely zero and then stays zero for
  #                          ever. Waiting for a backlog that will never arrive is
  #                          how a dead fleet reads as "Queue processing normally".
  #                          Paired with "nothing finished", a zero heartbeat count
  #                          cannot be a deploy cutover — that does not stop
  #                          completions for ten minutes.
  #
  # `last_finished_at` being nil is "no job has ever finished here", which is a
  # fresh database rather than a dead worker, and is not this condition. It is also
  # what keeps a development or test instance, which registers no worker at all,
  # out of the heartbeat branch.
  #
  # @return [Hash, nil] :since_seconds, :stalled_lanes, :fleet_dark, :paused_queues
  def execution_stall(queue_stats, active_workers:)
    since = queue_stats[:seconds_since_last_finished]
    return nil if since.nil? || since < EXECUTION_STALL_CRITICAL_AGE

    stalled = stalled_fast_lanes(queue_stats)
    fleet_dark = active_workers.to_i.zero?
    return nil if stalled.empty? && !fleet_dark

    {
      since_seconds: since,
      stalled_lanes: stalled,
      fleet_dark: fleet_dark,
      paused_queues: paused_queues
    }
  end

  # The FAST lanes whose head of line has waited past the window — the ones the
  # ten-minute number was calibrated for.
  #
  # Deliberately not `oldest_ready_age_seconds`, which is the maximum across every
  # lane. QUEUE_LANE_CRITICAL_THRESHOLDS exists because Zimmer's lanes are sized
  # apart on purpose, and it records that a ready `AgentSessionJob` waiting HOURS is
  # admission control working as designed. So on any instance with a standing
  # `agents` queue the global maximum is over ten minutes continuously, the age
  # conjunct is satisfied all the time, and this gate collapses to the single
  # predicate "nothing finished in ten minutes" — which an eleven-minute migration
  # or a short database failover satisfies with nothing wrong.
  #
  # The lanes ABSENT from that table — `default`, `pollers`, `triggers`, and any new
  # queue nobody has sized — are the ones that turn jobs over in milliseconds, so a
  # ten-minute-old head on one of them is unambiguous. They are also the lanes
  # Zimmer's own cron feeds every thirty seconds.
  #
  # @return [Hash<String, Integer>] lane => head-of-line age, oldest first
  def stalled_fast_lanes(queue_stats)
    ages = queue_stats[:oldest_ready_age_seconds_by_queue] || {}

    ages.reject { |queue, _age| QUEUE_LANE_CRITICAL_THRESHOLDS.key?(queue) }
        .select { |_queue, age| age.to_i >= EXECUTION_STALL_CRITICAL_AGE }
        .sort_by { |_queue, age| -age.to_i }
        .to_h
  end

  # A stall with a queue deliberately paused underneath it is a `warning`, not a
  # page: an operator in queue recovery mode has already halted five of the seven
  # lanes on purpose, and paging them for the silence they just asked for would put
  # a lock on the escape hatch — the same reasoning that keeps recovery mode out
  # from behind HealthActionCooldown. The condition is still reported, in the same
  # words, because "nothing is executing and here is why" is what the operator
  # opening /health during a recovery actually needs to read.
  def execution_stall_status(stall, depth:, active_workers:)
    stalled = stall[:stalled_lanes]
    waiting = if stalled.any?
      "#{depth} job(s) are ready and #{stalled.keys.join(", ")} " \
      "#{stalled.one? ? "has" : "have"} picked nothing up in #{format_wait(stalled.values.first)}"
    else
      "no worker is reporting a heartbeat"
    end

    observation = "Nothing is executing: no job has finished anywhere in " \
                  "#{format_wait(stall[:since_seconds])}, and #{waiting} " \
                  "(#{active_workers} worker(s) reporting a heartbeat)"

    unexplained = stalled.keys - stall[:paused_queues]
    if stalled.any? && unexplained.empty?
      paused = stall[:paused_queues]
      HealthStatus.new(
        status: :warning,
        code: "#{EXECUTION_STALL_CODE}:paused",
        message: "#{observation}. Halted on purpose: #{paused.join(", ")} #{paused.one? ? "is" : "are"} paused."
      )
    else
      HealthStatus.new(status: :critical, code: EXECUTION_STALL_CODE, message: "#{observation}.")
    end
  end

  # What GoodJob actually has paused, including a lane an operator paused by hand.
  # Never raises: this is read on the path that reports an outage, and a health
  # surface that dies because it could not read a settings row is the failure mode
  # the whole issue is about.
  def paused_queues
    QueueRecoveryMode.paused_queues
  rescue StandardError => e
    @logger.error("Failed to read paused queues", error: e.message)
    []
  end

  # The lane whose entire thread pool is held by executions that have outlived what
  # that lane's jobs are designed to take, while ready work waits behind them.
  #
  # Checked before both backlog branches because it is a strictly more specific
  # reading of the same evidence, arrived at from the other side of the table. The
  # backlog branches see ready rows that are not being picked up and can say only
  # that; this sees the reason — the threads that would have picked them up are all
  # held, and by what. A responder who gets "the inference lane is holding 2/2
  # threads on work that has been running 1h 16m-1h 17m (oldest:
  # SessionStatusSummaryJob)" is already at the job to go and look at, where "the
  # inference lane has 57 jobs ready, oldest waiting 1h 17m" leaves them to work
  # out which of the two possible causes it was from numbers that do not carry the
  # distinction.
  #
  # It also fires EARLIER than they do, which is the point of it existing beside
  # them rather than as a retune of them. A wedge is diagnosable the moment the pool
  # is full and its executions are past what the lane's own jobs can explain —
  # before enough ready work has piled up behind it to clear a depth threshold sized
  # in the hundreds. It is the one branch here that pages on a lane the backlog
  # thresholds call healthy; the five conjuncts below are what keep that from being
  # noise.
  #
  # Five conditions, each load-bearing:
  #
  #   Ready work behind it   A full pool with an empty lane behind it is a lane
  #                          doing its job. Nothing is being starved, so there is
  #                          nothing to report.
  #   A full pool            Fewer executions than threads means the lane still has
  #                          a thread to claim with, so whatever is slow about it,
  #                          it is not wedged. The capacity is the lane's threads
  #                          times the number of LIVE workers, not the per-process
  #                          count: during a deploy cutover two workers are
  #                          registered at once, and measuring one worker's four
  #                          held threads against a two-thread pool would call a
  #                          healthy overlap a wedge. Scaling errs toward missing a
  #                          wedge for the seconds the overlap lasts, which is the
  #                          safe direction, and resolves itself when the old
  #                          process deregisters.
  #   Past its own ceiling   From LANE_EXECUTION_CEILINGS — the longest a job in
  #                          that lane is designed to hold a thread. A lane with no
  #                          ceiling (`agents`, and any queue nobody has sized) is
  #                          never judged wedged.
  #   A known thread count   A lane the running configuration does not describe has
  #                          no pool size to be full against.
  #   EVERY thread past it   Not just the oldest. One hung thread beside two healthy
  #                          ones satisfies "full pool" and "the oldest is old", and
  #                          reporting that as a wedge is untrue of the other two and
  #                          sends the responder after something that is not there.
  #
  # Longest-wedged lane first, by iterating the oldest-first execution ages rather
  # than the depths: on this branch "worst" is how long the lane has been unable to
  # start anything, not how much has piled up behind it.
  def wedged_lane(queue_stats, active_workers)
    depths = queue_stats[:ready_count_by_queue] || {}
    claims = queue_stats[:claimed_count_by_queue] || {}
    ages = queue_stats[:oldest_claimed_age_seconds_by_queue] || {}
    youngest = queue_stats[:youngest_claimed_age_seconds_by_queue] || {}
    job_classes = queue_stats[:oldest_claimed_job_class_by_queue] || {}
    threads = self.class.lane_thread_counts

    ages.each do |queue, age|
      ceiling = LANE_EXECUTION_CEILINGS[queue]
      next if ceiling.nil?
      next if age < ceiling

      # Every hash here is a separate query against a moving table, so a lane can
      # appear in one and not another. A missing operand is no evidence of a wedge.
      ready = depths[queue].to_i
      next unless ready.positive?

      # No live worker is no pool to be full against — and stale rows a dead
      # process left claimed are GoodJob's to reap, not a wedge to page on.
      pool = threads[queue].to_i * active_workers.to_i
      next unless pool.positive?

      held = claims[queue].to_i
      next unless held >= pool

      # The oldest execution being past the ceiling says ONE thread is stuck. The
      # youngest being past it too is what says they all are — without this, a lane
      # with one hung thread and the rest turning work over normally would be
      # reported as "holding 3/3 threads on work that has been running for 20m",
      # which is false of two of those three and sends the responder after a wedge
      # that is not there.
      next if youngest[queue].nil? || youngest[queue] < ceiling

      return {
        queue: queue,
        depth: ready,
        threads: pool,
        held: held,
        age_seconds: age,
        youngest_age_seconds: youngest[queue],
        job_class: job_classes[queue] || UNKNOWN_LABEL
      }
    end

    nil
  end

  # The single lane that is past both of its own thresholds, deepest first so the
  # message names the worst one when several qualify. Nil when every lane is within
  # what its thread count and its jobs' durations explain.
  def starved_lane(queue_stats)
    depths = queue_stats[:ready_count_by_queue] || {}
    ages = queue_stats[:oldest_ready_age_seconds_by_queue] || {}

    # `lane_counts` already returns deepest-first with a name tiebreak. Re-sorting
    # here would discard that stability — `sort_by` is not stable, so two lanes at
    # equal depth could swap between two reads of an unchanged queue and the page
    # would name a different lane each time.
    depths.each do |queue, count|
      # The depths and the ages are two queries against a moving table, so a lane
      # can appear in one and not the other. No age is no evidence of a stall.
      age = ages[queue]
      next if age.nil?

      thresholds = lane_critical_thresholds(queue)
      next unless count >= thresholds[:depth] && age >= thresholds[:stall_age]

      return { queue: queue, depth: count, age_seconds: age }
    end

    nil
  end

  # The backlog held by the lanes that have picked up nothing in longer than THEIR
  # OWN tolerance, when there are enough such lanes for that to mean the worker and
  # their combined depth is past the original global threshold. Nil otherwise.
  #
  # Each lane is judged against its own `stall_age`, not against the flat
  # QUEUE_STALL_CRITICAL_AGE. Selecting on the flat floor here would reintroduce the
  # very bug this gate exists to fix, one branch over: `inference` at 57m and
  # `maintenance` at 56m are both inside the envelope the threshold table calls
  # healthy, and `agents` sits past ten minutes as a matter of routine because eight
  # threads are each held for a whole session — so the 2026-09-02 firing re-fires
  # unchanged the moment `agents` reads 12m instead of the 4m it happened to show,
  # and two lanes well inside their own limits sum past the global bar. A lane's
  # depth is evidence of a stall only once that lane is past the age its own thread
  # count and job durations can explain.
  #
  # What that leaves is the shape a wedge actually has. The lanes that cross a
  # ten-minute bar quickly are the fast ones — `default`, `pollers`, `triggers`,
  # which turn jobs over in milliseconds and hold no override — so a worker that has
  # stopped picking anything up shows up here as those going stale together, while a
  # slow lane joins only once it is past its own much longer tolerance. That is the
  # discrimination the whole gate is for, applied consistently to both branches.
  #
  # The depth summed is the STALLED lanes' own, not `ready_count`: a lane that is
  # draining is not part of the backlog this branch is describing, and counting it
  # would put us back to ANDing one lane's depth against another lane's age.
  #
  # A stall confined to a single lane returns nil here and is left to
  # `starved_lane`, which judges it on that lane's own terms — the point of the
  # overrides. That does mean a lane with a relaxed threshold is tolerated for
  # longer when it stalls alone; for `agents` that is the intent, and a worker that
  # is wholly dead cannot be caught here at all, since this monitor runs on the
  # worker it watches. That case belongs to the external Grafana rule, which is why
  # it exists alongside this one.
  def stalled_lane_backlog(queue_stats)
    depths = queue_stats[:ready_count_by_queue] || {}
    ages = queue_stats[:oldest_ready_age_seconds_by_queue] || {}

    # `depths.key?` and not just the age test: the two halves are separate queries
    # against a moving table, so a lane can drain away between them and leave an age
    # behind with no rows under it. Such a lane adds nothing to the summed depth
    # either way, but counting it toward the lane tally would let an already-empty
    # queue help clear the two-lane bar. `starved_lane` guards the mirror of this
    # with its `next if age.nil?`.
    stalled = ages.select do |queue, age|
      depths.key?(queue) && age >= lane_critical_thresholds(queue)[:stall_age]
    end
    return nil if stalled.size < WORKER_STALL_MIN_LANES

    depth = stalled.sum { |queue, _age| depths[queue].to_i }
    return nil if depth < QUEUE_DEPTH_CRITICAL_THRESHOLD

    { depth: depth, lanes: stalled.size, freshest_age_seconds: stalled.values.min }
  end

  # A lane absent from QUEUE_LANE_CRITICAL_THRESHOLDS keeps the original calibration.
  # That is the right default for a lane nobody has sized yet as well as for the fast
  # ones: a new queue is a `default`-shaped queue until somebody says otherwise.
  def lane_critical_thresholds(queue)
    QUEUE_LANE_CRITICAL_THRESHOLDS.fetch(queue) do
      { depth: QUEUE_DEPTH_CRITICAL_THRESHOLD, stall_age: QUEUE_STALL_CRITICAL_AGE }
    end
  end

  def format_wait(seconds)
    self.class.format_wait(seconds)
  end

  def format_wait_range(from_seconds, to_seconds)
    self.class.format_wait_range(from_seconds, to_seconds)
  end

  # Calculate overall system status from the section statuses `full_health_report`
  # already computed.
  #
  # @param statuses [Array<HealthStatus>] one per summarized section
  def calculate_overall_status(statuses)
    if statuses.any?(&:critical?)
      HealthStatus.new(status: :critical, message: "One or more critical issues detected")
    elsif statuses.any?(&:warning?)
      HealthStatus.new(status: :warning, message: "One or more warnings detected")
    elsif (unevaluated = statuses.count(&:unknown?)).positive?
      # Still `:healthy` — an unevaluated check is not a fault, and escalating on it
      # would page for a condition that is permanent by design. But not "all systems
      # operational" either: that sentence claims a check was made. Naming the count
      # is the difference between a report that is quiet and one that lies.
      HealthStatus.new(
        status: :healthy,
        message: "No issues detected in #{statuses.size - unevaluated} of #{statuses.size} checks; " \
                 "#{unevaluated} could not be evaluated"
      )
    else
      HealthStatus.new(status: :healthy, message: "All systems operational")
    end
  end
end
