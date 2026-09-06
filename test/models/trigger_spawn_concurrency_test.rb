# frozen_string_literal: true

require "test_helper"

# `skip_if_pending_session` under real concurrency (#606).
#
# PR #670 landed the setting and named the residual in its own words: the check
# was "deliberately NOT under a row lock", so "two fires landing in the same
# instant can both read 'nothing pending' and both spawn". That is what produced
# two fleet-maintenance sessions for one `quota_available` recovery — same
# trigger, same second, two processes — each then running the wake policy's caps
# against the same waiting queue.
#
# Non-transactional deliberately. The whole question is whether one connection
# sees a session another connection has committed, and a transactional test hides
# exactly that.
class TriggerSpawnConcurrencyTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  setup do
    @fixture_session_ids = Session.pluck(:id)
  end

  teardown do
    Session.where.not(id: @fixture_session_ids).find_each(&:destroy)
    @trigger&.destroy
  end

  # The lock is what a losing fire loses. While one process is making this
  # trigger's spawn decision, no other process may be making it — and when the
  # loser is finally let through it reads a session that is really committed,
  # rather than one still in flight, so it skips instead of spawning a sibling.
  test "a second fire cannot make the spawn decision while another process is making it" do
    trigger = build_trigger

    holder_took_lock = Queue.new
    release_holder = Queue.new
    holder_spawned = Queue.new
    loser_returned = Queue.new

    holder = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        Trigger.with_spawn_lock(trigger.id) do |serialized|
          holder_took_lock << serialized
          release_holder.pop
          # Nested acquire on the same connection: advisory locks are counted per
          # session, which is what makes the whole fire path safe to run inside
          # the lock it will take again.
          holder_spawned << Trigger.find(trigger.id).create_session!(prompt: "wake the fleet")&.id
        end
      end
    end

    assert_equal true, holder_took_lock.pop, "the holder must actually take the lock"

    loser_started = Queue.new
    loser = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        fire = Trigger.find(trigger.id)
        loser_started << true
        loser_returned << fire.create_session!(prompt: "wake the fleet")&.id
      end
    end

    # Wait for the loser to be inside the fire before asserting it is stuck, so
    # the assertion cannot pass merely because the thread had not started.
    loser_started.pop
    sleep 0.3
    assert_raises(ThreadError, "the second fire must block while another process holds the spawn lock") do
      loser_returned.pop(true)
    end
    assert_equal 0, Session.for_trigger(trigger.id).count,
      "nothing may be spawned by a fire that has not taken the lock"

    release_holder << true
    spawned_id = holder_spawned.pop
    assert_not_nil spawned_id, "the fire holding the lock spawns the session the event asked for"
    holder.join(10)

    assert_nil loser_returned.pop, "the losing fire must see the committed session and skip"
    loser.join(10)

    assert_equal [ spawned_id ], Session.for_trigger(trigger.id).pluck(:id),
      "one recovery edge, one session"
  end

  # The same thing said the way the issue says it: two fires, one instant, one
  # session.
  test "two fires landing in the same instant spawn one session, not two" do
    trigger = build_trigger
    barrier = Concurrent::CyclicBarrier.new(2)

    ids = [ 1, 2 ].map {
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          fire = Trigger.find(trigger.id)
          barrier.wait(10)
          fire.create_session!(prompt: "wake the fleet")&.id
        end
      end
    }.map { |thread| thread.join(30) && thread.value }

    assert_equal 1, ids.compact.uniq.size, "exactly one fire may spawn"
    assert_equal ids.compact.uniq, Session.for_trigger(trigger.id).pluck(:id)
  end

  # Over-tightening is the failure on the other side. The lock serializes the
  # decision; it does not change what the decision is. A fire that arrives once
  # the earlier session has had its turn still spawns, or a stalled queue would
  # be the cure for a doubled one.
  test "a fire after the previous session has had its turn still spawns" do
    trigger = build_trigger

    first = trigger.create_session!(prompt: "wake the fleet")
    assert_not_nil first
    first.update_columns(status: Session.statuses[:archived])

    second = trigger.create_session!(prompt: "wake the fleet")

    assert_not_nil second, "an archived predecessor must not suppress the next recovery"
    assert_not_equal first.id, second.id
  end

  # The lock is opt-in with the setting it protects: a trigger that never asked
  # to dedup is asking for one session per fire, and two fires are two sessions.
  # The lock is never taken on that path — asserted by holding it throughout, so
  # a fire that tried to take it would stall for SPAWN_LOCK_WAIT instead.
  test "a trigger without the setting takes no lock and spawns per fire" do
    trigger = build_trigger(skip_if_pending_session: false)
    first = nil
    second = nil

    ActiveRecord::Base.connection_pool.with_connection do
      Trigger.with_spawn_lock(trigger.id) do |serialized|
        assert_equal true, serialized

        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        first = Thread.new { ActiveRecord::Base.connection_pool.with_connection { trigger.create_session!(prompt: "wake the fleet") } }.value
        second = Thread.new { ActiveRecord::Base.connection_pool.with_connection { trigger.create_session!(prompt: "wake the fleet") } }.value
        elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

        assert_operator elapsed, :<, Trigger::SPAWN_LOCK_WAIT.to_f,
          "a trigger without the setting must not wait on the spawn lock at all"
      end
    end

    assert_not_nil first
    assert_not_nil second
    assert_not_equal first.id, second.id
  end

  # The fail-open contract: a fire that cannot take the lock within its wait
  # still spawns. Dropping it would trade a rare duplicate for a lost wake.
  test "a fire that cannot take the lock in time proceeds unserialized" do
    trigger = build_trigger
    holder_took_lock = Queue.new
    release_holder = Queue.new

    holder = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        Trigger.with_spawn_lock(trigger.id) do |serialized|
          holder_took_lock << serialized
          release_holder.pop
        end
      end
    end
    assert_equal true, holder_took_lock.pop

    serialized = nil
    session = nil
    ActiveRecord::Base.connection_pool.with_connection do
      Trigger.with_spawn_lock(trigger.id, wait: 0.1) do |acquired|
        serialized = acquired
        session = trigger.create_session!(prompt: "wake the fleet")
      end
    end

    assert_equal false, serialized, "the lock was held, so this fire must know it ran unserialized"
    assert_not_nil session, "an unserialized fire must still spawn — a dropped wake is the worse failure"

    release_holder << true
    holder.join(10)
  end

  # An advisory lock is session-level, so a leaked one would be held for the life
  # of a pooled connection and every later fire of that trigger would stall for
  # the full wait before failing open.
  test "the lock is released when the block raises" do
    trigger = build_trigger

    assert_raises(RuntimeError) do
      ActiveRecord::Base.connection_pool.with_connection do
        Trigger.with_spawn_lock(trigger.id) { raise "spawn blew up" }
      end
    end

    ActiveRecord::Base.connection_pool.with_connection do
      Trigger.with_spawn_lock(trigger.id, wait: 0.1) do |serialized|
        assert_equal true, serialized, "the raise must not have left the lock held"
      end
    end
  end

  # A caller that opened its own transaction gets no lock, deliberately: it could
  # not see a committed sibling from inside that snapshot, and a session-level
  # lock survives the rollback of a block that aborted the transaction — so
  # taking it would strand the lock on a pooled connection for good.
  test "a fire inside a caller's transaction takes no lock" do
    trigger = build_trigger
    serialized = nil

    ActiveRecord::Base.transaction do
      Trigger.with_spawn_lock(trigger.id) { |acquired| serialized = acquired }
      raise ActiveRecord::Rollback
    end

    assert_equal false, serialized

    # And the lock really was never taken, so it is free immediately afterwards.
    ActiveRecord::Base.connection_pool.with_connection do
      Trigger.with_spawn_lock(trigger.id, wait: 0.1) do |acquired|
        assert_equal true, acquired
      end
    end
  end

  private

  def build_trigger(skip_if_pending_session: true)
    @trigger = Trigger.create!(
      name: "Spawn race #{SecureRandom.hex(3)}",
      agent_root_name: AgentRootsConfig.all.first.name,
      prompt_template: "Wake the fleet",
      status: "enabled",
      skip_if_pending_session: skip_if_pending_session,
      trigger_conditions_attributes: [
        { condition_type: "system_event", configuration: { "event_name" => "quota_available" } }
      ]
    )
  end
end
