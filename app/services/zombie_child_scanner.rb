# frozen_string_literal: true

require "open3"

# Enumerates the process table so ZombieReaperJob can name the specific pids it is
# about to reap instead of reaping whatever `waitpid(-1)` happens to hand back.
#
# Two questions are answered from a single `ps` snapshot:
#   * which pids exist at all (used to prune stale ChildWaiterRegistry claims)
#   * which of *our* direct children are zombies (the reap candidates)
#
# `ps` rather than `/proc` because it is the idiom already used for this question
# elsewhere in the app (ProcessTerminationService#process_info,
# ProcessDiagnostics) and because it works on macOS dev machines as well as the
# Linux production container. The `ps` child itself is reaped by Open3's wait
# thread, and pid reuse cannot confuse the caller: a zombie occupies its pid until
# it is reaped, so a pid observed as a zombie still refers to the same dead child
# when the reaper waits on it.
class ZombieChildScanner
  # A parsed view of the process table.
  Snapshot = Struct.new(:pids, :zombie_child_pids, keyword_init: true)

  # ps fields: pid, parent pid, state. Trailing "=" suppresses the header on both
  # Linux (procps) and macOS (BSD ps).
  PS_ARGS = %w[ps -eo pid=,ppid=,stat=].freeze

  attr_reader :parent_pid

  # @param parent_pid [Integer] whose children count as "ours"
  # @param ps_runner [#call, nil] returns [stdout, success_boolean]; injectable for tests
  def initialize(parent_pid: Process.pid, ps_runner: nil)
    @parent_pid = parent_pid
    @ps_runner = ps_runner || method(:run_ps)
  end

  # @return [Snapshot, nil] nil when the process table could not be read, which
  #   the caller must treat as "reap nothing" rather than "nothing to reap".
  def snapshot
    output, ok = @ps_runner.call
    return nil unless ok && output

    pids = []
    zombies = []

    output.each_line do |line|
      pid, ppid, state = line.split(nil, 3)
      next unless pid&.match?(/\A\d+\z/)

      pid = pid.to_i
      pids << pid
      zombies << pid if state.to_s.start_with?("Z") && ppid.to_i == parent_pid
    end

    Snapshot.new(pids: pids, zombie_child_pids: zombies)
  end

  private

  def run_ps
    stdout, _stderr, status = Open3.capture3(*PS_ARGS)
    # `status` is nil when Open3's wait thread lost the child's exit status to
    # another reaper. Nothing in this process reaps blindly any more, so that
    # should not happen — but a nil status is still not a "ps succeeded", and
    # acting on a half-read process table means reaping the wrong pid.
    [ stdout, SubprocessStatus.success?(status) ]
  rescue StandardError => e
    Rails.logger.warn "[ZombieChildScanner] Could not read the process table: #{e.class}: #{e.message}"
    [ nil, false ]
  end
end
