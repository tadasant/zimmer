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
# Two variables decide `SessionMemoryCgroup.available?`, so a test that stubs only one
# is still reading the other off the host. Every helper here sets both. See
# #stub_cgroup_env! for what the second one is and why leaving it alone is not safe.
#
# Usage:
#   with_delegated_cgroup_parent do |parent|
#     write_session_cgroup(session.id, oom_kills: 1, peak: 4.gigabytes)
#     ...
#   end
#
#   without_delegated_cgroup_parent { ... }   # the unbounded path
#   pin_delegated_cgroup_parent_absent        # ... for a whole test class
module SessionMemoryCgroupHelpers
  extend ActiveSupport::Concern

  # A bound that is present and non-zero, pinned so that availability is a function of
  # the stubbed parent alone. The value itself is never asserted on; it just has to be
  # neither absent nor the break-glass zero.
  PINNED_LIMIT_MB = "4096"

  ROOT_VAR = "ZIMMER_SESSION_CGROUP_ROOT"
  LIMIT_VAR = "ZIMMER_SESSION_MEMORY_MAX_MB"

  class_methods do
    # Point every test in this class at a delegated parent that does not exist.
    #
    # The block form below can only wrap a line the test itself writes. This is for the
    # case it cannot reach: a subject that touches cgroups somewhere inside a call the
    # test makes for another reason. ZombieReaperJob is the sharp one — #perform sweeps
    # cgroups as its first statement, before every early return, so all 13 of its tests
    # that call `perform_now` for reasons having nothing to do with memory would
    # otherwise sweep the host's real subtree, with the *test* database as the liveness
    # oracle. It holds no real session ids, so every real cgroup reads as dead and the
    # empty ones — an idle session between turns is empty, and normal — get `rmdir`'d,
    # resetting the `memory.peak` and OOM counters of live sessions. Declaring it once
    # at the top of the class is cheaper than remembering it at 13 call sites.
    def pin_delegated_cgroup_parent_absent
      setup do
        @delegated_cgroup_tmp = Dir.mktmpdir("cgroupfs")
        @delegated_cgroup_env = stub_cgroup_env!(root: File.join(@delegated_cgroup_tmp, "zimmer.sessions"))
      end

      teardown do
        restore_cgroup_env!(@delegated_cgroup_env) if @delegated_cgroup_env
        FileUtils.rm_rf(@delegated_cgroup_tmp) if @delegated_cgroup_tmp
      end
    end
  end

  # Point SessionMemoryCgroup at a throwaway parent for the duration of the block, and
  # restore whatever was there before — including "nothing", which is the state the rest
  # of the suite expects to find the env in. "Nothing" is not the same as "no cgroup":
  # a test that wants the bound *unavailable* names that with #without_delegated_cgroup_parent
  # rather than leaving the env unset and inheriting the host's.
  #
  # The yielded path is the POOL — `<root>/sessions` — because that is where session
  # cgroups live and what every caller asserts about. The root itself holds the pool and
  # the `app` sibling, and the app never creates anything directly in it.
  #
  # @yieldparam pool [String] the path session cgroups are created in
  def with_delegated_cgroup_parent
    Dir.mktmpdir("cgroupfs") do |tmp|
      root = File.join(tmp, "zimmer.sessions")
      FileUtils.mkdir_p(File.join(root, SessionMemoryCgroup::POOL_DIRNAME))
      with_cgroup_env(root: root) { yield SessionMemoryCgroup.parent_path }
    end
  end

  # The other half of the seam: point SessionMemoryCgroup at a parent that does not
  # exist, for a test of the unbounded path.
  #
  # Leaving the env unset does NOT do this. Unset falls through to DEFAULT_ROOT,
  # `/sys/fs/cgroup/zimmer.sessions`, which on a sysbox worker is a real delegated
  # subtree — the box Zimmer's own agent sessions run on is exactly such a box. A test
  # that only omits the stub therefore asserts "this host has no cgroupfs" rather than
  # "the unbounded path is a clean pass-through", passes on a laptop and in CI, and
  # fails on the worker (#902). Worse, it does not merely fail: `prepare!` succeeds, so
  # the run creates `session-<id>` cgroups in the live subtree next to real sessions.
  #
  # The tmpdir exists and its `zimmer.sessions` child deliberately does not, so the
  # path is absent, is unique per call, and cannot collide with anything on the host.
  #
  # @yieldparam parent [String] the absent parent's path, for a test that wants to
  #   assert nothing was created there
  def without_delegated_cgroup_parent
    Dir.mktmpdir("cgroupfs") do |tmp|
      root = File.join(tmp, "zimmer.sessions")
      with_cgroup_env(root: root) do
        parent = SessionMemoryCgroup.parent_path

        # The whole point of the helper, so it is checked rather than assumed: a test
        # of the unbounded path that runs with the bound available proves nothing.
        raise "the delegated parent #{parent} must be unavailable" if SessionMemoryCgroup.available?

        yield parent
      end
    end
  end

  # Set both variables `available?` reads, and return their previous values.
  #
  # The second one is easy to overlook. `available?` short-circuits false when
  # ZIMMER_SESSION_MEMORY_MAX_MB is `0` — the documented break-glass that takes the
  # mechanism out of the path entirely — and the worker exports that variable at deploy
  # time. So a *positive* test that stubbed only the parent would fail on a box mid
  # break-glass, which is #902's own mistake pointing the other way.
  #
  # @return [Array<String, nil>] the previous [root, limit], for #restore_cgroup_env!
  def stub_cgroup_env!(root:)
    previous = ENV.values_at(ROOT_VAR, LIMIT_VAR)
    ENV[ROOT_VAR] = root
    ENV[LIMIT_VAR] = PINNED_LIMIT_MB
    previous
  end

  # Put back what #stub_cgroup_env! returned, restoring "absent" as absent rather than
  # as an empty string.
  def restore_cgroup_env!(previous)
    root, limit = previous
    root.nil? ? ENV.delete(ROOT_VAR) : ENV[ROOT_VAR] = root
    limit.nil? ? ENV.delete(LIMIT_VAR) : ENV[LIMIT_VAR] = limit
  end

  def with_cgroup_env(root:)
    previous = nil
    previous = stub_cgroup_env!(root: root)
    yield
  ensure
    restore_cgroup_env!(previous) if previous
  end

  # Write the control files the kernel would have written for one session's cgroup.
  #
  # Only the ones a test names: a `nil` is a file that is absent, which is a state the
  # readers have to survive (an older kernel has no `memory.peak`).
  #
  # @return [String] the cgroup's path
  # `oom_events` is the cgroup's own `oom` counter — the one the kernel moves only when
  # THIS cgroup's limit was the one exceeded, and therefore what separates a kill the
  # session's own bound caused from one the shared pool declared. It defaults to matching
  # the kill count, which is the session's-own-bound case; pass 0 for a pool kill, or nil
  # to leave the key out of the file entirely.
  def write_session_cgroup(session_id, oom_kills: nil, oom_events: :match, current: nil, peak: nil,
    limit: 4 * 1024 * 1024 * 1024)
    path = File.join(SessionMemoryCgroup.parent_path, "session-#{session_id}")
    FileUtils.mkdir_p(path)
    File.write(File.join(path, "memory.max"), limit.to_s) if limit
    File.write(File.join(path, "memory.current"), current.to_s) if current
    File.write(File.join(path, "memory.peak"), peak.to_s) if peak
    if oom_kills
      events = oom_events == :match ? oom_kills : oom_events
      body = events.nil? ? "" : "oom #{events}\n"
      File.write(File.join(path, "memory.events"), "#{body}oom_kill #{oom_kills}\n")
    end
    path
  end

  # The pool's aggregate bound, which bin/docker-entrypoint writes as root.
  #
  # @return [String] the pool's path
  def write_pool_cgroup(current: nil, limit: 6 * 1024 * 1024 * 1024)
    path = SessionMemoryCgroup.parent_path
    FileUtils.mkdir_p(path)
    File.write(File.join(path, "memory.max"), limit.nil? ? "max" : limit.to_s)
    File.write(File.join(path, "memory.current"), current.to_s) if current
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
