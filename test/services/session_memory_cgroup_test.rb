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
#
# The stand-in carries one rule with it, spelled out in SessionMemoryCgroupHelpers: a
# test that reads #incarnation twice must not let anything create a file in the cgroup
# directory in between. On real cgroupfs the control files arrive with the directory;
# here they do not, and creating one moves the ctime #incarnation keys on (#820).
class SessionMemoryCgroupTest < ActiveSupport::TestCase
  setup do
    @original_root = ENV["ZIMMER_SESSION_CGROUP_ROOT"]
    @original_limit = ENV["ZIMMER_SESSION_MEMORY_MAX_MB"]
    @tmp = Dir.mktmpdir("cgroupfs")
    @root = File.join(@tmp, "zimmer.sessions")
    ENV["ZIMMER_SESSION_CGROUP_ROOT"] = @root
    # bin/docker-entrypoint creates the pool inside the delegated root, and session
    # cgroups live in the pool rather than in the root — the root also holds `app`, so a
    # cap there would cover the Rails worker (tadasant/zimmer#981).
    @parent = File.join(@root, SessionMemoryCgroup::POOL_DIRNAME)
    FileUtils.mkdir_p(@parent)
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
  #
  # `memory.events` is seeded before the baseline rather than after it, per the rule at
  # the top of the file: seeded after, this assertion passed only when both reads landed
  # in the same ctime granule, which is a coin flip and not a test (#820). Any control
  # file #prepare! learns to write has to be seeded here too, for the same reason.
  test "prepare! reuses an existing cgroup rather than resetting its counters" do
    cgroup = SessionMemoryCgroup.for(7)
    cgroup.prepare!
    File.write(File.join(cgroup.path, "memory.events"), "oom_kill 3\n")
    before = cgroup.incarnation

    assert cgroup.prepare!
    assert_equal 3, cgroup.oom_kill_count
    assert_equal before, cgroup.incarnation, "a reused cgroup is the same incarnation"
  end

  # --- the reported-kills baseline ----------------------------------------
  #
  # Shared by SessionMemoryWatch (which reports) and ProcessLifecycleManager (which
  # attributes a signal death), so it lives here rather than in either of them.

  test "every kill is unaccounted for until the session is told" do
    cgroup = SessionMemoryCgroup.for(30)
    cgroup.prepare!
    File.write(File.join(cgroup.path, "memory.events"), "oom_kill 2\n")
    session = sessions(:active_session)

    assert_equal 2, cgroup.unaccounted_oom_kills(session)

    cgroup.record_oom_kills!(session, 2)

    assert_equal 0, cgroup.unaccounted_oom_kills(session.reload)
  end

  # The inode alone would not do this: ext4 hands the same inode straight back on a
  # remove-and-recreate, which is why #incarnation pairs it with the creation time.
  test "a recreated cgroup's counter is news, even at the same count" do
    cgroup = SessionMemoryCgroup.for(31)
    cgroup.prepare!
    File.write(File.join(cgroup.path, "memory.events"), "oom_kill 1\n")
    session = sessions(:active_session)
    cgroup.record_oom_kills!(session, 1)

    assert_equal 0, cgroup.unaccounted_oom_kills(session.reload)

    recreate_session_cgroup(31, oom_kills: 1)

    assert_equal 1, SessionMemoryCgroup.for(31).unaccounted_oom_kills(session.reload),
      "the counter restarted, so its kill has never been reported"
  end

  test "a session with no metadata at all does not blow up the readers" do
    cgroup = SessionMemoryCgroup.for(32)
    cgroup.prepare!
    File.write(File.join(cgroup.path, "memory.events"), "oom_kill 1\n")
    session = sessions(:active_session)
    session.update_columns(metadata: nil)

    assert_equal 1, cgroup.unaccounted_oom_kills(session)
    refute cgroup.recently_oom_killed?(session, within: 1.minute)
  end

  test "recently_oom_killed? is scoped to the incarnation it was recorded against" do
    cgroup = SessionMemoryCgroup.for(33)
    cgroup.prepare!
    File.write(File.join(cgroup.path, "memory.events"), "oom_kill 1\n")
    session = sessions(:active_session)
    cgroup.record_oom_kills!(session, 1)

    assert cgroup.recently_oom_killed?(session.reload, within: 1.minute)

    recreate_session_cgroup(33, oom_kills: 1)

    refute SessionMemoryCgroup.for(33).recently_oom_killed?(session, within: 1.minute),
      "a timestamp from a cgroup that no longer exists says nothing about this one"
  end

  # The break-glass has to take the whole mechanism out of the path, not merely widen the
  # bound: an operator reaching for it in an incident may well be reaching for it BECAUSE
  # of the `sh` wrapper or the migration, and writing `max` into memory.max would leave
  # both exactly where they were.
  test "a limit of 0 takes the whole mechanism out of the spawn path" do
    ENV["ZIMMER_SESSION_MEMORY_MAX_MB"] = "0"

    refute SessionMemoryCgroup.available?
    assert_nil SessionMemoryCgroup.for(1)
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
    FileUtils.mkdir_p(SessionMemoryCgroup.parent_path)
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
  test "the sweep removes cgroups whose session is gone from the database" do
    finished = SessionMemoryCgroup.for(20)
    FileUtils.mkdir_p(finished.path)

    assert_equal 1, SessionMemoryCgroup.sweep!
    refute_predicate finished, :exists?
  end

  # THE BUG A REVIEW CAUGHT, from the sweep's side. A session between turns sits in
  # `needs_input` for hours with a cgroup that holds no processes and is not remotely
  # garbage. Removing it resets `memory.peak` and the OOM counter the next turn reads,
  # so a session that OOMs, idles, and OOMs again loses the second report.
  test "the sweep leaves a live session's cgroup alone even when it holds no processes" do
    session = sessions(:active_session)
    idle = SessionMemoryCgroup.for(session.id)
    FileUtils.mkdir_p(idle.path)

    assert_equal 0, SessionMemoryCgroup.sweep!
    assert_predicate idle, :exists?,
      "a session between turns has an empty cgroup and is not finished with it"
  end

  test "the sweep removes an archived session's cgroup" do
    session = sessions(:active_session)
    session.update_columns(status: Session.statuses[:archived])
    done = SessionMemoryCgroup.for(session.id)
    FileUtils.mkdir_p(done.path)

    assert_equal 1, SessionMemoryCgroup.sweep!
    refute_predicate done, :exists?
  end

  test "the sweep ignores a directory that is not a session cgroup" do
    FileUtils.mkdir_p(File.join(@parent, "session-not-a-number"))

    assert_equal 0, SessionMemoryCgroup.sweep!
    assert File.directory?(File.join(@parent, "session-not-a-number"))
  end

  test "the sweep leaves a cgroup that still holds a process, whatever the database thinks" do
    live = SessionMemoryCgroup.for(21)
    live.prepare!
    File.write(live.procs_path, "4242\n")

    assert_equal 0, SessionMemoryCgroup.sweep!
    assert_predicate live, :exists?
  end

  test "the sweep leaves anything it did not create alone" do
    # `app` is the pool's SIBLING, so the sweep never looks at it at all -- but the
    # filter is what makes that a fact about the sweep rather than about where the
    # entrypoint currently puts things.
    FileUtils.mkdir_p(File.join(@root, "app"))
    File.write(File.join(@root, "app", "cgroup.procs"), "")
    FileUtils.mkdir_p(File.join(@parent, "app"))
    File.write(File.join(@parent, "app", "cgroup.procs"), "")

    assert_equal 0, SessionMemoryCgroup.sweep!
    assert File.directory?(File.join(@root, "app")),
      "sweeping the app cgroup would evict the Rails worker's own delegation anchor"
    assert File.directory?(File.join(@parent, "app"))
  end

  test "the sweep does nothing where per-session cgroups are unavailable" do
    ENV["ZIMMER_SESSION_CGROUP_ROOT"] = File.join(@tmp, "never-delegated")

    assert_equal 0, SessionMemoryCgroup.sweep!
  end

  # --- the shared pool (tadasant/zimmer#981) -------------------------------
  #
  # Per-session bounds do not sum to anything: eight sessions each far inside a 4 GiB
  # bound reached 8.7 GB between them, the container's own 10 GiB cap fired, and the
  # kernel killed the biggest process in it -- the Rails worker. The pool is a second
  # `memory.max` on a cgroup that holds every session cgroup and NOT the worker.

  # The placement is the fix. A cap on the delegated root would cover `root/app`, where
  # the entrypoint puts the Rails worker, and the kernel picks its victim by size across
  # the whole subtree of the memcg that declared the OOM -- so the worker would be right
  # back in the victim pool.
  test "session cgroups live in the pool below the delegated root, not beside the app" do
    assert_equal File.join(@root, "sessions"), SessionMemoryCgroup.parent_path
    assert_equal @root, SessionMemoryCgroup.root_path
    assert_equal File.join(@root, "sessions", "session-77"), SessionMemoryCgroup.for(77).path
  end

  test "the aggregate bound is read from the pool the entrypoint wrote it on" do
    File.write(File.join(@parent, "memory.max"), "6442450944\n")

    assert_equal 6_442_450_944, SessionMemoryCgroup.pool_stats.limit_bytes
  end

  # "The entrypoint could not write the cap" and "the cap is simply large" are different
  # states, and only the reader can tell them apart -- so an uncapped pool must read as
  # nil rather than as a number.
  test "an uncapped or unreadable pool reports no aggregate bound" do
    assert_nil SessionMemoryCgroup.pool_stats.limit_bytes, "no memory.max at all is not a bound"

    File.write(File.join(@parent, "memory.max"), "max\n")

    assert_nil SessionMemoryCgroup.pool_stats.limit_bytes
  end

  # --- which bound killed it -----------------------------------------------
  #
  # `oom_kill` counts processes killed in this cgroup by ANY OOM killer, including one an
  # ancestor declared, so on its own it cannot tell "this session ran out" from "the pool
  # did". `oom` counts the cgroup whose OWN limit was exceeded, and cgroup v2 propagates
  # events upward only — so it is the discriminator.

  test "a kill that moved this cgroup's own oom counter is the session's own bound" do
    cgroup = SessionMemoryCgroup.for(31)
    cgroup.prepare!
    File.write(File.join(cgroup.path, "memory.events"), "oom 1\noom_kill 1\n")
    session = sessions(:active_session)

    assert_equal SessionMemoryCgroup::SESSION_SCOPE, cgroup.record_oom_kills!(session, 1)
    assert_equal SessionMemoryCgroup::SESSION_SCOPE, cgroup.last_kill_scope(session.reload)
  end

  test "a kill that left this cgroup's own oom counter alone came from the pool" do
    cgroup = SessionMemoryCgroup.for(32)
    cgroup.prepare!
    File.write(File.join(cgroup.path, "memory.events"), "oom 0\noom_kill 1\n")
    session = sessions(:active_session)

    assert_equal SessionMemoryCgroup::POOL_SCOPE, cgroup.record_oom_kills!(session, 1)
    assert_equal SessionMemoryCgroup::POOL_SCOPE, cgroup.last_kill_scope(session.reload)
  end

  # The baseline moves with the report, so a session that hits its own bound twice is
  # attributed to itself both times rather than reading the second as the pool's.
  test "the oom baseline moves with each report" do
    cgroup = SessionMemoryCgroup.for(33)
    cgroup.prepare!
    File.write(File.join(cgroup.path, "memory.events"), "oom 1\noom_kill 1\n")
    session = sessions(:active_session)
    cgroup.record_oom_kills!(session, 1)

    File.write(File.join(cgroup.path, "memory.events"), "oom 1\noom_kill 2\n")

    assert_equal SessionMemoryCgroup::POOL_SCOPE, cgroup.record_oom_kills!(session.reload, 2),
      "the same oom count means this kill was not this cgroup's own limit"

    File.write(File.join(cgroup.path, "memory.events"), "oom 2\noom_kill 3\n")

    assert_equal SessionMemoryCgroup::SESSION_SCOPE, cgroup.record_oom_kills!(session.reload, 3)
  end

  # Same reason #accounted_oom_kills is keyed to the incarnation: a recreated cgroup's
  # counter restarts at zero while the recorded baseline lives in Postgres and does not.
  test "a recreated cgroup does not read its first own-bound kill as the pool's" do
    cgroup = SessionMemoryCgroup.for(34)
    cgroup.prepare!
    File.write(File.join(cgroup.path, "memory.events"), "oom 3\noom_kill 3\n")
    session = sessions(:active_session)
    cgroup.record_oom_kills!(session, 3)

    FileUtils.remove_entry(cgroup.path)
    cgroup.prepare!
    File.write(File.join(cgroup.path, "memory.events"), "oom 1\noom_kill 1\n")

    assert_equal SessionMemoryCgroup::SESSION_SCOPE, cgroup.record_oom_kills!(session.reload, 1)
    assert_nil cgroup.last_kill_scope(Session.new), "a foreign incarnation answers nothing"
  end

  test "a kernel that cannot answer records no scope rather than guessing one" do
    cgroup = SessionMemoryCgroup.for(35)
    cgroup.prepare!
    File.write(File.join(cgroup.path, "memory.events"), "oom_kill 1\n")
    session = sessions(:active_session)

    assert_nil cgroup.record_oom_kills!(session, 1)
    assert_nil cgroup.last_kill_scope(session.reload)
  end

  test "pool stats report the shared usage and the kills anywhere beneath it" do
    File.write(File.join(@parent, "memory.current"), "6442450944\n")
    File.write(File.join(@parent, "memory.max"), "7516192768\n")
    File.write(File.join(@parent, "memory.events"), "low 0\nhigh 0\nmax 4353\noom 1\noom_kill 3\n")

    stats = SessionMemoryCgroup.pool_stats

    assert_equal 6_442_450_944, stats.current_bytes
    assert_equal 7_516_192_768, stats.limit_bytes
    assert_equal 3, stats.oom_kills
    assert_predicate stats, :oom_killed?
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
