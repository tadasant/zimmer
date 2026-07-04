# frozen_string_literal: true

# ProcessRegistry maintains a thread-safe registry of spawned processes with ownership information.
# This enables tracking process ownership (UID/GID), correlation IDs, and provides
# diagnostics when operations fail.
#
# Features (Issue #326):
# - Track process owner UID/GID when spawning
# - Store correlation IDs for log correlation
# - Record spawn time and command for debugging
# - Thread-safe access via Mutex
# - Automatic cleanup of terminated processes
#
# Usage:
#   registry = ProcessRegistry.new
#   registry.register(pid, uid: Process.uid, gid: Process.gid, command: "claude", correlation_id: "abc123")
#   info = registry.get(pid)
#   registry.unregister(pid)
#
class ProcessRegistry
  # Information tracked for each process
  ProcessInfo = Struct.new(
    :pid,
    :uid,
    :gid,
    :command,
    :correlation_id,
    :spawned_at,
    :working_directory,
    :process_group,
    keyword_init: true
  ) do
    def to_h
      {
        pid: pid,
        uid: uid,
        gid: gid,
        command: command,
        correlation_id: correlation_id,
        spawned_at: spawned_at,
        working_directory: working_directory,
        process_group: process_group
      }
    end

    def owned_by?(uid)
      self.uid == uid
    end

    def age_seconds
      Time.current - spawned_at
    end
  end

  def initialize
    @processes = {}
    @mutex = Mutex.new
  end

  # Register a new process in the registry
  # @param pid [Integer] The process ID
  # @param uid [Integer] The owner's user ID (defaults to current user)
  # @param gid [Integer] The owner's group ID (defaults to current group)
  # @param command [String, Array] The command that was executed
  # @param correlation_id [String, nil] Optional correlation ID for log tracking
  # @param working_directory [String, nil] The working directory for the process
  # @param process_group [Integer, nil] The process group ID (defaults to pid)
  # @return [ProcessInfo] The registered process info
  def register(pid, uid: nil, gid: nil, command: nil, correlation_id: nil, working_directory: nil, process_group: nil)
    info = ProcessInfo.new(
      pid: pid,
      uid: uid || Process.uid,
      gid: gid || Process.gid,
      command: normalize_command(command),
      correlation_id: correlation_id || generate_correlation_id,
      spawned_at: Time.current,
      working_directory: working_directory,
      process_group: process_group || pid
    )

    @mutex.synchronize do
      @processes[pid] = info
    end

    info
  end

  # Get process info by PID
  # @param pid [Integer] The process ID
  # @return [ProcessInfo, nil] The process info or nil if not found
  def get(pid)
    @mutex.synchronize do
      @processes[pid]
    end
  end

  # Remove a process from the registry
  # @param pid [Integer] The process ID
  # @return [ProcessInfo, nil] The removed process info or nil if not found
  def unregister(pid)
    @mutex.synchronize do
      @processes.delete(pid)
    end
  end

  # Get all registered processes
  # @return [Hash<Integer, ProcessInfo>] Map of PID to process info
  def all
    @mutex.synchronize do
      @processes.dup
    end
  end

  # Get count of registered processes
  # @return [Integer] Number of tracked processes
  def count
    @mutex.synchronize do
      @processes.size
    end
  end

  # Check if a process is registered
  # @param pid [Integer] The process ID
  # @return [Boolean] true if the process is registered
  def registered?(pid)
    @mutex.synchronize do
      @processes.key?(pid)
    end
  end

  # Get all processes owned by a specific user
  # @param uid [Integer] The user ID
  # @return [Array<ProcessInfo>] Array of process info owned by the user
  def owned_by(uid)
    @mutex.synchronize do
      @processes.values.select { |info| info.uid == uid }
    end
  end

  # Get all processes with a specific correlation ID
  # @param correlation_id [String] The correlation ID
  # @return [Array<ProcessInfo>] Array of matching process info
  def by_correlation_id(correlation_id)
    @mutex.synchronize do
      @processes.values.select { |info| info.correlation_id == correlation_id }
    end
  end

  # Clear all registered processes
  # @return [Integer] Number of processes that were cleared
  def clear
    @mutex.synchronize do
      count = @processes.size
      @processes.clear
      count
    end
  end

  # Get processes older than a specified age
  # @param seconds [Integer] Age threshold in seconds
  # @return [Array<ProcessInfo>] Array of processes older than threshold
  def older_than(seconds)
    threshold = Time.current - seconds
    @mutex.synchronize do
      @processes.values.select { |info| info.spawned_at < threshold }
    end
  end

  private

  def normalize_command(command)
    case command
    when Array
      command.join(" ")
    when String
      command
    else
      command.to_s
    end
  end

  def generate_correlation_id
    SecureRandom.uuid
  end
end
