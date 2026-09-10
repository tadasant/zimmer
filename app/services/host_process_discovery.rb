# frozen_string_literal: true

require "open3"

# The one place Zimmer asks the HOST which agent CLI processes are alive: a `pgrep`
# over the current user's processes, from which HealthMonitorService derives its
# `active_count` and — after cross-referencing against the sessions table — the
# orphan list that `cleanup_orphaned_processes` terminates.
#
# It is its own object rather than a private method on the health service because
# the answer it gives is a fact about the machine, not about the database, and the
# two are only allowed to meet in a real deployment. A test process runs against a
# test database whose fixtures name no real pid, so a host scan from inside one
# classifies EVERY live agent process the same uid owns as orphaned and kills it —
# which is what happened three times over in #1095, each time taking down the
# session that ran the test. HealthMonitorService therefore reads
# `config.x.host_process_discovery` to decide whether to build this class or
# `HostProcessDiscovery::None`; `config/environments/test.rb` sets `:none`, and a
# test that genuinely wants the scanner constructs one and injects it.
#
# Security: `-u` restricts the scan to the current user's processes.
class HostProcessDiscovery
  # The discovery that sees nothing. HealthMonitorService#process_health already
  # copes with an empty scan: whenever a session records an agent process this
  # process cannot probe, it reports the count as not observable from here rather
  # than as zero orphans.
  class None
    def claude_processes
      []
    end
  end

  def initialize(process_manager:, logger:)
    @process_manager = process_manager
    @logger = logger
  end

  # @return [Array<Hash>] one `{ pid:, command:, running: }` per Claude CLI process
  #   the current user owns, excluding this process
  def claude_processes
    pgrep_output.each_line.filter_map do |line|
      parts = line.strip.split(/\s+/, 2)
      next if parts.size < 2

      pid = parts[0].to_i
      command = parts[1]

      # Skip if this is our own process
      next if pid == Process.pid
      # Only match processes that look like the actual Claude CLI
      next unless command.match?(/\bclaude\b/)

      { pid: pid, command: command, running: @process_manager.running?(pid) }
    end
  rescue => e
    # An incomplete scan is no scan: a partial list would feed the orphan check a
    # subset that says nothing about the processes it never reached.
    @logger.error("Failed to find active processes", error: e.message)
    []
  end

  private

  # The host call itself, on its own so a test of the parser above can stub this
  # one instance rather than `Open3` for the whole process.
  def pgrep_output
    output, _status = Open3.capture2("pgrep", "-fl", "-u", Process.uid.to_s, "claude")
    output
  end
end
