# frozen_string_literal: true

require "test_helper"

# The one-off memory boost: SessionMemoryBoost.reconcile! converging the cgroups on the
# columns, against a directory of ordinary files standing in for cgroupfs (see
# SessionMemoryCgroupTest for what that can and cannot cover).
class SessionMemoryBoostTest < ActiveSupport::TestCase
  GIB = 1024 * 1024 * 1024

  setup do
    @tmp = Dir.mktmpdir("cgroupfs")
    @previous_env = stub_cgroup_env!(root: File.join(@tmp, "zimmer.sessions"))
    @pool = SessionMemoryCgroup.parent_path
    FileUtils.mkdir_p(@pool)
    File.write(File.join(@pool, "memory.max"), (6 * GIB).to_s)
    @session = sessions(:running)
    @other = sessions(:needs_input)
  end

  teardown do
    restore_cgroup_env!(@previous_env)
    FileUtils.remove_entry(@tmp) if @tmp && Dir.exist?(@tmp)
  end

  def boost!(session, mb, expires_at: 2.hours.from_now)
    session.update_columns(memory_boost_mb: mb, memory_boost_expires_at: expires_at)
  end

  def shared_max
    File.read(File.join(SessionMemoryCgroup.shared_path, "memory.max"))
  end

  test "with no boost held, the shared tier carries no cap of its own" do
    SessionMemoryCgroup.for(@other.id).prepare!

    assert_equal({}, SessionMemoryBoost.reconcile!)
    assert_equal "max", shared_max
    assert_empty SessionMemoryCgroup.boosted_session_ids
  end

  test "a boost carves the session out and caps everyone else at what it leaves" do
    SessionMemoryCgroup.for(@session.id).prepare!
    boost!(@session, 5120)

    assert_equal({ @session.id => 5 * GIB }, SessionMemoryBoost.reconcile!)

    cgroup = SessionMemoryCgroup.for(@session.id)
    assert_predicate cgroup, :carved_out?
    assert_equal (5 * GIB).to_s, File.read(File.join(cgroup.path, "memory.max"))
    assert_equal (1 * GIB).to_s, shared_max, "pool 6 GiB minus the 5 GiB boost"
    assert_equal (6 * GIB).to_s, File.read(File.join(@pool, "memory.max")), "the pool itself is never written"

    @session.reload
    assert_equal 5 * GIB, @session.metadata[SessionMemoryBoost::APPLIED_BYTES_KEY]
    assert_equal 1 * GIB, @session.metadata[SessionMemoryBoost::SHARED_TARGET_BYTES_KEY]
    assert_match(/5 GB per-session limit/, SessionMemoryBoost.describe(@session))
    assert_match(/all of it is reserved/, SessionMemoryBoost.describe(@session))
  end

  test "a boost bigger than the pool can pay for is clamped to leave the floor to everyone else" do
    boost!(@session, 12_288)

    assert_equal({ @session.id => 5 * GIB }, SessionMemoryBoost.reconcile!)
    assert_match(/12 GB requested; the pool leaves room for no more/, SessionMemoryBoost.describe(@session.reload))
  end

  test "a boost that would leave no more than the ordinary bound is not applied" do
    File.write(File.join(@pool, "memory.max"), (5 * GIB).to_s)
    boost!(@session, 8192)

    assert_equal({}, SessionMemoryBoost.reconcile!, "5 GiB pool minus the 1 GiB floor is no more than 4 GiB")
    assert_equal "max", shared_max
    assert_match(/Not applied yet/, SessionMemoryBoost.describe(@session.reload))
  end

  test "on a busy box the cap approaches its target and the page says how much is reserved" do
    SessionMemoryCgroup.ensure_tier!(SessionMemoryCgroup.shared_path)
    File.write(File.join(SessionMemoryCgroup.shared_path, "memory.current"), (3 * GIB).to_s)
    boost!(@session, 5120)

    SessionMemoryBoost.reconcile!

    cap = 3 * GIB + SessionMemoryCgroup::SHARED_CAP_SLACK_BYTES
    assert_equal cap.to_s, shared_max, "never below what the others already hold"
    assert_match(/coming down to 1 GB/, SessionMemoryBoost.describe(@session.reload))
  end

  test "an expired boost returns the session to the shared tier and lifts the cap" do
    boost!(@session, 5120)
    SessionMemoryBoost.reconcile!
    cgroup = SessionMemoryCgroup.for(@session.id)
    File.write(cgroup.procs_path, "")
    FileUtils.rm(Dir.glob(File.join(cgroup.boosted_path, "*")))

    boost!(@session, 5120, expires_at: 1.minute.ago)
    assert_equal({}, SessionMemoryBoost.reconcile!)

    refute_predicate cgroup, :carved_out?
    assert_equal File.join(SessionMemoryCgroup.shared_path, "session-#{@session.id}"), cgroup.path
    assert_equal "max", shared_max
    assert_nil @session.reload.metadata[SessionMemoryBoost::APPLIED_BYTES_KEY]
    assert_nil SessionMemoryBoost.describe(@session)
  end

  test "an archived session's boost ends and an unarchive does not bring it back" do
    boost!(@session, 5120)
    @session.archive!

    assert_nil @session.reload.memory_boost_mb
    assert_nil @session.memory_boost_expires_at
    refute_predicate @session, :memory_boost_active?
  end

  test "two stored boosts never overspend the pool" do
    boost!(@session, 5120)
    boost!(@other, 5120)

    granted = SessionMemoryBoost.reconcile!

    assert_equal [ [ @session.id, @other.id ].min ], granted.keys, "the later one gets what is left, which is nothing"
  end

  test "is a no-op where per-session cgroups are unavailable" do
    boost!(@session, 5120)
    FileUtils.remove_entry(@pool)

    assert_equal({}, SessionMemoryBoost.reconcile!)
  end
end
