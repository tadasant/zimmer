# frozen_string_literal: true

require "open3"

# Runs a subprocess under a hard wall-clock timeout, killing the entire process
# group on deadline.
#
# Shared by the two places Zimmer shells out to git over the network on the
# `waiting → running` launch path:
#   - GitCloneService (clones the session's working directory)
#   - AirPrepareService (runs `air prepare`, which itself shells out to
#     `git clone` for the catalog repo)
#
# Both run synchronously inside AgentSessionJob *before* the session transitions
# to `running`, so a stalled clone — e.g. a half-open HTTPS connection during
# fetch-pack that never sends a TCP reset — would block the calling thread and
# wedge the session in `waiting` forever with no output and no recovery (the
# GoodJob job keeps its advisory lock, so it still looks "alive" to orphan
# detection). The watchdog bounds that.
#
# The child is started as its own process-group leader (pgroup: true) so that on
# timeout we SIGKILL the whole group — git/npm spawn helper processes
# (git-remote-https, index-pack, …) that must die too, not just the parent.
# stdout/stderr are drained via an IO.select loop bounded by the deadline so a
# chatty child can't deadlock on a full pipe buffer.
module BoundedSubprocess
  # Raised when a subprocess exceeds its timeout and the process group is killed.
  class TimeoutError < StandardError; end

  module_function

  # @param command_array [Array<String>] argv (no shell — pass args explicitly)
  # @param env [Hash] extra environment for the child
  # @param cwd [String, nil] working directory for the child
  # @param timeout [Numeric] wall-clock seconds before the process group is killed
  # @return [Array(String, String, Process::Status)] stdout, stderr, status
  # @raise [TimeoutError] if the deadline is exceeded
  def run(command_array, timeout:, env: {}, cwd: nil)
    spawn_opts = { pgroup: true }
    spawn_opts[:chdir] = cwd if cwd

    Open3.popen3(env, *command_array, spawn_opts) do |stdin, stdout, stderr, wait_thr|
      stdin.close
      out = +""
      err = +""
      buffers = { stdout => out, stderr => err }
      deadline = monotonic_now + timeout

      until buffers.empty?
        remaining = deadline - monotonic_now
        if remaining <= 0
          terminate_process_group(wait_thr.pid)
          wait_thr.value # reap the killed child so it does not linger as a zombie
          raise TimeoutError,
            "command timed out after #{timeout}s (process group killed): #{command_array.join(' ')}"
        end

        ready, = IO.select(buffers.keys, nil, nil, remaining)
        next if ready.nil? # select timed out; loop re-evaluates the deadline

        ready.each do |io|
          buffers[io] << io.readpartial(65_536)
        rescue EOFError
          io.close
          buffers.delete(io)
        end
      end

      [ out, err, wait_thr.value ]
    end
  end

  # SIGKILL an entire process group (negative pid). Best-effort: the process may
  # already have exited, or we may lack permission, in which case we fall back to
  # killing just the leader.
  def terminate_process_group(pid)
    Process.kill("KILL", -Process.getpgid(pid))
  rescue Errno::ESRCH, Errno::EPERM
    begin
      Process.kill("KILL", pid)
    rescue Errno::ESRCH
      # already gone
    end
  end

  def monotonic_now
    Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end
end
