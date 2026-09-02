# frozen_string_literal: true

require "test_helper"
require "tmpdir"

# The reporting half of the per-session memory bound (tadasant/zimmer#815).
#
# The case that makes this necessary is the one the incident actually was: the kernel kills
# a TOOL SUBPROCESS, the agent survives, and the only trace is a bare `Killed` and exit 137
# in a tool result. No exit path ever sees that, so if the monitoring loop does not say so,
# nothing does.
class SessionMemoryWatchTest < ActiveSupport::TestCase
  # A log buffer that keeps its entries instead of writing them, so a test can read what a
  # human would have read.
  class RecordingBuffer
    attr_reader :entries

    def initialize = @entries = []
    def add(content, level: "info") = @entries << { content: content, level: level }
    def contents = @entries.map { |e| e[:content] }.join("\n")
  end

  setup do
    @original_root = ENV["ZIMMER_SESSION_CGROUP_ROOT"]
    @tmp = Dir.mktmpdir("cgroupfs")
    @parent = File.join(@tmp, "zimmer.sessions")
    FileUtils.mkdir_p(@parent)
    ENV["ZIMMER_SESSION_CGROUP_ROOT"] = @parent

    @session = sessions(:active_session)
    @cgroup = SessionMemoryCgroup.for(@session.id)
    @cgroup.prepare!
    @buffer = RecordingBuffer.new
  end

  teardown do
    if @original_root.nil?
      ENV.delete("ZIMMER_SESSION_CGROUP_ROOT")
    else
      ENV["ZIMMER_SESSION_CGROUP_ROOT"] = @original_root
    end
    FileUtils.remove_entry(@tmp) if @tmp && Dir.exist?(@tmp)
  end

  def write_cgroup(current: nil, peak: nil, oom_kills: nil, limit: 4 * 1024 * 1024 * 1024)
    File.write(File.join(@cgroup.path, "memory.max"), limit.to_s)
    File.write(File.join(@cgroup.path, "memory.current"), current.to_s) if current
    File.write(File.join(@cgroup.path, "memory.peak"), peak.to_s) if peak
    File.write(File.join(@cgroup.path, "memory.events"), "oom_kill #{oom_kills}\n") if oom_kills
  end

  test "reports an OOM kill in the session's own cgroup, and says what it means" do
    write_cgroup(peak: 4 * 1024 * 1024 * 1024, oom_kills: 1)

    SessionMemoryWatch.new(@session).check(@buffer)

    assert_match(/memory limit/, @buffer.contents)
    assert_match(/137/, @buffer.contents,
      "the agent sees exit 137 and nothing else — the log has to connect the two")
    assert_equal "warning", @buffer.entries.first[:level]
  end

  # Otherwise every tick for the rest of the session re-reports the same kill.
  test "reports each OOM kill once" do
    write_cgroup(oom_kills: 1)
    watch = SessionMemoryWatch.new(@session)
    watch.check(@buffer)

    fresh = SessionMemoryWatch.new(@session.reload)
    fresh.check(@buffer)

    assert_equal 1, @buffer.entries.count { |e| e[:content].include?("memory limit") }
  end

  # The count is remembered on the session rather than in the object, because the process
  # that has to tell "this death was the bound" from "a subprocess died an hour ago" is
  # ProcessLifecycleManager, in a different object and often a different job.
  test "records the observed kill count on the session" do
    write_cgroup(oom_kills: 2)

    SessionMemoryWatch.new(@session).check(@buffer)

    assert_equal 2, @session.reload.metadata[SessionMemoryWatch::OOM_KILL_COUNT_KEY]
  end

  test "a later kill is reported even though an earlier one was already seen" do
    write_cgroup(oom_kills: 1)
    SessionMemoryWatch.new(@session).check(@buffer)

    write_cgroup(oom_kills: 2)
    SessionMemoryWatch.new(@session.reload).check(@buffer)

    assert_equal 2, @buffer.entries.count { |e| e[:content].include?("memory limit") }
    assert_equal 2, @session.reload.metadata[SessionMemoryWatch::OOM_KILL_COUNT_KEY]
  end

  test "says nothing while the session is nowhere near its bound" do
    write_cgroup(current: 100 * 1024 * 1024, oom_kills: 0)

    SessionMemoryWatch.new(@session).check(@buffer)

    assert_empty @buffer.entries
  end

  # The early warning. A `memory.high` watermark would be the kernel-side way to get one,
  # but there is no swap to reclaim into, so it would buy a long stall and then the same
  # kill — see SessionMemoryCgroup#prepare!.
  test "warns once when the session crosses three quarters of its bound" do
    write_cgroup(current: (3.5 * 1024 * 1024 * 1024).to_i, oom_kills: 0)
    watch = SessionMemoryWatch.new(@session)

    watch.check(@buffer)
    @session.reload
    watch.instance_variable_set(:@last_checked_at, nil) # let it tick again immediately
    watch.check(@buffer)

    assert_equal 1, @buffer.entries.count { |e| e[:content].include?("of its") }
    assert_match(/3\.5 GB/, @buffer.contents)
  end

  # 0.5s per tick against a ramp measured in minutes: reading the cgroup every time would
  # be pure overhead.
  test "reads the cgroup at most once per interval" do
    now = Time.current
    clock = -> { now }
    watch = SessionMemoryWatch.new(@session, clock: clock)
    write_cgroup(oom_kills: 1)

    watch.check(@buffer)
    write_cgroup(oom_kills: 5)
    watch.check(@buffer)

    assert_equal 1, @buffer.entries.size
    now += SessionMemoryWatch::CHECK_INTERVAL + 1
    watch.check(@buffer)

    assert_equal 2, @buffer.entries.size
  end

  test "is inert where per-session cgroups are unavailable" do
    ENV["ZIMMER_SESSION_CGROUP_ROOT"] = File.join(@tmp, "never-delegated")
    watch = SessionMemoryWatch.new(@session)

    refute_predicate watch, :active?
    assert_nothing_raised { watch.check(@buffer) }
    assert_empty @buffer.entries
  end

  # A cgroup can be swept out from under a watch that is still ticking. A missing warning
  # is a missing warning; an exception here would take the monitoring loop with it.
  test "a vanished cgroup does not break the monitoring loop" do
    watch = SessionMemoryWatch.new(@session)
    FileUtils.remove_entry(@cgroup.path)

    assert_nothing_raised { watch.check(@buffer) }
    assert_empty @buffer.entries
  end
end
