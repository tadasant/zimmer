# frozen_string_literal: true

# ProcessDiagnostics provides detailed diagnostics for process operations.
# This service helps debug process-related issues by providing:
# - Process tree visualization
# - Detailed process state information
# - Child process enumeration
# - Permission and ownership analysis
#
# Features (Issue #326):
# - Process tree visualization for debugging
# - Detailed diagnostics when operations fail
# - Cross-platform support (macOS/Linux)
# - Safe command execution (no shell injection)
#
# Usage:
#   diagnostics = ProcessDiagnostics.new(pid)
#   diagnostics.full_report  # => detailed hash of process info
#   diagnostics.process_tree # => visual tree string
#   diagnostics.can_terminate? # => true/false
#
class ProcessDiagnostics
  attr_reader :pid

  # Diagnostic result struct for structured reporting
  DiagnosticResult = Struct.new(
    :exists,
    :state,
    :uid,
    :gid,
    :owner_name,
    :is_zombie,
    :owned_by_us,
    :can_terminate,
    :children,
    :parent_pid,
    :process_group,
    :command,
    :cpu_time,
    :start_time,
    :error,
    keyword_init: true
  ) do
    def to_h
      super.compact
    end
  end

  def initialize(pid)
    @pid = pid
  end

  # Get comprehensive diagnostics for the process
  # @return [DiagnosticResult] Full diagnostic information
  def full_report
    return DiagnosticResult.new(exists: false, error: "Invalid PID") unless valid_pid?

    info = fetch_process_info
    return DiagnosticResult.new(exists: false, error: info[:error]) if info[:error]

    children = fetch_child_processes

    DiagnosticResult.new(
      exists: info[:exists],
      state: info[:state],
      uid: info[:uid],
      gid: info[:gid],
      owner_name: info[:owner_name],
      is_zombie: info[:is_zombie],
      owned_by_us: info[:uid] == Process.uid,
      can_terminate: can_terminate_process?(info),
      children: children,
      parent_pid: info[:parent_pid],
      process_group: info[:process_group],
      command: info[:command],
      cpu_time: info[:cpu_time],
      start_time: info[:start_time]
    )
  end

  # Generate a visual process tree starting from this process
  # @param include_children [Boolean] Whether to include child processes
  # @return [String] Visual representation of the process tree
  def process_tree(include_children: true)
    return "Process #{pid} not found" unless process_exists?

    lines = []
    build_tree_lines(pid, lines, "", true, include_children)
    lines.join("\n")
  end

  # Check if we can terminate the process
  # @return [Boolean] true if we have permission to terminate
  def can_terminate?
    return false unless valid_pid?

    info = fetch_process_info
    can_terminate_process?(info)
  end

  # Get list of child PIDs
  # @return [Array<Integer>] Array of child process IDs
  def child_pids
    fetch_child_processes.map { |c| c[:pid] }
  end

  # Check if process exists
  # @return [Boolean] true if process exists
  def process_exists?
    return false unless valid_pid?

    Process.kill(0, pid)
    true
  rescue Errno::ESRCH
    false
  rescue Errno::EPERM
    true # Process exists but we can't signal it
  end

  # Check if process is a zombie
  # @return [Boolean] true if process is in zombie state
  def zombie?
    return false unless valid_pid?

    info = fetch_process_info
    info[:is_zombie] == true
  end

  # Get process state description
  # @return [String] Human-readable state description
  def state_description
    return "not found" unless process_exists?

    info = fetch_process_info
    return "unknown" unless info[:state]

    case info[:state]
    when /^R/ then "running"
    when /^S/ then "sleeping"
    when /^D/ then "uninterruptible sleep"
    when /^Z/ then "zombie"
    when /^T/ then "stopped"
    when /^I/ then "idle"
    else info[:state]
    end
  end

  private

  def valid_pid?
    pid.is_a?(Integer) && pid > 0
  end

  def fetch_process_info
    return { exists: false, error: "Invalid PID" } unless valid_pid?

    # Use ps command for cross-platform compatibility
    # Format: uid, gid, ppid, pgid, state, time, user, command
    output, status = Open3.capture2(
      "ps", "-o", "uid=,gid=,ppid=,pgid=,stat=,time=,user=,args=",
      "-p", pid.to_s
    )

    unless status.success? && output.strip.present?
      return { exists: false }
    end

    parse_ps_output(output.strip)
  rescue => e
    { exists: false, error: e.message }
  end

  def parse_ps_output(line)
    # Parse the ps output fields: uid, gid, ppid, pgid, stat, time, user, args
    # Use split with limit to handle commands containing spaces correctly
    parts = line.split(nil, 8)
    return { exists: false } if parts.length < 7

    {
      exists: true,
      uid: parts[0].to_i,
      gid: parts[1].to_i,
      parent_pid: parts[2].to_i,
      process_group: parts[3].to_i,
      state: parts[4],
      cpu_time: parts[5],
      owner_name: parts[6],
      command: parts[7] || "",
      is_zombie: parts[4].include?("Z")
    }
  end

  def fetch_child_processes
    # Use pgrep to find children (works on both macOS and Linux)
    output, status = Open3.capture2("pgrep", "-P", pid.to_s)

    return [] unless status.success?

    output.strip.split("\n").filter_map do |child_pid_str|
      child_pid = child_pid_str.to_i
      next unless child_pid > 0

      child_info = ProcessDiagnostics.new(child_pid).fetch_process_info
      next unless child_info[:exists]

      {
        pid: child_pid,
        command: child_info[:command],
        state: child_info[:state]
      }
    end
  rescue => e
    Rails.logger.debug { "Failed to fetch child processes: #{e.message}" }
    []
  end

  def can_terminate_process?(info)
    return false unless info[:exists]
    return true if info[:uid] == Process.uid
    return true if Process.uid == 0 # root can terminate anything

    false
  end

  def build_tree_lines(current_pid, lines, prefix, is_last, include_children)
    diag = ProcessDiagnostics.new(current_pid)
    info = diag.fetch_process_info

    connector = is_last ? "└── " : "├── "
    state_indicator = info[:is_zombie] ? "[Z]" : ""

    command = info[:command] || "unknown"
    command = command[0..50] + "..." if command.length > 50

    lines << "#{prefix}#{connector}#{current_pid} #{state_indicator}#{command}"

    return unless include_children

    children = diag.child_pids
    children.each_with_index do |child_pid, index|
      child_prefix = prefix + (is_last ? "    " : "│   ")
      is_child_last = index == children.length - 1
      build_tree_lines(child_pid, lines, child_prefix, is_child_last, true)
    end
  end

  # Make fetch_process_info accessible from other ProcessDiagnostics instances.
  # This is needed for process_tree building where we recursively create new
  # ProcessDiagnostics instances for child processes and need to call their
  # fetch_process_info method.
  protected :fetch_process_info
end
