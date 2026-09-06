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

    loser = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        loser_returned << Trigger.find(trigger.id).create_session!(prompt: "wake the fleet")&.id
      end
    end

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
  test "a trigger without the setting is untouched by the lock" do
    trigger = build_trigger(skip_if_pending_session: false)

    first = trigger.create_session!(prompt: "wake the fleet")
    second = trigger.create_session!(prompt: "wake the fleet")

    assert_not_nil first
    assert_not_nil second
    assert_not_equal first.id, second.id
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
