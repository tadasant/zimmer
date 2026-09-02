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

  # How many entries `ready_backlog_breakdown` keeps from each breakdown. Enough
  # to cover every Zimmer queue and still name the job classes that matter, short
  # enough that the alert body stays readable in Slack. Whatever the limit cuts is
  # reported as a remainder entry rather than dropped.
  READY_BREAKDOWN_LIMIT = 5

  # What a row with no `job_class` (or no `queue_name`) is called in a breakdown.
  UNKNOWN_LABEL = "(unknown)"
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

  # Compact human-readable wait ("45s", "12m", "2h 5m"). Public because the Slack page
  # `SystemHealthMonitorJob` sends is the one surface where a human, not a parser,
  # reads this number — "oldest waiting 18000s" is worse there than "5h 0m".
  def self.format_wait(seconds)
    seconds = seconds.to_i
    return "#{seconds}s" if seconds < 60
    return "#{seconds / 60}m" if seconds < 3600

    "#{seconds / 3600}h #{(seconds % 3600) / 60}m"
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
  end

  def initialize(process_manager: nil)
    @process_manager = process_manager || SystemProcessManager.new
    @logger = StructuredLogger.new({ service: "HealthMonitorService" })
  end

  # Generate a complete health report
  # @return [Hash] Full health report with all sections
  def full_health_report
    {
      process_health: process_health,
      session_health: session_health,
      system_health: system_health,
      egress_health: egress_health,
      auth_health: auth_health,
      retry_budget_health: retry_budget_health,
      sigterm_retry_health: sigterm_retry_health,
      api_error_retry_health: api_error_retry_health,
      post_deploy_task_health: post_deploy_task_health,
      overall_status: calculate_overall_status,
      generated_at: Time.current
    }
  end

  # Get process health information
  # @return [Hash] Process health data
  def process_health
    active_processes = find_active_claude_processes
    orphaned_processes = find_orphaned_processes(active_processes)
    tracked_processes = @process_manager.tracked_processes

    {
      active_count: active_processes.size,
      active_processes: active_processes,
      orphaned_count: orphaned_processes.size,
      orphaned_processes: orphaned_processes,
      tracked_count: tracked_processes.size,
      tracked_processes: tracked_processes.values,
      status: process_health_status(orphaned_processes.size)
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
  # error) and read as complete, while the signal-death, MCP-connection and
  # context-length budgets were invisible to /health, to get_system_health and to
  # SystemHealthMonitorJob — so "why did this session fail permanently" could not be
  # answered from any health surface for three of the five ways it can happen.
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
      status: system_health_status(queue_stats)
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
          with_db_retry do
            # Clear stale retry metadata for fresh execution.
            # See Session::STALE_RETRY_METADATA_KEYS for the full list of keys cleared.
            session.update!(
              metadata: (session.metadata || {}).except(*Session::STALE_RETRY_METADATA_KEYS)
            )
            session.resume_for_system_recovery!
            AgentSessionJob.enqueue_with_prompt(session.id, AutomatedPrompts::SYSTEM_RECOVERY)
          end
          results[:retried] << session.id
          @logger.info("Session retry initiated", session_id: session.id)
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
  # only printing it; the Grafana rule over
  # `zimmer_good_job_oldest_ready_age_seconds` still reads the single global number.
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

    # One read, two answers. `system_health_status` needs each lane's depth AND each
    # lane's head-of-line age to evaluate its conjunction within a lane, and taking
    # them from separate queries against a moving table would let it threshold one
    # lane's depth against another lane's age. Uncapped, unlike the alert body's
    # breakdown: a lane the cap cut would read as having no depth at all, and the
    # gate would stop seeing the very queue that is starving.
    heads = head_of_line_by_queue(ready_jobs)

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
      ready_count_by_queue: lane_depths(ready_jobs),
      oldest_ready_age_seconds_by_queue: lane_head_ages(heads),
      # The global head of line is the oldest of the per-lane heads by definition —
      # the oldest ready row anywhere is the head of its own lane — so it comes from
      # the same read rather than a query of its own, and the two can no longer
      # disagree about a row that drained between them.
      oldest_ready_age_seconds: heads.first&.fetch(:age_seconds),
      processing_rate_per_hour: completed_last_hour
    }
  end

  # Ready depth per lane, deepest first, uncapped, with the same UNKNOWN_LABEL
  # treatment `head_of_line_by_queue` gives a row GoodJob wrote with no queue name —
  # so a lane appears under one key in both halves and the gate can join them.
  #
  # Ordered rather than left in the adapter's grouping order, so two reads of an
  # unchanged queue serialize identically; and a plain Hash rather than the
  # accumulator's `Hash.new(0)`, so a lane with nothing ready reads as absent to a
  # Ruby caller too and not as a zero the default conjured.
  def lane_depths(ready_jobs)
    counts = ready_jobs.group(:queue_name).count.each_with_object(Hash.new(0)) do |(queue, count), acc|
      acc[queue.presence || UNKNOWN_LABEL] += count
    end

    counts.sort_by { |queue, count| [ -count, queue.to_s ] }.to_h
  end

  # Head-of-line age per lane, oldest lane first. `heads` arrives sorted oldest
  # first and two raw queue names can share one label (a NULL and an empty string
  # both render as UNKNOWN_LABEL), so keeping the FIRST sighting keeps the older of
  # them — the age the gate has to see, and the one the alert body means. Writing
  # the label blind would keep the younger and quietly under-report the lane it
  # collapsed.
  def lane_head_ages(heads)
    heads.each_with_object({}) do |head, acc|
      acc[head[:queue]] ||= head[:age_seconds]
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

  # Get recent error logs
  def recent_error_logs
    Log.where(level: "error")
       .where("created_at > ?", 1.hour.ago)
       .order(created_at: :desc)
       .limit(20)
       .map do |log|
      {
        id: log.id,
        session_id: log.session_id,
        content: log.content.truncate(200),
        created_at: log.created_at
      }
    end
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
    # budget more than once: the generic section walks all five, and the SIGTERM and
    # API-error panels each read their own again. Unmemoised that is seven passes —
    # ~28 queries plus seven unbounded loads — on a page that refreshes every 30s.
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

    # Sessions that spent the budget and did NOT end up failed — the recovery worked.
    successful_recovery_count = budget.sessions.where.not(status: :failed).count

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

  # Determine process health status based on orphaned count
  def process_health_status(orphaned_count)
    if orphaned_count >= ORPHANED_PROCESS_CRITICAL_THRESHOLD
      HealthStatus.new(status: :critical, message: "#{orphaned_count} orphaned processes detected")
    elsif orphaned_count >= ORPHANED_PROCESS_WARNING_THRESHOLD
      HealthStatus.new(status: :warning, message: "#{orphaned_count} orphaned processes detected")
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
  # Both branches are strict narrowings of the queue-blind rule — every per-lane depth
  # threshold is at least QUEUE_DEPTH_CRITICAL_THRESHOLD and every per-lane stall age
  # at least QUEUE_STALL_CRITICAL_AGE, and the cross-lane branch sums a SUBSET of the
  # ready count — so nothing pages that did not page before. This only removes
  # firings, which is the whole point; it cannot add one.
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
  def system_health_status(queue_stats)
    depth = queue_stats[:ready_count].to_i

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

  # The single lane that is past both of its own thresholds, deepest first so the
  # message names the worst one when several qualify. Nil when every lane is within
  # what its thread count and its jobs' durations explain.
  def starved_lane(queue_stats)
    depths = queue_stats[:ready_count_by_queue] || {}
    ages = queue_stats[:oldest_ready_age_seconds_by_queue] || {}

    # `lane_depths` already returns deepest-first with a name tiebreak. Re-sorting
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

    stalled = ages.select { |queue, age| age >= lane_critical_thresholds(queue)[:stall_age] }
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

  # Calculate overall system status
  def calculate_overall_status
    process_status = process_health[:status]
    session_status = session_health[:status]
    system_status = system_health[:status]
    egress_status = egress_health[:status]
    auth_status = auth_health[:status]

    post_deploy_status = post_deploy_task_health[:status]

    statuses = [ process_status, session_status, system_status, egress_status, auth_status, post_deploy_status ]

    if statuses.any?(&:critical?)
      HealthStatus.new(status: :critical, message: "One or more critical issues detected")
    elsif statuses.any?(&:warning?)
      HealthStatus.new(status: :warning, message: "One or more warnings detected")
    else
      HealthStatus.new(status: :healthy, message: "All systems operational")
    end
  end
end
