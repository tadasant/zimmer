# frozen_string_literal: true

require "test_helper"

# EnqueuedMessage#reorder_to run against another writer holding the same queue
# open on a second connection.
#
# The reorder renumbers its neighbours from positions it reads. Read without
# the queue lock, those positions can belong to a queue another transaction is
# halfway through rewriting, and the reorder writes numbers computed from them
# once that transaction commits — undoing the other caller's move. Under
# Sessions::QueueTail.lock!, it waits for the other writer to commit and reads
# the queue it left.
#
# Non-transactional deliberately: the question is what one connection sees of
# another's uncommitted work, and a transactional test hides exactly that.
class EnqueuedMessageReorderConcurrencyTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  setup do
    @session = Session.create!(
      prompt: "Original prompt",
      agent_runtime: "claude_code",
      git_root: "https://github.com/test/repo.git",
      branch: "main",
      session_id: SecureRandom.uuid,
      status: :running
    )
    @a, @b, @c, @d = %w[A B C D].each_with_index.map do |content, i|
      @session.enqueued_messages.create!(content: content, status: "pending", position: i + 1)
    end
  end

  teardown do
    @session&.destroy
  end

  test "two reorders on one queue both land, the second applied to the queue the first left" do
    # A moves to 3 and holds its transaction open: B1 C2 A3 D4, uncommitted.
    # D, loaded at 4 before that, moves to 1 meanwhile.
    race(holding: -> { EnqueuedMessage.find(@a.id).reorder_to(3) }) do
      @d.reorder_to(1)
    end

    assert_equal %w[D B C A], queue_contents
    assert_equal [ 1, 2, 3, 4 ], @session.enqueued_messages.order(:position).pluck(:position)
  end

  test "a reorder waits for an open append and the appended row stays at the tail" do
    contender_blocked = race(
      holding: -> {
        session = Session.find(@session.id)
        session.enqueued_messages.create!(
          content: "E", status: "pending", position: Sessions::QueueTail.next_position!(session)
        )
      }
    ) { @a.reorder_to(4) }

    assert contender_blocked, "the reorder must wait while an append holds the queue lock"
    assert_equal %w[B C D A E], queue_contents
  end

  private

  # Runs `holding` in a transaction on one connection and keeps it open, runs
  # the block on another, then commits the holder. Returns whether the block was
  # still blocked 0.3s after it started. The holder is always released, so a
  # failed assertion cannot leave its lock open for teardown to wait on.
  def race(holding:, &contend)
    held = Queue.new
    release = Queue.new
    started = Queue.new
    finished = Queue.new
    holder = contender = nil

    begin
      holder = Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          ActiveRecord::Base.transaction do
            holding.call
            held << true
            release.pop
          end
        end
      end
      unless held.pop(timeout: 10)
        holder.join(1)&.value # re-raises what the holding writer died of, if it died
        flunk "the holding writer did not take its lock within 10s"
      end

      contender = Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          started << true
          contend.call
          finished << true
        end
      end

      started.pop
      sleep 0.3
      blocked = finished.empty?
    ensure
      release << true
      holder&.join(10)
      contender&.join(10)
    end

    contender.value
    blocked
  end

  def queue_contents
    @session.enqueued_messages.order(:position).pluck(:content)
  end
end
