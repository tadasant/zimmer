# frozen_string_literal: true

# Makes a session's memory bound legible while the session is still running.
#
# SessionMemoryCgroup contains a runaway command; this reports it. Without something
# on this side, the containment is invisible in exactly the case it was built for:
# when the kernel kills a TOOL SUBPROCESS the agent stays alive, its Bash tool returns
# a bare `Killed` / exit 137, and neither the agent nor the human is told that a limit
# was hit — which is the third item tadasant/zimmer#815 asked for.
#
# Three things get reported, all into the session log the human reads:
#
#   * an OOM kill inside this session's cgroup, the moment the counter moves. This is
#     the one that matters, and what has been reported is recorded on the session so
#     that ProcessLifecycleManager can tell "the agent died BECAUSE of the bound" from
#     "the agent died of something else, and a subprocess was killed an hour ago".
#   * crossing WARN_FRACTION of the bound, once. That is the early warning; a
#     `memory.high` watermark would have been the kernel-side way to get one, but the
#     memory at issue is anonymous and the worker has no swap, so a watermark buys a
#     long allocator stall and then the same kill. Polling costs two file reads.
#   * crossing POOL_WARN_FRACTION of the SHARED pool's bound, once. A session can be
#     killed while nowhere near its own limit, because every session on the box shares
#     one aggregate `memory.max` (tadasant/zimmer#981). Without this the session log
#     would say a session using 400 MB of its 4 GB was killed for memory, which reads
#     like a bug rather than like a busy box.
#   * a cgroup that exists but never took a process, once. That means the `sh` wrapper
#     could not migrate and the session is running UNBOUNDED. The wrapper says so on
#     the runtime's stderr log, but that log only reaches the session log when a turn
#     fails — so on its own it is not a way to hear that the protection is off.
#
# Driven from AgentSessionJob's monitoring loop, which ticks every 0.5s — far too often
# for this, hence CHECK_INTERVAL. Every read is best-effort: a cgroup that vanished
# (deploy, sweep) or a container with no cgroup support at all leaves this a no-op
# rather than an exception on the monitoring path.
class SessionMemoryWatch
  include DatabaseRetry

  # Seconds between reads. The ramp that prompted this took 35 minutes, and the fastest
  # on record (tadasant/zimmer#719) took 90 seconds, so 10s is not the resolution that
  # decides whether the warning is useful.
  CHECK_INTERVAL = 10

  # Fraction of the bound that earns a one-time warning.
  WARN_FRACTION = 0.75

  # The same, for the pool every session shares. Higher than WARN_FRACTION because the
  # pool is *expected* to run warm — it is sized to be used, and a box running eight
  # sessions sits well above 75% of it in normal operation — so a warning at 0.75 would
  # be on almost all the time and would say nothing.
  POOL_WARN_FRACTION = 0.9

  # @param session [Session]
  # @param clock [#call] injectable for tests
  def initialize(session, clock: -> { Time.current })
    @session = session
    @clock = clock
    @cgroup = SessionMemoryCgroup.for(session.id)
    @last_checked_at = nil
    @warned_high = false
    @warned_unbounded = false
    @warned_pool = false
  end

  # @return [Boolean] whether this container can bound and observe the session at all
  def active?
    !@cgroup.nil?
  end

  # One tick of the monitoring loop. Cheap and self-throttling, so the caller can call
  # it unconditionally.
  #
  # @param log_buffer [#add] the session's log buffer
  # @return [void]
  def check(log_buffer)
    return unless active?
    return unless due?

    first_check = @last_checked_at.nil?
    @last_checked_at = @clock.call
    @pool_stats = nil

    stats = @cgroup.stats
    report_oom_kills(stats, log_buffer)
    report_high_usage(stats, log_buffer)
    report_pool_pressure(log_buffer)
    report_unbounded(log_buffer) unless first_check
  rescue StandardError => e
    # Never the reason a monitoring loop dies. A missing warning is a missing warning;
    # an exception here would take the session with it.
    Rails.logger.warn("[SessionMemoryWatch] session=#{@session.id} check failed: #{e.message}")
  end

  private

  def due?
    @last_checked_at.nil? || (@clock.call - @last_checked_at) >= CHECK_INTERVAL
  end

  # The kernel killed something in this session's cgroup. Say what, and how close to the
  # bound it was, because "your session hit its 4 GB limit" is the sentence a bare
  # `Killed` in a tool result is missing.
  #
  # The record is written BEFORE the log line. If the write fails, the rescue above
  # swallows it and the next tick tries again — whereas logging first would re-emit the
  # same warning every 10 seconds for the rest of the turn.
  def report_oom_kills(stats, log_buffer)
    observed = stats.oom_kills
    return if observed.nil?

    killed = @cgroup.unaccounted_oom_kills(@session)
    return if killed.nil? || killed.zero?

    # The scope has to be computed before the baseline moves, so #record_oom_kills! is
    # what computes it and hands it back.
    scope = with_db_retry { @cgroup.record_oom_kills!(@session, observed) }

    log_buffer.add(oom_kill_message(killed, stats, scope), level: "warning")
    Rails.logger.warn(
      "[SessionMemoryWatch] session=#{@session.id} oom_kills=#{observed} " \
      "peak=#{stats.peak_bytes} limit=#{stats.limit_bytes}"
    )
  end

  # Which bound the session ran into, because they are two different pieces of advice.
  #
  # Its own bound means the session allocated too much and the fix is in the session:
  # stream the output, split the build, stop holding the file in memory. The shared pool
  # means the box was busy and this session was simply the one holding memory when it ran
  # out — nothing the agent did is wrong, and telling it to allocate less would be advice
  # for a problem it does not have.
  #
  # A scope of nil is a kernel that could not answer, and says the honest thing: the limit
  # was reached, without claiming which one.
  def oom_kill_message(killed, stats, scope)
    opening = "The kernel killed #{killed} process(es) in this session. A command that ran " \
      "out of memory exits with a bare \"Killed\" and status 137 — that is this, not a bug " \
      "in the command."

    case scope
    when SessionMemoryCgroup::SESSION_SCOPE
      "#{opening} The session reached its own memory limit of " \
        "#{human_bytes(stats.limit_bytes)} (peak #{human_bytes(stats.peak_bytes)}), so " \
        "nothing outside this session was affected."
    when SessionMemoryCgroup::POOL_SCOPE
      "#{opening} This session never reached its own limit of " \
        "#{human_bytes(stats.limit_bytes)} — what ran out is the " \
        "#{human_bytes(pool_stats.limit_bytes)} of memory that ALL sessions on this worker " \
        "share. Retrying is reasonable once the box is quieter; running fewer things at " \
        "once inside this session (parallel test workers, concurrent builds) makes it less " \
        "likely."
    else
      "#{opening} The session reached a memory limit of " \
        "#{human_bytes(stats.limit_bytes)} (peak #{human_bytes(stats.peak_bytes)})."
    end
  end

  # Live pressure on the pool, for the early warning. `memory.current` is the right signal
  # HERE and the wrong one for attributing a kill — see SessionMemoryCgroup#kill_scope.
  def pool_exhausted?
    return false if pool_stats.current_bytes.nil? || pool_stats.limit_bytes.nil?

    pool_stats.current_bytes >= pool_stats.limit_bytes * POOL_WARN_FRACTION
  end

  # Read once per tick, not once per question: the kill message and the pressure warning
  # both consult it, and they must be looking at the same reading.
  def pool_stats
    @pool_stats ||= SessionMemoryCgroup.pool_stats
  end

  # Once per job, not once per tick: a session that sits at 80% for an hour has one
  # thing to say, and the monitoring loop's log is read by humans.
  def report_high_usage(stats, log_buffer)
    return if @warned_high
    return if stats.current_bytes.nil? || stats.limit_bytes.nil?
    return if stats.current_bytes < stats.limit_bytes * WARN_FRACTION

    @warned_high = true
    log_buffer.add(
      "This session is using #{human_bytes(stats.current_bytes)} of its " \
      "#{human_bytes(stats.limit_bytes)} memory limit. If it reaches the limit the " \
      "kernel kills the largest process in the session — most likely whatever is " \
      "allocating. Consider streaming large output instead of holding it in memory.",
      level: "warning"
    )
  end

  # The shared pool is nearly full, so this session may be killed while comfortably
  # inside its own bound. Once per job, like the bound warning above.
  #
  # This is the visibility half of tadasant/zimmer#981: the pile-up that killed the Rails
  # worker on 2026-09-05 was invisible from inside any one session, because every session
  # involved was doing something entirely reasonable.
  def report_pool_pressure(log_buffer)
    return if @warned_pool
    return unless pool_exhausted?

    @warned_pool = true
    log_buffer.add(
      "All agent sessions on this worker share " \
      "#{human_bytes(pool_stats.limit_bytes)} of memory, and " \
      "#{human_bytes(pool_stats.current_bytes)} of it is in use. A session can be " \
      "OOM-killed here while well inside its own limit. If this session is running " \
      "something parallel — a test suite, a build — consider narrowing it.",
      level: "warning"
    )
    Rails.logger.warn(
      "[SessionMemoryWatch] session=#{@session.id} pool_current=#{pool_stats.current_bytes} " \
      "pool_limit=#{pool_stats.limit_bytes}"
    )
  end

  # A cgroup with nothing in it, while a process is supposed to be running in it, means
  # the `sh` wrapper could not migrate — so the session is running with no bound at all
  # and every other reading here is a zero that means nothing.
  #
  # Never on the first tick: the wrapper writes its pid a moment after the spawn, and
  # racing it would report a failure that did not happen.
  def report_unbounded(log_buffer)
    return if @warned_unbounded
    return unless @cgroup.exists?
    return unless File.read(@cgroup.procs_path).empty?

    @warned_unbounded = true
    log_buffer.add(
      "This session's memory cgroup (#{@cgroup.path}) holds no processes, so the " \
      "per-session memory limit is NOT in force for this turn and the session can " \
      "consume the whole worker's memory. The runtime's stderr log has the reason.",
      level: "warning"
    )
    Rails.logger.warn("[SessionMemoryWatch] session=#{@session.id} is running unbounded")
  rescue SystemCallError
    # The cgroup went away between the two checks. Nothing to report.
    nil
  end

  def human_bytes(bytes)
    return "unknown" if bytes.nil?

    ActiveSupport::NumberHelper.number_to_human_size(bytes)
  end
end
