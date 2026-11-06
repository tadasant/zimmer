# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"

class LiveConversations::SwitchTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    stub_live_root
    stub_live_key
  end

  def ended(mode: "text", at: 1.hour.ago, said: "Is the poller test still failing on main?", **attrs)
    conversation = create_live_conversation(mode: mode, status: LiveConversation::ENDED, ended_at: at, **attrs)
    conversation.turns.create!(role: "user", source: "typed", content: said) if said
    conversation.turns.create!(role: "assistant", content: "Looking.") if said
    conversation
  end

  def refusal(*args, **kwargs)
    assert_raises(LiveConversations::Actions::Refused) { LiveConversations::Switch.call(*args, **kwargs) }
  end

  test "reopens the same row, ends the open one, and leaves exactly one open" do
    old = ended
    current = create_live_conversation

    outcome = LiveConversations::Switch.call(old.id)

    assert outcome.moved
    assert_equal old, outcome.conversation
    assert_equal [ current ], outcome.left
    assert old.reload.active?
    assert_nil old.ended_at
    assert current.reload.ended?
    assert_equal old, LiveConversation.current
    assert_equal 1, LiveConversation.unfinished.count
    assert_equal 2, old.turns.count
  end

  test "start new, then go back: no id means the one left last, and going back again toggles" do
    first = create_live_conversation(mode: "voice")
    first.turns.create!(role: "user", source: "spoken", content: "Deploy the fix to staging please")
    fresh = LiveConversations::Start.call("voice")
    fresh.update!(status: LiveConversation::ACTIVE, instructions: "# Live")
    fresh.turns.create!(role: "user", source: "spoken", content: "Actually a new thing to discuss")

    assert_equal first, LiveConversations::Switch.call.conversation
    assert_equal fresh, LiveConversations::Switch.call.conversation
    assert_equal fresh, LiveConversation.current
    assert_equal 1, LiveConversation.unfinished.count
  end

  test "a conversation nobody spoke in is not what going back means" do
    worth_it = ended(at: 2.hours.ago)
    ended(at: 1.hour.ago, said: nil)

    assert_equal worth_it, LiveConversations::Switch.call.conversation
  end

  test "the target takes the mode of the conversation being left, so a call stays a call" do
    old = ended(mode: "text")
    create_live_conversation(mode: "voice")

    conversation = LiveConversations::Switch.call(old.id).conversation

    assert conversation.voice?
    assert_equal LiveConversations.mode("voice").model, conversation.model
  end

  test "an explicit mode wins, and with nothing open the target keeps its own" do
    typed = ended(mode: "text")
    assert LiveConversations::Switch.call(typed.id, mode: "voice").conversation.voice?
    typed.end!

    spoken = ended(mode: "voice")
    assert LiveConversations::Switch.call(spoken.id).conversation.voice?
  end

  test "the thread's own servers follow it, less any the catalog dropped" do
    real = ServersConfig.find("zimmer")
    ServersConfig.stubs(:find).with("zimmer").returns(real)
    ServersConfig.stubs(:find).with("gone").returns(nil)
    old = ended(mcp_servers: %w[zimmer gone], mcp_tool_cache: { "gone" => [ { "name" => "x" } ] })

    conversation = LiveConversations::Switch.call(old.id).conversation

    assert_equal [ "zimmer" ], conversation.mcp_servers
    assert_empty conversation.mcp_tool_cache
  end

  test "already current is a no-op, not an error, and enqueues nothing" do
    current = create_live_conversation

    outcome = nil
    assert_no_enqueued_jobs { outcome = LiveConversations::Switch.call(current.id) }

    assert_not outcome.moved
    assert_equal current, outcome.conversation
    assert current.reload.active?
  end

  test "refuses what cannot be gone back to, and leaves the current conversation alone" do
    current = create_live_conversation
    failed = create_live_conversation(status: LiveConversation::FAILED)
    retired = ended
    retired.update!(agent_root: "live-voice")

    assert_equal :not_found, refusal(0).status
    assert_equal :not_found, refusal("nonsense").status
    assert_match(/failed/, refusal(failed.id).message)
    assert_match(/older Live Mode/, refusal(retired.id).message)
    assert current.reload.active?
  end

  test "nothing to go back to says so" do
    create_live_conversation

    assert_match(/no earlier conversation/, refusal.message)
  end

  test "a stale selection is refused: another conversation took over since the caller looked" do
    old = ended
    thought_current = ended(at: 2.hours.ago)
    actually_current = create_live_conversation

    error = refusal(old.id, from_id: thought_current.id)

    assert_equal :conflict, error.status
    assert_match(/changed/, error.message)
    assert actually_current.reload.active?
    assert old.reload.ended?
  end

  test "from_id is no bar when nothing is open any more" do
    old = ended

    assert LiveConversations::Switch.call(old.id, from_id: 123).moved
  end

  test "Live Mode being off refuses, in words a person can act on" do
    OpenaiClient.stubs(:api_key).returns(nil)
    old = ended

    error = refusal(old.id)

    assert_equal :service_unavailable, error.status
    assert_match(/not set/, error.message)
  end

  test "an unknown mode is refused before anything moves" do
    old = ended

    assert_match(/mode must be/, refusal(old.id, mode: "video").message)
    assert old.reload.ended?
  end

  test "one left mid-reply is reopened unclaimed, and the line nobody answered gets its answer" do
    old = create_live_conversation(status: LiveConversation::ENDED, ended_at: 1.hour.ago, responding_since: 1.hour.ago)
    old.turns.create!(role: "user", source: "typed", content: "Did it land?")

    assert_enqueued_with(job: LiveConversationReplyJob, args: [ old.id ]) { LiveConversations::Switch.call(old.id) }

    assert_nil old.reload.responding_since
  end

  test "a thread that ended on an answer asks for no reply, and refreshes its instructions" do
    old = ended

    assert_enqueued_with(job: LiveConversationPrepareJob, args: [ old.id, { refresh: true } ]) { LiveConversations::Switch.call(old.id) }
    assert_no_enqueued_jobs(only: LiveConversationReplyJob)
  end

  test "one that ended before it ever read its instructions prepares, rather than running on none" do
    old = ended(instructions: nil)

    assert_enqueued_with(job: LiveConversationPrepareJob, args: [ old.id ]) { LiveConversations::Switch.call(old.id) }

    assert old.reload.preparing?
  end

  test "the car's mark does not carry over: the next secret sets it for whoever calls" do
    old = ended(car_call: true, client_surface: "ios")

    conversation = LiveConversations::Switch.call(old.id, client_surface: "carplay").conversation

    assert_not conversation.car_call
    assert_equal "carplay", conversation.client_surface
  end

  test "losing the unique index to another opener retries once, then answers from what won" do
    old = ended
    other = create_live_conversation
    LiveConversations::Switch.any_instance.stubs(:move_to).raises(ActiveRecord::RecordNotUnique.new("dup"))

    assert_match(/changed/, refusal(old.id).message)
    other.update!(status: LiveConversation::ENDED)
    old.update!(status: LiveConversation::ACTIVE)
    assert_not LiveConversations::Switch.call(old.id).moved
  end
end

# Real connections and real locks, so outside the test's transaction.
class LiveConversations::SwitchRaceTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  setup do
    stub_live_root
    stub_live_key
    LiveConversation.delete_all
  end

  teardown { LiveConversation.delete_all }

  def race(count, &block)
    gate = Concurrent::CountDownLatch.new(1)
    threads = Array.new(count) do |index|
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          gate.wait
          block.call(index)
        rescue LiveConversations::Actions::Refused => e
          e
        end
      end
    end
    gate.count_down
    threads.map(&:value)
  end

  def ended_with_turn
    conversation = create_live_conversation(status: LiveConversation::ENDED, ended_at: 1.hour.ago)
    conversation.turns.create!(role: "user", source: "typed", content: "Something worth going back to")
    conversation
  end

  test "switches racing to different places leave exactly one open, and it is one of them" do
    targets = Array.new(3) { ended_with_turn }
    create_live_conversation

    10.times do
      race(3) { |index| LiveConversations::Switch.call(targets[index].id) }

      assert_equal 1, LiveConversation.unfinished.count
      assert_includes targets, LiveConversation.current
    end
  end

  test "two switches to one place: one moves, the other is the no-op" do
    target = ended_with_turn
    create_live_conversation

    outcomes = race(2) { LiveConversations::Switch.call(target.id) }

    assert_equal [ false, true ], outcomes.map(&:moved).sort_by { |moved| moved ? 1 : 0 }
    assert_equal target, LiveConversation.current
  end

  test "a switch racing a start still leaves one open" do
    target = ended_with_turn
    create_live_conversation

    race(2) { |index| index.zero? ? LiveConversations::Switch.call(target.id) : LiveConversations::Start.call("voice") }

    assert_equal 1, LiveConversation.unfinished.count
  end
end
