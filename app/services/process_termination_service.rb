# Service for terminating processes gracefully with fallback to force kill
#
# This service handles the termination of Claude CLI processes and their children:
# - Detects zombie processes and handles appropriately
# - Checks process ownership before attempting termination
# - Attempts graceful termination with SIGTERM (process group first, then individual)
# - Waits for process to exit
# - Falls back to SIGKILL if process doesn't exit
# - Sweeps the process group with SIGKILL so grandchildren do not survive the leader
# - Returns structured results indicating success/failure reason
#
# Liveness of our own child is answered by reaping, not by signal 0 (#280).
# `Process.kill(0, pid)` keeps succeeding for a child that has already exited,
# because an unreaped child holds its pid as a zombie until someone waits on it.
# See #process_running?.
#
# Usage:
#   service = ProcessTerminationService.new(
#     process_pid: 12345,
#     process_manager: SystemProcessManager.new,
#     log_buffer: log_buffer
#   )
#   result = service.terminate
#   result.success?         # => true/false
#   result.status           # => :terminated, :already_dead, :zombie, :permission_denied, :error
#   result.message          # => human-readable message
#
class ProcessTerminationService
  include DatabaseRetry

  # How long the target gets to exit after a SIGTERM, per attempt. Each wait
  # polls and returns as soon as the process is actually gone, so this is a
  # ceiling, not a cost.
  TERM_GRACE_SECONDS = 3.0

  # How long to confirm a SIGKILL landed. SIGKILL is not deliverable-refusable;
  # this only covers the scheduler getting round to the reaping.
  KILL_GRACE_SECONDS = 1.0

  # How long the process GROUP gets to drain after the leader is confirmed dead,
  # before the group SIGKILL sweep. The group already received the SIGTERM in
  # strategy 1 — this is additional grace on top of however long the leader took
  # to exit. See #sweep_process_group.
  GROUP_DRAIN_GRACE_SECONDS = 1.0

  LIVENESS_POLL_INTERVAL = 0.1
  GROUP_POLL_INTERVAL = 0.05

  # Returned by #reap_process when the pid is not (or is no longer) our child,
  # so waiting on it can never answer the liveness question.
  NOT_OUR_CHILD = :not_our_child

  # Session log level => Rails.logger method. See #add_log.
  LOGGER_METHODS = {
    "debug" => :debug,
    "info" => :info,
    "warn" => :warn,
    "warning" => :warn,
    "error" => :error
  }.freeze

  attr_reader :process_pid, :process_manager, :log_buffer, :session

  # Structured result for termination operations
  TerminationResult = Struct.new(:status, :message, keyword_init: true) do
    def success?
      [ :terminated, :already_dead, :zombie_reaped ].include?(status)
    end
  end

  def initialize(process_pid:, process_manager: nil, log_buffer: nil, session: nil)
    @process_pid = process_pid
    @process_manager = process_manager || SystemProcessManager.new
    @log_buffer = log_buffer
    @session = session
    @logger = StructuredLogger.new({
      process_pid: process_pid,
      session_id: session&.id,
      service: "ProcessTerminationService"
    })
  end

  # Terminate the process
  # @return [TerminationResult] structured result indicating outcome
  def terminate
    unless process_pid
      return TerminationResult.new(status: :already_dead, message: "No process ID provided")
    end

    # Get process info for diagnostics
    info = process_info
    add_log("Terminating process #{process_pid}: #{info.inspect}", level: "info")

    # Handle zombie processes - they just need to be reaped
    if info[:is_zombie]
      add_log("Process #{process_pid} is a zombie, attempting to reap", level: "info")
      reap_process
      # The leader is already dead, but its process group may still hold live
      # grandchildren (MCP servers, node, gh). Sweep them the same way a normal
      # termination does.
      sweep_process_group
      return TerminationResult.new(status: :zombie_reaped, message: "Zombie process #{process_pid} reaped")
    end

    # Check if process is already dead. Deliberately no group sweep here: we never
    # observed this pid alive, so it may be stale or recycled, and `-pid` would
    # name whatever group a reused pid leads today. Every path that sweeps has
    # confirmed the leader first.
    unless info[:exists]
      add_log("Process #{process_pid} already terminated", level: "info")
      return TerminationResult.new(status: :already_dead, message: "Process #{process_pid} not found")
    end

    # Log ownership info for debugging
    if info[:owned_by_us]
      add_log("Process #{process_pid} is owned by current user (uid=#{info[:uid]})", level: "debug")
    else
      add_log("Process #{process_pid} has different owner (uid=#{info[:uid]}, ours=#{Process.uid})", level: "warning")
    end

    # Try termination strategies in order
    result = try_termination_strategies

    if result.success?
      add_log("Process #{process_pid} terminated successfully", level: "info")
    else
      add_log("Failed to terminate process #{process_pid}: #{result.message}", level: "error")
    end

    result
  end

  # Get information about the process
  # @return [Hash] process information including :exists, :is_zombie, :owned_by_us, :uid, :state
  def process_info
    info = {
      exists: false,
      is_zombie: false,
      owned_by_us: false,
      uid: nil,
      state: nil
    }

    # Validate process_pid is an integer to prevent command injection
    return info unless process_pid.is_a?(Integer) && process_pid > 0

    # On macOS, use ps command since /proc doesn't exist
    # On Linux, we could use /proc/#{pid}/stat
    # Using Open3 with array syntax to prevent command injection
    begin
      require "open3"
      ps_output, _status = Open3.capture2("ps", "-o", "uid=,stat=", "-p", process_pid.to_s)
      ps_output = ps_output.strip

      if ps_output.empty?
        # ps didn't find the process - check via process_manager as fallback
        # This handles cases like mock process managers in tests
        if @process_manager.running?(process_pid)
          info[:exists] = true
          info[:owned_by_us] = true  # Assume owned by us if mock/test scenario
          info[:uid] = Process.uid
          info[:state] = "S"  # Default to sleeping state
        end
        return info
      end

      parts = ps_output.split
      return info if parts.length < 2

      info[:exists] = true
      info[:uid] = parts[0].to_i
      info[:state] = parts[1]
      info[:is_zombie] = parts[1].include?("Z")
      info[:owned_by_us] = info[:uid] == Process.uid
    rescue => e
      add_log("Error getting process info: #{e.message}", level: "debug")
      # On error, fall back to checking via process_manager
      if @process_manager.running?(process_pid)
        info[:exists] = true
        info[:owned_by_us] = true
        info[:uid] = Process.uid
        info[:state] = "S"
      end
    end

    info
  end

  private

  # Try multiple termination strategies in sequence
  #
  # Each step waits on a truthful liveness check (see #process_running?), so a
  # step that works ends the ladder immediately instead of falling through the
  # remaining ~15s of sleeps and redundant signals it used to (#280).
  #
  # @return [TerminationResult] result of termination attempt
  def try_termination_strategies
    # Strategy 1: SIGTERM to process group
    result = try_signal_process_group("TERM")
    return finish(result) if result&.success?

    # If process group failed but process still exists, try individual process
    if process_running?
      # Strategy 2: SIGTERM to individual process
      result = try_signal_individual("TERM")
      return finish(result) if result&.success?
    else
      return finish(TerminationResult.new(status: :terminated, message: "Process terminated after group signal"))
    end

    # Strategy 3: SIGKILL. Strategy 2 already spent its full SIGTERM grace on a
    # liveness check that now tells the truth, so there is nothing left to wait
    # for before escalating.
    result = force_kill_if_needed
    return finish(result) if result

    # Final check
    if process_running?
      TerminationResult.new(status: :error, message: "Process #{process_pid} could not be terminated")
    else
      # Reap to prevent zombie (a no-op if the liveness check above already did)
      reap_process
      finish(TerminationResult.new(status: :terminated, message: "Process #{process_pid} terminated"))
    end
  rescue Errno::EPERM => e
    add_log("Permission denied when trying to kill process #{process_pid}", level: "error")
    TerminationResult.new(status: :permission_denied, message: "Permission denied: #{e.message}")
  rescue => e
    add_log("Error terminating process: #{e.message}", level: "error")
    TerminationResult.new(status: :error, message: "Error: #{e.message}")
  end

  # Try to signal the process group
  # @param signal [String] signal to send
  # @return [TerminationResult, nil] result if terminal, nil to continue
  def try_signal_process_group(signal)
    @process_manager.kill(signal, -process_pid)
    wait_for_termination
    return nil if process_running?

    reap_process
    TerminationResult.new(status: :terminated, message: "Process group terminated with SIG#{signal}")
  rescue Errno::ESRCH
    # Process group not found, continue to individual process
    nil
  rescue Errno::EPERM
    # Permission denied on process group, try individual
    add_log("Permission denied for process group -#{process_pid}, trying individual process", level: "debug")
    nil
  end

  # Try to signal the individual process
  # @param signal [String] signal to send
  # @return [TerminationResult, nil] result if terminal, nil to continue
  def try_signal_individual(signal)
    @process_manager.kill(signal, process_pid)
    wait_for_termination
    return nil if process_running?

    reap_process
    TerminationResult.new(status: :terminated, message: "Process terminated with SIG#{signal}")
  rescue Errno::ESRCH
    TerminationResult.new(status: :already_dead, message: "Process #{process_pid} already terminated")
  rescue Errno::EPERM
    TerminationResult.new(status: :permission_denied, message: "Permission denied for process #{process_pid}")
  end

  # Wait for the process to terminate, polling a truthful liveness check.
  # Returns as soon as the process is gone.
  # @param timeout [Float] ceiling in seconds
  def wait_for_termination(timeout: TERM_GRACE_SECONDS)
    deadline = monotonic_now + timeout
    while process_running?
      break if monotonic_now >= deadline
      sleep LIVENESS_POLL_INTERVAL
    end
  end

  # Force kill the process if it's still running
  # @return [TerminationResult, nil] result if successfully killed, nil otherwise
  def force_kill_if_needed
    return nil unless process_running?

    add_log("Force killing process #{process_pid} with SIGKILL", level: "info")

    # Try process group first
    begin
      @process_manager.kill("KILL", -process_pid)
      wait_for_termination(timeout: KILL_GRACE_SECONDS)
      unless process_running?
        reap_process
        return TerminationResult.new(status: :terminated, message: "Process group killed with SIGKILL")
      end
    rescue Errno::ESRCH, Errno::EPERM
      # Process group not found or permission denied, try individual
    end

    # Try individual process
    begin
      @process_manager.kill("KILL", process_pid)
      wait_for_termination(timeout: KILL_GRACE_SECONDS)
      unless process_running?
        reap_process
        return TerminationResult.new(status: :terminated, message: "Process killed with SIGKILL")
      end
    rescue Errno::ESRCH
      return TerminationResult.new(status: :already_dead, message: "Process already terminated")
    rescue Errno::EPERM
      return TerminationResult.new(status: :permission_denied, message: "Permission denied for SIGKILL")
    end

    nil
  end

  # Run the grandchild sweep on the way out of a successful termination, and
  # return the result untouched. A failed sweep never downgrades a termination
  # that worked — the leader is dead either way, and the result callers act on
  # is about the leader.
  # @param result [TerminationResult, nil]
  # @return [TerminationResult, nil] the same result
  def finish(result)
    sweep_process_group if result&.success?
    result
  end

  # SIGKILL whatever is left of the leader's process group.
  #
  # Agent children are spawned with `pgroup: true`, so the leader's grandchildren
  # — MCP servers, `node`, `gh` — live in its process group and are reparented to
  # init when it dies. They received the group SIGTERM in strategy 1; anything
  # still alive after the leader has exited either ignored it or is wedged, and
  # nothing is left to report to. So the semantics are:
  #
  #   1. Probe the group with signal 0. An empty group (ESRCH) means there is
  #      nothing to sweep and no signal is sent — which is also the common case,
  #      making the sweep free for a single-process termination.
  #   2. Give a live group GROUP_DRAIN_GRACE_SECONDS to drain on its own, polling
  #      so a group that exits promptly costs one extra probe.
  #   3. SIGKILL the group, then confirm.
  #
  # Before #280 this sweep happened on every termination, but only as a side
  # effect of the liveness bug — the leader always looked alive, so the ladder
  # always escalated to a group SIGKILL. Making liveness truthful removes that
  # accident, so the sweep is deliberate here instead.
  #
  # The leader's pid is already reaped by the time this runs, which raises the
  # obvious question the `:already_dead` branch above worries about: could the pid
  # be recycled during the drain window, so that `-process_pid` names a stranger's
  # group by the time we SIGKILL? No — a pid is not reusable while it is still in
  # use as a process-group id (Linux keeps the id live for as long as the group
  # has members, and the BSDs skip such pids when allocating). The loop below only
  # reaches the SIGKILL if the group has never once looked empty, so the group it
  # signals is necessarily the one the leader led.
  #
  # Never raises: this runs after the leader is already confirmed dead.
  # @return [Symbol] :skipped, :empty, :drained, :swept, :survived, or :error
  def sweep_process_group
    return :skipped unless sweepable_process_group?
    return :empty unless process_group_alive?

    deadline = monotonic_now + GROUP_DRAIN_GRACE_SECONDS
    while process_group_alive?
      break if monotonic_now >= deadline
      sleep GROUP_POLL_INTERVAL
    end
    return :drained unless process_group_alive?

    add_log(
      "Process group #{process_pid} still has members after SIGTERM; sweeping with SIGKILL",
      level: "info"
    )
    @process_manager.kill("KILL", -process_pid)

    confirm_deadline = monotonic_now + KILL_GRACE_SECONDS
    while process_group_alive?
      break if monotonic_now >= confirm_deadline
      sleep GROUP_POLL_INTERVAL
    end

    if process_group_alive?
      add_log("Process group #{process_pid} survived SIGKILL sweep", level: "warning")
      :survived
    else
      :swept
    end
  rescue Errno::ESRCH
    # Last member exited between the probe and the signal.
    :empty
  rescue Errno::EPERM => e
    add_log("Permission denied sweeping process group #{process_pid}: #{e.message}", level: "warning")
    :error
  rescue => e
    add_log("Error sweeping process group #{process_pid}: #{e.message}", level: "warning")
    :error
  end

  # Is `-process_pid` safe to signal as a process group?
  #
  # A pgid always equals the pid of its group leader, so `-process_pid` only ever
  # names a group the terminated process led. The guard is against the one case
  # where signalling it would be suicide: a pid that somehow matches OUR process
  # group would put the SIGKILL through this Ruby process (and every GoodJob
  # thread in it).
  def sweepable_process_group?
    return false unless process_pid.is_a?(Integer) && process_pid > 1

    process_pid != Process.getpgid(Process.pid)
  rescue SystemCallError
    # Cannot establish our own pgid — do not guess, do not sweep.
    false
  end

  # Does the leader's process group still have any member?
  # Signal 0 to a process group is the group-level equivalent of the individual
  # liveness probe: ESRCH means no member remains.
  def process_group_alive?
    @process_manager.kill(0, -process_pid)
    true
  rescue Errno::ESRCH
    false
  rescue Errno::EPERM
    # Members exist, we just may not signal them.
    true
  end

  # Reap the process to prevent zombies.
  #
  # This is now on the polling path rather than a one-shot at the end of the
  # ladder, so it wins the `waitpid` race against another thread waiting on the
  # same pid more often than it used to — concretely `ProcessLifecycleManager#
  # wait_nonblock` in the monitoring loop, when a *different* job terminates the
  # process it is watching (`SessionRecoveryService` on a hung session). That
  # thread then gets ECHILD, which it already rescues: it falls through to the
  # signal-0 detection path and the session still lands in `needs_input`.
  #
  # Collecting here is the point, not a side effect. This service is the one
  # asked to end this pid, `handle_exit`'s recovery branches are for a process
  # that died on its own rather than one we just killed, and the alternative is
  # the leak this fixes — nobody collects, the zombie survives, and the caller is
  # told the kill failed.
  #
  # @return [Array<Integer, Process::Status>, nil, Symbol] the wait2 result if the
  #   child had exited and was collected here, nil if it is our child and has NOT
  #   exited, or NOT_OUR_CHILD when waiting cannot answer the question.
  def reap_process
    return NOT_OUR_CHILD if @child_reaped

    result = @process_manager.wait(process_pid, Process::WNOHANG)
    @child_reaped = true if result
    result
  rescue Errno::ECHILD
    # Not our child, or somebody else already collected it. Either way `wait`
    # cannot answer the liveness question — the caller falls back to signal 0.
    NOT_OUR_CHILD
  rescue SystemCallError => e
    add_log("Error reaping process #{process_pid}: #{e.message}", level: "debug")
    NOT_OUR_CHILD
  end

  # Check if the process is still running.
  #
  # For a child WE spawned, `Process.kill(0, pid)` is not a liveness check: an
  # exited-but-unreaped child holds its pid as a zombie, so signal 0 keeps
  # succeeding for a process that is already dead. That is what made every step
  # of the ladder answer "still running" after a SIGTERM that had worked, burning
  # ~15-25s of sleeps and reporting :error for a successful kill (#280).
  #
  # A non-blocking wait answers it correctly and reaps as a side effect:
  #   - a result  => the child had exited; it is now collected and truly gone
  #   - nil       => it is our child and it has NOT exited; still running
  #   - ECHILD    => waiting cannot answer; fall back to signal 0, which is the
  #                  right (and only) answer for a process we did not spawn
  #
  # Once reaped, the pid is released back to the OS and could be recycled, so the
  # answer is memoized rather than re-probed with signal 0.
  def process_running?
    return false if @child_reaped

    case reap_process
    when NOT_OUR_CHILD
      @process_manager.running?(process_pid)
    when nil
      true
    else
      false
    end
  end

  def monotonic_now
    Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end

  # Add log entry
  # Uses log_buffer if available, otherwise creates log directly
  def add_log(content, level: "info")
    if @log_buffer
      @log_buffer.add(content, level: level)
    elsif @session
      with_db_retry do
        @session.logs.create!(content: content, level: level)
      end
    else
      # Log to Rails logger if no other option. Session log levels are not Logger
      # method names — "warning" is a Log level but `Rails.logger.warning` does not
      # exist, and calling it raises NoMethodError from inside the rescue-less
      # logging path. Map instead of trusting the string.
      Rails.logger.send(LOGGER_METHODS.fetch(level.to_s, :info), "[ProcessTerminationService] #{content}")
    end
  end
end
