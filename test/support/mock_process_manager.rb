# Mock implementation of ProcessManager for testing
# This allows tests to simulate process behavior without spawning real processes.
#
# Enhanced capabilities (Issue #326):
# - Mock implementation of spawn_with_tracking for ownership tracking
# - Mock implementation of kill_process_group for process group termination
# - Mock process registry for tracking spawned processes
# - Support for correlation IDs in tests
#
# Usage in tests:
#   manager = MockProcessManager.new
#   manager.spawn_hook = ->(cmd, opts) { ... }  # Optional: customize spawn behavior
#   pid = manager.spawn(["echo", "hello"])
#   manager.spawned_processes  # => [{ pid: 10000, command: ["echo", "hello"], options: {} }]
#   manager.kill("TERM", pid)
#   manager.killed_processes  # => [{ signal: "TERM", pid: 10000 }]
#
# To simulate specific process states:
#   manager.set_process_state(pid, :zombie)  # Make process appear as zombie
#   manager.set_process_state(pid, :running) # Normal running state
#   manager.set_process_uid(pid, 0)          # Make process owned by root
#
# For tracking tests:
#   pid = manager.spawn_with_tracking(["claude"], correlation_id: "abc123")
#   info = manager.get_tracked_process(pid)
#   info[:correlation_id]  # => "abc123"
class MockProcessManager < ProcessManager
  attr_accessor :spawn_hook, :wait_hook, :kill_hook, :getpgid_hook, :running_hook, :kill_group_hook
  attr_reader :spawned_processes, :killed_processes, :registry

  def initialize
    @spawned_processes = []
    @killed_processes = []
    # Start mock PIDs at 10000 to avoid conflicts with real system PIDs during tests
    @next_pid = 10000
    @process_states = {}  # pid => :running, :zombie, :dead
    @process_uids = {}    # pid => uid
    @process_gids = {}    # pid => gid
    @registry = ProcessRegistry.new
  end

  # Set the state of a process for testing
  # @param pid [Integer] The process ID
  # @param state [Symbol] :running, :zombie, or :dead
  def set_process_state(pid, state)
    @process_states[pid] = state
  end

  # Set the UID of a process for testing
  # @param pid [Integer] The process ID
  # @param uid [Integer] The user ID
  def set_process_uid(pid, uid)
    @process_uids[pid] = uid
  end

  # Set the GID of a process for testing
  # @param pid [Integer] The process ID
  # @param gid [Integer] The group ID
  def set_process_gid(pid, gid)
    @process_gids[pid] = gid
  end

  # Get mock process info (called by tests, not by the service directly)
  # @param pid [Integer] The process ID
  # @return [Hash] process info
  def mock_process_info(pid)
    state = @process_states[pid] || (running?(pid) ? :running : :dead)
    uid = @process_uids[pid] || Process.uid
    gid = @process_gids[pid] || Process.gid

    {
      exists: state != :dead && (running?(pid) || state == :zombie),
      is_zombie: state == :zombie,
      owned_by_us: uid == Process.uid,
      uid: uid,
      gid: gid,
      state: state == :zombie ? "Z" : (state == :running ? "S" : nil)
    }
  end

  # Simulate spawning a process
  # Handles both forms:
  #   spawn(*command, **options)
  #   spawn(env, *command, **options)
  # @param args [Array] Command arguments (or env hash + command)
  # @param options [Hash] Options that would be passed to Process.spawn
  # @return [Integer] A mock process ID
  def spawn(*args, **options)
    pid = @next_pid
    @next_pid += 1

    # Check if first arg is an env hash (when env vars are provided)
    # Process.spawn accepts: spawn([env,] command, [options])
    # Note: We treat any Hash as env, including empty ones, matching Process.spawn behavior
    env = {}
    command = args

    if args.first.is_a?(Hash)
      env = args.first
      command = args[1..-1]
    end

    @spawned_processes << { pid: pid, command: command, options: options, env: env }
    spawn_hook&.call(args, options) if spawn_hook
    pid
  end

  # Simulate spawning a process with ownership tracking
  # @param args [Array] Command and arguments to execute
  # @param options [Hash] Options to pass to Process.spawn
  # @param correlation_id [String, nil] Optional correlation ID for tracking
  # @return [Integer] A mock process ID
  def spawn_with_tracking(*args, correlation_id: nil, **options)
    pid = spawn(*args, **options)

    # Track in registry with ownership info
    working_dir = options[:chdir]
    # Determine process group (see SystemProcessManager for full documentation)
    process_group = case options[:pgroup]
    when true then pid
    when Integer then options[:pgroup]
    else pid
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

    pid
  end

  # Simulate waiting for a process
  # @param pid [Integer] The process ID to wait for
  # @param flags [Integer] Flags (e.g., Process::WNOHANG)
  # @return [Array<Integer, MockStatus>, nil] Returns mock status or nil
  def wait(pid, flags = 0)
    if wait_hook
      result = wait_hook.call(pid, flags)
      @registry.unregister(pid) if result
      result
    else
      # Default behavior: return a successful status and unregister
      @registry.unregister(pid)
      [ pid, MockStatus.new(0) ]
    end
  end

  # Simulate killing a process
  # @param signal [String, Integer] The signal to send
  # @param pid [Integer] The process ID to signal
  # @return [Integer] Returns 1 (number of processes signaled)
  def kill(signal, pid)
    @killed_processes << { signal: signal, pid: pid }
    kill_hook&.call(signal, pid) if kill_hook
    1
  end

  # Simulate killing a process group
  # @param signal [String, Integer] The signal to send
  # @param pgid [Integer] The process group ID to signal (positive value)
  # @return [Integer] Returns 1 (number of processes signaled)
  # @raise [Errno::ESRCH] if the process group does not exist (when hook raises)
  # @raise [Errno::EPERM] if permission is denied (when hook raises)
  def kill_process_group(signal, pgid)
    @killed_processes << { signal: signal, pid: -pgid.abs, type: :group }
    kill_group_hook&.call(signal, pgid) if kill_group_hook
    1
  end

  # Check if a process is running
  # @param pid [Integer] The process ID to check
  # @return [Boolean] true if spawned and not killed, false otherwise
  def running?(pid)
    # Allow override via hook for fine-grained control in tests
    return running_hook.call(pid) if running_hook

    # Check if process state was explicitly set
    state = @process_states[pid]
    return false if state == :dead
    return true if state == :zombie || state == :running

    # Default behavior: check spawned/killed lists
    spawned = @spawned_processes.any? { |p| p[:pid] == pid }
    killed = @killed_processes.any? { |p| p[:pid] == pid && p[:signal] != 0 }
    spawned && !killed
  end

  # Get the process group ID (mock implementation)
  # @param pid [Integer] The process ID to query
  # @return [Integer] The process group ID (returns the pid itself for mock purposes)
  # @raise [Errno::ESRCH] if the process does not exist
  def getpgid(pid)
    if getpgid_hook
      getpgid_hook.call(pid)
    else
      raise Errno::ESRCH unless running?(pid)
      # For mock purposes, return the pid itself as the pgid
      # In real scenarios, processes can be in different process groups
      pid
    end
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

  # Mock Process::Status for testing
  # Provides a simple interface that mimics Process::Status behavior
  #
  # Supports two exit modes:
  # 1. Normal exit: initialize with exitstatus (e.g., MockStatus.new(0) for success)
  # 2. Signal termination: use MockStatus.signaled(15) for SIGTERM, etc.
  #
  # This mimics Ruby's Process::Status behavior:
  # - Normal exit: exitstatus returns the code, termsig returns nil, signaled? returns false
  # - Signal termination: exitstatus returns nil, termsig returns signal number, signaled? returns true
  class MockStatus
    attr_reader :exitstatus, :termsig

    def initialize(exitstatus = 0, termsig: nil)
      @exitstatus = exitstatus
      @termsig = termsig
    end

    # Factory method to create a status representing signal termination
    # @param signal [Integer] The signal number (e.g., 15 for SIGTERM)
    # @return [MockStatus] A status with signaled? == true and termsig == signal
    def self.signaled(signal)
      new(nil, termsig: signal)
    end

    def success?
      @exitstatus == 0
    end

    def signaled?
      !@termsig.nil?
    end

    # Simplified implementation of to_i - matches Unix convention of exit code in high byte
    # Real Process::Status has more complex bit packing for signals and other flags
    def to_i
      @exitstatus || 0
    end
  end
end
