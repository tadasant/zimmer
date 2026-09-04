# frozen_string_literal: true

# A stand-in for the delegated cgroup subtree `bin/docker-entrypoint` creates, so tests
# can exercise SessionMemoryCgroup without a writable cgroup2 filesystem — CI has none.
#
# A directory of ordinary files is a good stand-in, with two exceptions.
#
# `rmdir`: the kernel removes a cgroup directory along with the control files it shows,
# while `rmdir` on a tmpdir holding the same file names fails with ENOTEMPTY. Tests that
# care about removal build a bare directory rather than a populated one, and the real
# thing is verified on staging.
#
# Creation: the kernel creates a cgroup's interface files with the directory itself, so
# writing `memory.events` on real cgroupfs never adds a directory entry — here it does,
# and that moves the directory's ctime, which is what SessionMemoryCgroup#incarnation
# reads. So the rule for every test that reads an incarnation twice is that nothing may
# create a file in the directory in between, whether the creating write is the test's or
# #prepare!'s. Seed what the test needs first. #write_session_cgroup does its own writes
# before it returns, but it writes no `cgroup.procs` and skips `memory.max` when `limit:`
# is nil, so a test adding either of those later is still creating an entry (#820).
#
# Usage:
#   with_delegated_cgroup_parent do |parent|
#     write_session_cgroup(session.id, oom_kills: 1, peak: 4.gigabytes)
#     ...
#   end
module SessionMemoryCgroupHelpers
  # Point SessionMemoryCgroup at a throwaway parent for the duration of the block, and
  # restore whatever was there before — including "nothing", which is the state the rest
  # of the suite expects to find the env in. "Nothing" is not the same as "no cgroup":
  # a test that wants the bound *unavailable* names that with #without_delegated_cgroup_parent
  # rather than leaving the env unset and inheriting the host's.
  #
  # @yieldparam parent [String] the delegated parent's path
  def with_delegated_cgroup_parent
    original = ENV["ZIMMER_SESSION_CGROUP_ROOT"]
    Dir.mktmpdir("cgroupfs") do |tmp|
      parent = File.join(tmp, "zimmer.sessions")
      FileUtils.mkdir_p(parent)
      ENV["ZIMMER_SESSION_CGROUP_ROOT"] = parent
      yield parent
    end
  ensure
    original.nil? ? ENV.delete("ZIMMER_SESSION_CGROUP_ROOT") : ENV["ZIMMER_SESSION_CGROUP_ROOT"] = original
  end

  # The other half of the seam: point SessionMemoryCgroup at a parent that does not
  # exist, for a test of the unbounded path.
  #
  # Leaving the env unset does NOT do this. Unset falls through to DEFAULT_PARENT,
  # `/sys/fs/cgroup/zimmer.sessions`, which on a sysbox worker is a real delegated
  # subtree — the box Zimmer's own agent sessions run on is exactly such a box. A test
  # that only omits the stub therefore asserts "this host has no cgroupfs" rather than
  # "the unbounded path is a clean pass-through", passes on a laptop and in CI, and
  # fails on the worker (#902). Worse, it does not merely fail: `prepare!` succeeds, so
  # the run creates `session-<id>` cgroups in the live subtree next to real sessions.
  #
  # The tmpdir exists and its `zimmer.sessions` child deliberately does not, so the
  # path is absent, is unique per call, and cannot collide with anything on the host.
  def without_delegated_cgroup_parent
    original = ENV["ZIMMER_SESSION_CGROUP_ROOT"]
    Dir.mktmpdir("cgroupfs") do |tmp|
      ENV["ZIMMER_SESSION_CGROUP_ROOT"] = File.join(tmp, "zimmer.sessions")
      yield
    end
  ensure
    original.nil? ? ENV.delete("ZIMMER_SESSION_CGROUP_ROOT") : ENV["ZIMMER_SESSION_CGROUP_ROOT"] = original
  end

  # Write the control files the kernel would have written for one session's cgroup.
  #
  # Only the ones a test names: a `nil` is a file that is absent, which is a state the
  # readers have to survive (an older kernel has no `memory.peak`).
  #
  # @return [String] the cgroup's path
  def write_session_cgroup(session_id, oom_kills: nil, current: nil, peak: nil, limit: 4 * 1024 * 1024 * 1024)
    path = File.join(SessionMemoryCgroup.parent_path, "session-#{session_id}")
    FileUtils.mkdir_p(path)
    File.write(File.join(path, "memory.max"), limit.to_s) if limit
    File.write(File.join(path, "memory.current"), current.to_s) if current
    File.write(File.join(path, "memory.peak"), peak.to_s) if peak
    File.write(File.join(path, "memory.events"), "oom_kill #{oom_kills}\n") if oom_kills
    path
  end

  # Recreate a session's cgroup from scratch, the way a deploy or the sweep does.
  #
  # The point of it is the inode: SessionMemoryCgroup keys its "already reported" baseline
  # to the directory's incarnation, because `memory.events` restarts at zero here while
  # the recorded count lives in Postgres and does not.
  #
  # @return [String] the new cgroup's path
  def recreate_session_cgroup(session_id, **)
    path = File.join(SessionMemoryCgroup.parent_path, "session-#{session_id}")
    FileUtils.remove_entry(path) if File.directory?(path)
    write_session_cgroup(session_id, **)
  end
end
