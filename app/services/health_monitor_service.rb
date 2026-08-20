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

  # How many entries `ready_backlog_breakdown` keeps from each breakdown. Enough
  # to cover every Zimmer queue and still name the job classes that matter, short
  # enough that the alert body stays readable in Slack.
  READY_BREAKDOWN_LIMIT = 5
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

  # Structured result for health status
  HealthStatus = Struct.new(:status, :message, keyword_init: true) do
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
      sigterm_retry_health: sigterm_retry_health,
      api_error_retry_health: api_error_retry_health,
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

  # Get SIGTERM retry health information
  # Tracks sessions that have experienced SIGTERM exits and their retry behavior
  # @return [Hash] SIGTERM retry health data
  def sigterm_retry_health
    rate_limit_tracker = GlobalRateLimitTracker.new

    # Use SQL aggregation to get counts and sum in a single query
    # This avoids loading all sessions into memory
    # Using pluck to avoid ORDER BY issues with aggregate functions
    total_sigterm_sessions, total_retries_attempted = Session
      .where("metadata->>'sigterm_retry_count' IS NOT NULL")
      .pluck(
        Arel.sql("COUNT(*)"),
        Arel.sql("COALESCE(SUM((metadata->>'sigterm_retry_count')::int), 0)")
      ).first

    total_sigterm_sessions = total_sigterm_sessions.to_i
    total_retries_attempted = total_retries_attempted.to_i

    # Count recovered sessions (not failed, have retry count > 0) using SQL
    successful_recovery_count = Session
      .where("metadata->>'sigterm_retry_count' IS NOT NULL")
      .where.not(status: :failed)
      .count

    # Count exhausted retries using SQL (failed with retry count >= MAX_RETRIES)
    exhausted_retry_count = Session
      .where("metadata->>'sigterm_retry_count' IS NOT NULL")
      .where(status: :failed)
      .where("(metadata->>'sigterm_retry_count')::int >= ?", SigtermRetryService::MAX_RETRIES)
      .count

    # Get recent SIGTERM events (last 24 hours)
    # We filter in Ruby to gracefully handle invalid timestamps in metadata
    # This loads sessions with last_sigterm_at set, then filters by time
    threshold = 24.hours.ago
    all_sigterm_sessions = Session.where("metadata->>'last_sigterm_at' IS NOT NULL")
    recent_sigterm_sessions = all_sigterm_sessions.select do |session|
      timestamp = parse_timestamp_safely(session.metadata&.dig("last_sigterm_at"))
      timestamp && timestamp > threshold
    end.sort_by do |session|
      parse_timestamp_safely(session.metadata&.dig("last_sigterm_at")) || Time.at(0)
    end.reverse.first(RECENT_EVENTS_DISPLAY_LIMIT)

    recent_sigterm_count = all_sigterm_sessions.count do |session|
      timestamp = parse_timestamp_safely(session.metadata&.dig("last_sigterm_at"))
      timestamp && timestamp > threshold
    end

    {
      total_sigterm_sessions: total_sigterm_sessions,
      total_retries_attempted: total_retries_attempted,
      successful_recovery_count: successful_recovery_count,
      exhausted_retry_count: exhausted_retry_count,
      recent_sigterm_count: recent_sigterm_count,
      rate_limit_pressure: rate_limit_tracker.under_pressure?,
      rate_limit_events_5min: rate_limit_tracker.recent_event_count,
      current_delay_mode: rate_limit_tracker.under_pressure? ? "escalated" : "normal",
      max_retries: SigtermRetryService::MAX_RETRIES,
      recent_sigterm_sessions: recent_sigterm_sessions.map { |s| sigterm_session_summary(s) }
    }
  end

  # Get API error retry health information
  # Tracks sessions that have experienced API errors (server errors + rate limits)
  # and their retry behavior. Shares the same GlobalRateLimitTracker as SIGTERM retries.
  # @return [Hash] API error retry health data
  def api_error_retry_health
    rate_limit_tracker = GlobalRateLimitTracker.new

    total_api_error_sessions, total_retries_attempted = Session
      .where("metadata->>'api_error_retry_count' IS NOT NULL")
      .pluck(
        Arel.sql("COUNT(*)"),
        Arel.sql("COALESCE(SUM((metadata->>'api_error_retry_count')::int), 0)")
      ).first

    total_api_error_sessions = total_api_error_sessions.to_i
    total_retries_attempted = total_retries_attempted.to_i

    successful_recovery_count = Session
      .where("metadata->>'api_error_retry_count' IS NOT NULL")
      .where.not(status: :failed)
      .count

    exhausted_retry_count = Session
      .where("metadata->>'api_error_retry_count' IS NOT NULL")
      .where(status: :failed)
      .where("(metadata->>'api_error_retry_count')::int >= ?", ApiErrorRetryService::MAX_RETRIES)
      .count

    # Get recent API error events (last 24 hours)
    threshold = 24.hours.ago
    all_api_error_sessions = Session.where("metadata->>'last_api_error_retry_at' IS NOT NULL")
    recent_api_error_sessions = all_api_error_sessions.select do |session|
      timestamp = parse_timestamp_safely(session.metadata&.dig("last_api_error_retry_at"))
      timestamp && timestamp > threshold
    end.sort_by do |session|
      parse_timestamp_safely(session.metadata&.dig("last_api_error_retry_at")) || Time.at(0)
    end.reverse.first(RECENT_EVENTS_DISPLAY_LIMIT)

    recent_api_error_count = all_api_error_sessions.count do |session|
      timestamp = parse_timestamp_safely(session.metadata&.dig("last_api_error_retry_at"))
      timestamp && timestamp > threshold
    end

    # Count sessions that hit account quota limits (daily/weekly limits, not transient 429s)
    quota_limit_sessions_count = Session
      .where("metadata->>'last_quota_limit_at' IS NOT NULL")
      .count

    recent_quota_limit_count = Session
      .where("metadata->>'last_quota_limit_at' IS NOT NULL")
      .where("(metadata->>'last_quota_limit_at')::timestamp > ?", threshold)
      .count

    {
      total_api_error_sessions: total_api_error_sessions,
      total_retries_attempted: total_retries_attempted,
      successful_recovery_count: successful_recovery_count,
      exhausted_retry_count: exhausted_retry_count,
      recent_api_error_count: recent_api_error_count,
      quota_limit_sessions_count: quota_limit_sessions_count,
      recent_quota_limit_count: recent_quota_limit_count,
      rate_limit_pressure: rate_limit_tracker.under_pressure?,
      rate_limit_events_5min: rate_limit_tracker.recent_event_count,
      current_delay_mode: rate_limit_tracker.under_pressure? ? "escalated" : "normal",
      max_retries: ApiErrorRetryService::MAX_RETRIES,
      recent_api_error_sessions: recent_api_error_sessions.map { |s| api_error_session_summary(s) }
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

    @logger.info("Old sessions archived", count: results[:archived].size)
    results
  end

  # The backlog split by queue and by job class.
  #
  # `queue_statistics` answers "how deep", which is what the thresholds need. It
  # does not answer "deep with WHAT", and that is the question every triage of a
  # backlog page actually opens with: a ready count alone cannot distinguish a
  # starved queue from a busy one, and Zimmer runs four queues with very different
  # thread counts and job durations.
  #
  # Deliberately NOT folded into `queue_statistics`. That runs on every /health
  # render; these are two more grouped scans of `good_jobs` and are only worth
  # paying for when something is about to page. Cardinality is small either way —
  # four queues, and job classes bounded by the app's job count — so the grouping
  # is done in SQL and the ordering in Ruby, which keeps this free of adapter
  # differences in how a grouped COUNT may be ordered.
  #
  # @param limit [Integer] how many entries to keep from each breakdown
  # @return [Hash] :by_queue and :by_job_class, each an ordered Hash of name => count
  def ready_backlog_breakdown(limit: READY_BREAKDOWN_LIMIT)
    ready = ready_scope(GoodJob::Job.where(finished_at: nil, locked_by_id: nil))

    {
      by_queue: top_counts(ready.group(:queue_name).count, limit),
      by_job_class: top_counts(ready.group(:job_class).count, limit)
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

    {
      pending_count: pending_jobs.count,
      ready_count: ready_jobs.count,
      scheduled_count: scheduled_jobs.count,
      claimed_count: running_jobs.count,
      failed_count: failed_jobs.count,
      oldest_ready_age_seconds: oldest_ready_age_seconds(ready_jobs),
      processing_rate_per_hour: completed_last_hour
    }
  end

  # How long the longest-waiting ready job has been waiting, in seconds — nil when
  # nothing is ready.
  #
  # "Waiting since" is `scheduled_at` for a job that was future-dated — it only became
  # backlog when its scheduled time arrived, and charging it for the hours it spent
  # correctly parked would make every wake-up trigger look like a stall — falling back
  # to `created_at` for a row with no `scheduled_at` at all.
  #
  # Read real columns rather than `minimum(Arel.sql(...))`: a calculation over a raw
  # SQL expression has no column to infer a type from, so the adapter decides whether
  # you get a Time or a String. `pick` on the columns themselves does not, and it
  # avoids materializing a whole row (including its `serialized_params` jsonb) on a
  # path that runs on every /health render and every monitor tick.
  def oldest_ready_age_seconds(ready_jobs)
    scheduled_at, created_at = ready_jobs.order(Arel.sql("COALESCE(scheduled_at, created_at) ASC"))
                                         .pick(:scheduled_at, :created_at)
    waiting_since = scheduled_at || created_at
    return nil if waiting_since.nil?

    [ (Time.current - waiting_since).round, 0 ].max
  end

  # Unclaimed work whose time has come — the population every "backlog" number
  # here is taken over. A row with no `scheduled_at` was ready the moment it was
  # created; a future-dated one is not backlog until its time arrives.
  def ready_scope(unclaimed_jobs)
    unclaimed_jobs.where("scheduled_at <= ? OR scheduled_at IS NULL", Time.current)
  end

  # Biggest first, keeping at most `limit`. A nil key (a row GoodJob wrote with no
  # job_class, which ADAPTER-enqueued rows can have) is labelled rather than
  # dropped, so the counts in the breakdown still add up against `ready_count`.
  def top_counts(counts, limit)
    counts.transform_keys { |key| key.presence || "(unknown)" }
          .sort_by { |_name, count| -count }
          .first(limit)
          .to_h
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

  # Create a summary of a session for SIGTERM retry display
  # Safely parses timestamp to handle corrupted data
  def sigterm_session_summary(session)
    last_sigterm_at = parse_timestamp_safely(session.metadata&.dig("last_sigterm_at"))

    {
      id: session.id,
      slug: session.slug,
      title: session.title,
      status: session.status,
      git_root: session.git_root,
      retry_count: session.metadata&.dig("sigterm_retry_count") || 0,
      last_sigterm_at: last_sigterm_at,
      updated_at: session.updated_at
    }
  end

  # Create a summary of a session for API error retry display
  # Safely parses timestamp to handle corrupted data
  def api_error_session_summary(session)
    last_api_error_at = parse_timestamp_safely(session.metadata&.dig("last_api_error_retry_at"))

    {
      id: session.id,
      slug: session.slug,
      title: session.title,
      status: session.status,
      git_root: session.git_root,
      retry_count: session.metadata&.dig("api_error_retry_count") || 0,
      last_api_error_at: last_api_error_at,
      updated_at: session.updated_at
    }
  end

  # Safely parse a timestamp string, returning nil if invalid
  def parse_timestamp_safely(timestamp_string)
    return nil if timestamp_string.blank?

    Time.parse(timestamp_string)
  rescue ArgumentError => e
    @logger.error("Invalid timestamp in session metadata", value: timestamp_string, error: e.message)
    nil
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
  # been waiting. Critical needs both — deep *and* stalled; see the threshold
  # constants. A deep queue that is still draining is a warning, which surfaces on the
  # health dashboard without paging anyone.
  def system_health_status(queue_stats)
    depth = queue_stats[:ready_count].to_i
    waiting_for = queue_stats[:oldest_ready_age_seconds].to_i

    if depth >= QUEUE_DEPTH_CRITICAL_THRESHOLD && waiting_for >= QUEUE_STALL_CRITICAL_AGE
      HealthStatus.new(
        status: :critical,
        message: "Queue backlog critical: #{depth} jobs ready, oldest waiting #{format_wait(waiting_for)}"
      )
    elsif depth >= QUEUE_DEPTH_WARNING_THRESHOLD
      HealthStatus.new(status: :warning, message: "Queue backlog elevated: #{depth} jobs ready")
    else
      HealthStatus.new(status: :healthy, message: "Queue processing normally")
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

    statuses = [ process_status, session_status, system_status, egress_status ]

    if statuses.any?(&:critical?)
      HealthStatus.new(status: :critical, message: "One or more critical issues detected")
    elsif statuses.any?(&:warning?)
      HealthStatus.new(status: :warning, message: "One or more warnings detected")
    else
      HealthStatus.new(status: :healthy, message: "All systems operational")
    end
  end
end
