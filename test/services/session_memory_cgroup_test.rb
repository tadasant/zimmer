# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require "open3"

# The per-session memory bound from tadasant/zimmer#815.
#
# What these tests can and cannot cover: CI has no writable cgroup2 filesystem, so the
# kernel's own enforcement is not exercised here — a directory of ordinary files stands in
# for the cgroup, which is enough to pin the file layout, the parsing and, importantly, the
# `sh` wrapper (that one runs for real). The enforcement half is verified on staging: a
# `bash` accumulating in a 256 MiB session cgroup was OOM-killed inside it while the
# container was untouched.
class SessionMemoryCgroupTest < ActiveSupport::TestCase
  setup do
    @original_root = ENV["ZIMMER_SESSION_CGROUP_ROOT"]
    @original_limit = ENV["ZIMMER_SESSION_MEMORY_MAX_MB"]
    @tmp = Dir.mktmpdir("cgroupfs")
    @parent = File.join(@tmp, "zimmer.sessions")
    FileUtils.mkdir_p(@parent)
    ENV["ZIMMER_SESSION_CGROUP_ROOT"] = @parent
  end

  teardown do
    restore_env("ZIMMER_SESSION_CGROUP_ROOT", @original_root)
    restore_env("ZIMMER_SESSION_MEMORY_MAX_MB", @original_limit)
    FileUtils.remove_entry(@tmp) if @tmp && Dir.exist?(@tmp)
  end

  # --- availability -------------------------------------------------------
  #
  # Every deployment that is not the sysbox worker lands here, so "unavailable" has to be
  # a clean no-op rather than an exception on the spawn path.

  test "is unavailable when the delegated parent does not exist" do
    ENV["ZIMMER_SESSION_CGROUP_ROOT"] = File.join(@tmp, "never-delegated")

    refute SessionMemoryCgroup.available?
    assert_nil SessionMemoryCgroup.for(42)
  end

  test "is unavailable when the delegated parent cannot be written" do
    File.chmod(0o500, @parent)

    refute SessionMemoryCgroup.available?
  ensure
    File.chmod(0o700, @parent)
  end

  test "has nothing to bound without a session id" do
    assert_nil SessionMemoryCgroup.for(nil)
    assert_nil SessionMemoryCgroup.for("")
  end

  # --- the cgroup ---------------------------------------------------------

  test "prepare! creates a cgroup named after the session and writes its limit" do
    ENV["ZIMMER_SESSION_MEMORY_MAX_MB"] = "2048"
    cgroup = SessionMemoryCgroup.for(12_398)

    assert cgroup.prepare!
    assert_equal File.join(@parent, "session-12398"), cgroup.path
    assert_equal (2048 * 1024 * 1024).to_s, File.read(File.join(cgroup.path, "memory.max"))
  end

  # The name is not cosmetic. A kernel `oom-kill:` line carries `oom_memcg=<path>`, so
  # naming the cgroup after the session is what turns "a process was OOM-killed on the
  # worker" into "session 12398 did it" — the attribution #815 could not establish.
  test "the cgroup path names the session, so the kernel's own OOM line attributes it" do
    assert_equal "session-12398", SessionMemoryCgroup.for(12_398).name
  end

  # A session respawns constantly — a follow-up turn, a continuation, a signal-death
  # resume. Each one must land in the SAME cgroup, or memory.peak and the OOM counter
  # reset every turn and the accumulated evidence is lost.
  test "prepare! reuses an existing cgroup rather than resetting its counters" do
    cgroup = SessionMemoryCgroup.for(7)
    cgroup.prepare!
    File.write(File.join(cgroup.path, "memory.events"), "oom_kill 3\n")

    assert cgroup.prepare!
    assert_equal 3, cgroup.oom_kill_count
  end

  test "a limit of 0 means no bound at all, for an operator disabling this in an incident" do
    ENV["ZIMMER_SESSION_MEMORY_MAX_MB"] = "0"
    cgroup = SessionMemoryCgroup.for(1)
    cgroup.prepare!

    assert_equal "max", File.read(File.join(cgroup.path, "memory.max"))
  end

  test "an unparseable limit falls back to the default rather than to no bound" do
    ENV["ZIMMER_SESSION_MEMORY_MAX_MB"] = "four gigs"

    assert_equal SessionMemoryCgroup::DEFAULT_LIMIT_BYTES, SessionMemoryCgroup.limit_bytes
  end

  # --- entering the cgroup ------------------------------------------------
  #
  # This wrapper is the whole mechanism — cgroup v2 has no Process.spawn option — so it
  # runs for real against a real /bin/sh here rather than being asserted as an array.

  test "the wrapper puts the process in the cgroup and keeps its pid through exec" do
    cgroup = SessionMemoryCgroup.for(5)
    cgroup.prepare!

    # The wrapped command prints its own pid. If `exec` did what it claims, that is the
    # same pid the shell wrote to cgroup.procs before it — which is what lets the
    # recorded process_pid, the process group and every signal path stay valid.
    argv = cgroup.enter_command([ "/bin/sh", "-c", "echo $$" ])
    stdout, status = Open3.capture2(*argv)

    assert_predicate status, :success?
    assert_equal stdout.strip, File.read(cgroup.procs_path).strip,
      "the pid in cgroup.procs must be the pid the command ends up running as"
  end

  test "the wrapper runs the command even when the cgroup cannot be joined" do
    cgroup = SessionMemoryCgroup.for(6)
    # No prepare! — cgroup.procs does not exist, which stands in for every way the
    # migration can fail. Unbounded is the old behaviour; refusing to start is not.
    argv = cgroup.enter_command([ "/bin/echo", "still ran" ])
    stdout, stderr, status = Open3.capture3(*argv)

    assert_predicate status, :success?
    assert_equal "still ran", stdout.strip
    assert_match(/without a per-session memory bound/, stderr,
      "a session running unbounded must say so where the monitoring loop tails stderr")
  end

  test "the wrapper does not let a path or an argument become shell syntax" do
    ENV["ZIMMER_SESSION_CGROUP_ROOT"] = File.join(@tmp, "od d; touch #{@tmp}/pwned")
    FileUtils.mkdir_p(ENV["ZIMMER_SESSION_CGROUP_ROOT"])
    cgroup = SessionMemoryCgroup.for(8)
    cgroup.prepare!

    argv = cgroup.enter_command([ "/bin/echo", "$(touch #{@tmp}/pwned2)", "; touch #{@tmp}/pwned3" ])
    stdout, = Open3.capture2(*argv)

    assert_equal "$(touch #{@tmp}/pwned2) ; touch #{@tmp}/pwned3", stdout.strip
    refute File.exist?(File.join(@tmp, "pwned"))
    refute File.exist?(File.join(@tmp, "pwned2"))
    refute File.exist?(File.join(@tmp, "pwned3"))
  end

  # --- reading the kernel's answer ----------------------------------------

  test "stats reports usage, high water mark and OOM kills" do
    cgroup = SessionMemoryCgroup.for(9)
    cgroup.prepare!
    File.write(File.join(cgroup.path, "memory.current"), "1048576\n")
    File.write(File.join(cgroup.path, "memory.peak"), "4194304\n")
    File.write(File.join(cgroup.path, "memory.events"), "low 0\nhigh 0\nmax 35\noom 1\noom_kill 2\n")

    stats = cgroup.stats

    assert_equal 1_048_576, stats.current_bytes
    assert_equal 4_194_304, stats.peak_bytes
    assert_equal 2, stats.oom_kills
    assert_predicate stats, :oom_killed?
  end

  # `memory.peak` needs Linux 5.19. The OOM counter is the part that decides whether a
  # death gets explained, so an older kernel must lose the nicety and not the answer.
  test "a kernel without memory.peak still reports the OOM count" do
    cgroup = SessionMemoryCgroup.for(10)
    cgroup.prepare!
    File.write(File.join(cgroup.path, "memory.events"), "oom_kill 1\n")

    stats = cgroup.stats

    assert_nil stats.peak_bytes
    assert_equal 1, stats.oom_kills
  end

  test "an unbounded cgroup reports no limit rather than a bogus number" do
    cgroup = SessionMemoryCgroup.for(11)
    cgroup.prepare!
    File.write(File.join(cgroup.path, "memory.max"), "max\n")

    assert_nil cgroup.stats.limit_bytes
  end

  test "stats on a cgroup that has been swept away reports nothing rather than raising" do
    cgroup = SessionMemoryCgroup.for(12)

    assert_nil cgroup.stats.oom_kills
    assert_nil cgroup.stats.current_bytes
  end

  # --- the sweep ----------------------------------------------------------

  # A bare directory rather than a prepare!d one, because this is the one place the fake
  # cgroupfs cannot stand in for the real one: `rmdir` removes a cgroup directory even
  # though the kernel shows control files inside it, while the same call on a tmpdir
  # holding those file names fails with ENOTEMPTY. The selection is what is asserted here;
  # that a populated cgroup really does rmdir is verified on staging.
  test "the sweep removes cgroups with no processes left in them" do
    finished = SessionMemoryCgroup.for(20)
    FileUtils.mkdir_p(finished.path)

    assert_equal 1, SessionMemoryCgroup.sweep!
    refute_predicate finished, :exists?
  end

  test "the sweep leaves a cgroup that still holds a process, whatever the database thinks" do
    live = SessionMemoryCgroup.for(21)
    live.prepare!
    File.write(live.procs_path, "4242\n")

    assert_equal 0, SessionMemoryCgroup.sweep!
    assert_predicate live, :exists?
  end

  test "the sweep leaves the app cgroup and anything else under the parent alone" do
    FileUtils.mkdir_p(File.join(@parent, "app"))
    File.write(File.join(@parent, "app", "cgroup.procs"), "")

    assert_equal 0, SessionMemoryCgroup.sweep!
    assert File.directory?(File.join(@parent, "app")),
      "sweeping the app cgroup would evict the Rails worker's own delegation anchor"
  end

  test "the sweep does nothing where per-session cgroups are unavailable" do
    ENV["ZIMMER_SESSION_CGROUP_ROOT"] = File.join(@tmp, "never-delegated")

    assert_equal 0, SessionMemoryCgroup.sweep!
  end

  private

  def restore_env(key, value)
    if value.nil?
      ENV.delete(key)
    else
      ENV[key] = value
    end
  end
end
