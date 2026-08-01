# Service for terminating processes gracefully with fallback to force kill
#
# This service handles the termination of Claude CLI processes and their children:
# - Detects zombie processes and handles appropriately
# - Checks process ownership before attempting termination
# - Attempts graceful termination with SIGTERM (process group first, then individual)
# - Waits for process to exit
# - Falls back to SIGKILL if process doesn't exit
# - Returns structured results indicating success/failure reason
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
      return TerminationResult.new(status: :zombie_reaped, message: "Zombie process #{process_pid} reaped")
    end

    # Check if process is already dead
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
  # @return [TerminationResult] result of termination attempt
  def try_termination_strategies
    # Strategy 1: SIGTERM to process group
    result = try_signal_process_group("TERM")
    return result if result&.success?

    # If process group failed but process still exists, try individual process
    if process_running?
      # Strategy 2: SIGTERM to individual process
      result = try_signal_individual("TERM")
      return result if result&.success?
    else
      return TerminationResult.new(status: :terminated, message: "Process terminated after group signal")
    end

    # Wait for graceful shutdown
    wait_for_termination

    # Strategy 3: SIGKILL if still running
    if process_running?
      result = force_kill_if_needed
      return result if result
    end

    # Final check
    if process_running?
      TerminationResult.new(status: :error, message: "Process #{process_pid} could not be terminated")
    else
      # Reap to prevent zombie
      reap_process
      TerminationResult.new(status: :terminated, message: "Process #{process_pid} terminated")
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

  # Wait for the process to terminate gracefully
  def wait_for_termination
    max_wait = 30
    attempts = 0
    while process_running? && attempts < max_wait
      sleep 0.1
      attempts += 1
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
      wait_for_termination
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
      wait_for_termination
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

  # Reap the process to prevent zombies
  def reap_process
    @process_manager.wait(process_pid, Process::WNOHANG)
  rescue Errno::ECHILD
    # Already reaped
  end

  # Check if the process is still running
  def process_running?
    @process_manager.running?(process_pid)
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
      # Log to Rails logger if no other option
      Rails.logger.send(level, "[ProcessTerminationService] #{content}")
    end
  end
end
