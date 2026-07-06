# Real implementation of ProcessManager using Ruby's Process module
# This is the production implementation that spawns and manages actual OS processes.
#
# Enhanced capabilities (Issue #326):
# - Track process ownership (UID/GID) when spawning via ProcessRegistry
# - Support process group management for reliable termination
# - Provide detailed diagnostics when operations fail via ProcessDiagnostics
# - Log all process operations with correlation IDs
#
# Usage:
#   manager = SystemProcessManager.new
#   pid = manager.spawn(["echo", "hello"], out: "/tmp/output.txt")
#   pid = manager.spawn_with_tracking(["claude"], correlation_id: "abc123", pgroup: true)
#   pid, status = manager.wait(pid)
#   manager.kill("TERM", pid)
#   manager.kill_process_group("TERM", pgid)
#   info = manager.get_tracked_process(pid)
class SystemProcessManager < ProcessManager
  attr_reader :registry

  def initialize(registry: nil, logger: nil)
    @registry = registry || ProcessRegistry.new
    @logger = logger || StructuredLogger.new({ service: "SystemProcessManager" })
  end

  # Spawn a new process using Process.spawn
  # @param args [Array] Command and options to pass to Process.spawn
  # @return [Integer] The process ID (PID)
  def spawn(*args, **options)
    Process.spawn(*args, **options)
  end

  # Spawn a new process with ownership tracking
  # @param args [Array] Command and arguments to execute
  # @param options [Hash] Options to pass to Process.spawn
  # @param correlation_id [String, nil] Optional correlation ID for tracking
  # @return [Integer] The process ID (PID)
  def spawn_with_tracking(*args, correlation_id: nil, **options)
    pid = Process.spawn(*args, **options)

    # Track the process with ownership information
    working_dir = options[:chdir]
    # Determine process group:
    # - pgroup: true means create new process group with pid as leader
    # - pgroup: <integer> means join that process group
    # - pgroup: false or nil means inherit parent's process group (use pid as fallback for tracking)
    process_group = case options[:pgroup]
    when true then pid
    when Integer then options[:pgroup]
    else pid # Default to pid for tracking purposes
    end

    @registry.register(
      pid,
      uid: Process.uid,
      gid: Process.gid,
      command: args,
      correlation_id: correlation_id,
      working_directory: working_dir,
      process_group: process_group
    )

    log_operation(:spawn, pid, correlation_id: correlation_id, command: args.first)

    pid
  end

  # Wait for a process to complete or check its status using Process.wait2
  # @param pid [Integer] The process ID to wait for
  # @param flags [Integer] Flags to pass to Process.wait2 (e.g., Process::WNOHANG)
  # @return [Array<Integer, Process::Status>, nil] Returns [pid, status] if process finished, nil if still running
  def wait(pid, flags = 0)
    result = Process.wait2(pid, flags)

    # If process completed, untrack it
    if result
      @registry.unregister(pid)
      log_operation(:wait_completed, pid, exit_status: result[1]&.exitstatus)
    end

    result
  end

  # Send a signal to a process using Process.kill
  # @param signal [String, Integer] The signal to send (e.g., "TERM", "KILL", 0)
  # @param pid [Integer] The process ID to signal
  # @return [Integer] The number of processes signaled (usually 1)
  def kill(signal, pid)
    result = Process.kill(signal, pid)
    log_operation(:kill, pid, signal: signal) unless signal == 0
    result
  rescue Errno::ESRCH => e
    log_operation(:kill_failed, pid, signal: signal, error: "Process not found")
    raise
  rescue Errno::EPERM => e
    log_operation(:kill_failed, pid, signal: signal, error: "Permission denied")
    raise
  end

  # Send a signal to a process group
  # @param signal [String, Integer] The signal to send (e.g., "TERM", "KILL")
  # @param pgid [Integer] The process group ID to signal (positive value)
  # @return [Integer] The number of processes signaled
  # @raise [Errno::ESRCH] if the process group does not exist
  # @raise [Errno::EPERM] if permission is denied
  def kill_process_group(signal, pgid)
    result = Process.kill(signal, -pgid.abs)
    log_operation(:kill_group, pgid, signal: signal)
    result
  rescue Errno::ESRCH => e
    log_operation(:kill_group_failed, pgid, signal: signal, error: "Process group not found")
    raise
  rescue Errno::EPERM => e
    log_operation(:kill_group_failed, pgid, signal: signal, error: "Permission denied")
    raise
  end

  # Check if a process is running by sending signal 0
  # Signal 0 is a special signal that doesn't actually send a signal,
  # but checks if the process exists and we have permission to signal it.
  # @param pid [Integer] The process ID to check
  # @return [Boolean] true if the process is running, false otherwise
  def running?(pid)
    return false unless pid

    Process.kill(0, pid)
    true
  rescue Errno::ESRCH
    # Process not found
    false
  rescue Errno::EPERM
    # Process exists but we don't have permission to signal it
    # This still means the process is running
    true
  end

  # Get the process group ID using Process.getpgid
  # @param pid [Integer] The process ID to query
  # @return [Integer] The process group ID
  # @raise [Errno::ESRCH] if the process does not exist
  def getpgid(pid)
    Process.getpgid(pid)
  end

  # Get tracked information about a spawned process
  # @param pid [Integer] The process ID to query
  # @return [Hash, nil] Process tracking info or nil if not tracked
  def get_tracked_process(pid)
    info = @registry.get(pid)
    info&.to_h
  end

  # Get all tracked processes
  # @return [Hash<Integer, Hash>] Map of PID to process info
  def tracked_processes
    @registry.all.transform_values(&:to_h)
  end

  # Untrack a process (call when process terminates)
  # @param pid [Integer] The process ID to untrack
  # @return [Hash, nil] The removed process info or nil
  def untrack_process(pid)
    info = @registry.unregister(pid)
    info&.to_h
  end

  # Get detailed diagnostics for a process
  # @param pid [Integer] The process ID
  # @return [ProcessDiagnostics::DiagnosticResult] Detailed diagnostics
  def diagnostics(pid)
    ProcessDiagnostics.new(pid).full_report
  end

  # Get process tree visualization
  # @param pid [Integer] The process ID
  # @return [String] Visual tree representation
  def process_tree(pid)
    ProcessDiagnostics.new(pid).process_tree
  end

  private

  def log_operation(operation, pid, **details)
    return unless log_operations_enabled?

    tracked = @registry.get(pid)
    correlation_id = details[:correlation_id] || tracked&.correlation_id

    message = "Process #{operation}: pid=#{pid}"
    context = details.merge(correlation_id: correlation_id).compact

    @logger.debug(message, context)
  end

  def log_operations_enabled?
    return @log_operations_enabled if defined?(@log_operations_enabled)

    @log_operations_enabled = Rails.application.config.process_manager.log_operations
  rescue StandardError
    # Config not available (e.g., during early boot or in tests)
    false
  end
end
