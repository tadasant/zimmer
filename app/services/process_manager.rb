# Base interface for process lifecycle management
# This abstraction allows for testable process management by providing
# a common interface that can be implemented by both real (SystemProcessManager)
# and mock (MockProcessManager) implementations.
#
# This follows the dependency injection pattern and makes it easier to:
# - Test process-related code without spawning real processes
# - Simulate process failures and edge cases
# - Isolate business logic from OS process APIs
#
# Enhanced capabilities (Issue #326):
# - Track process ownership (UID/GID) when spawning
# - Support process group management for reliable termination
# - Provide detailed diagnostics when operations fail
# - Log all process operations with correlation IDs
class ProcessManager
  # Spawn a new process with the given command and options
  # @param args [Array] Command and arguments to execute
  # @param options [Hash] Options to pass to Process.spawn (e.g., chdir, pgroup, out, err)
  # @return [Integer] The process ID (PID)
  def spawn(*args, **options)
    raise NotImplementedError, "#{self.class} must implement #spawn"
  end

  # Spawn a new process with ownership tracking
  # @param args [Array] Command and arguments to execute
  # @param options [Hash] Options to pass to Process.spawn
  # @param correlation_id [String, nil] Optional correlation ID for tracking
  # @return [Integer] The process ID (PID)
  def spawn_with_tracking(*args, correlation_id: nil, **options)
    raise NotImplementedError, "#{self.class} must implement #spawn_with_tracking"
  end

  # Wait for a process to complete or check its status
  # @param pid [Integer] The process ID to wait for
  # @param flags [Integer] Flags to pass to Process.wait2 (e.g., Process::WNOHANG)
  # @return [Array<Integer, Process::Status>, nil] Returns [pid, status] if process finished, nil if still running
  def wait(pid, flags = 0)
    raise NotImplementedError, "#{self.class} must implement #wait"
  end

  # Send a signal to a process
  # @param signal [String, Integer] The signal to send (e.g., "TERM", "KILL", 0)
  # @param pid [Integer] The process ID to signal
  # @return [Integer] The number of processes signaled (usually 1)
  def kill(signal, pid)
    raise NotImplementedError, "#{self.class} must implement #kill"
  end

  # Send a signal to a process group
  # @param signal [String, Integer] The signal to send (e.g., "TERM", "KILL")
  # @param pgid [Integer] The process group ID to signal (positive value)
  # @return [Integer] The number of processes signaled
  # @raise [Errno::ESRCH] if the process group does not exist
  # @raise [Errno::EPERM] if permission is denied
  def kill_process_group(signal, pgid)
    raise NotImplementedError, "#{self.class} must implement #kill_process_group"
  end

  # Check if a process is running
  # @param pid [Integer] The process ID to check
  # @return [Boolean] true if the process is running, false otherwise
  def running?(pid)
    raise NotImplementedError, "#{self.class} must implement #running?"
  end

  # Get the process group ID of a process
  # @param pid [Integer] The process ID to query
  # @return [Integer] The process group ID
  # @raise [Errno::ESRCH] if the process does not exist
  def getpgid(pid)
    raise NotImplementedError, "#{self.class} must implement #getpgid"
  end

  # Get tracked information about a spawned process
  # @param pid [Integer] The process ID to query
  # @return [Hash, nil] Process tracking info or nil if not tracked
  def get_tracked_process(pid)
    raise NotImplementedError, "#{self.class} must implement #get_tracked_process"
  end

  # Get all tracked processes
  # @return [Hash<Integer, Hash>] Map of PID to process info
  def tracked_processes
    raise NotImplementedError, "#{self.class} must implement #tracked_processes"
  end

  # Untrack a process (call when process terminates)
  # @param pid [Integer] The process ID to untrack
  # @return [Hash, nil] The removed process info or nil
  def untrack_process(pid)
    raise NotImplementedError, "#{self.class} must implement #untrack_process"
  end
end
