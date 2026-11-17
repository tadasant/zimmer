# frozen_string_literal: true

require "test_helper"

# EnqueuedMessage#reorder_to and Sessions::RemoveQueuedMessage (its entry
# points, including the processor's delivery) run against another writer
# holding the same queue open on a second connection.
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
class EnqueuedMessageQueueConcurrencyTest < ActiveSupport::TestCase
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

  test "a delete waits for an open reorder and closes the gap where the row ended up" do
    # A moves to 3 and holds its transaction open: B1 C2 A3 D4, uncommitted.
    # B, loaded at 2 before that, is deleted meanwhile. Read from the stale 2,
    # the gap would close behind the wrong row and collide at COMMIT.
    contender_blocked = race(holding: -> { EnqueuedMessage.find(@a.id).reorder_to(3) }) do
      Sessions::RemoveQueuedMessage.call(@b)
    end

    assert contender_blocked, "the delete must wait while a reorder holds the queue lock"
    assert_equal %w[C A D], queue_contents
    assert_equal [ 1, 2, 3 ], @session.enqueued_messages.order(:position).pluck(:position)
  end

  test "a reorder waits for an open delete and moves within the queue it left" do
    # B is deleted and the delete held open: A1 C2 D3, uncommitted. D, loaded at
    # 4 before that, moves to 1 meanwhile.
    contender_blocked = race(holding: -> { Sessions::RemoveQueuedMessage.call(EnqueuedMessage.find(@b.id)) }) do
      @d.reorder_to(1)
    end

    assert contender_blocked, "the reorder must wait while a delete holds the queue lock"
    assert_equal %w[D A C], queue_contents
    assert_equal [ 1, 2, 3 ], @session.enqueued_messages.order(:position).pluck(:position)
  end

  test "a withdrawal waits for an open delivery claim and leaves the message it delivered" do
    # The processor claims A (pending -> processing) under the session's row
    # lock, destroys it and closes the gap, and holds its transaction open.
    # A's sender, holding a copy loaded while A was still pending, withdraws it
    # meanwhile. Checked outside the lock, A reads as pending and the withdrawal
    # reports it destroyed — the caller then discards the attachments of a
    # message that is being delivered.
    stale = EnqueuedMessage.find(@a.id)
    withdrawn = nil
    contender_blocked = race(
      holding: -> {
        delivered = EnqueuedMessageProcessorService.new(Session.find(@session.id), revalidate: false).process_next_message
        raise "the delivery failed" unless delivered
      }
    ) { withdrawn = Sessions::RemoveQueuedMessage.withdraw_pending(stale) }

    assert contender_blocked, "the withdrawal must wait while a delivery holds the session lock"
    assert_nil withdrawn, "a message the processor claimed is not the sender's to withdraw"
    assert_equal %w[B C D], queue_contents
    assert_equal [ 1, 2, 3 ], @session.enqueued_messages.order(:position).pluck(:position)
  end

  test "a withdrawal waits for an open retirement and leaves the retired message" do
    # A is retired `undelivered` by a writer that takes no session lock
    # (EnqueuedMessage#retire_as_stale!), held open. A withdrawal that read the
    # status without locking the row would see `pending`, then delete the row
    # once the retirement committed.
    stale = EnqueuedMessage.find(@a.id)
    withdrawn = nil
    contender_blocked = race(holding: -> { EnqueuedMessage.find(@a.id).retire_as_stale! }) do
      withdrawn = Sessions::RemoveQueuedMessage.withdraw_pending(stale)
    end

    assert contender_blocked, "the withdrawal must wait while the row's status is being written"
    assert_nil withdrawn
    assert_equal [ [ "A", 1, "undelivered" ], [ "B", 2, "pending" ], [ "C", 3, "pending" ], [ "D", 4, "pending" ] ],
                 @session.enqueued_messages.order(:position).pluck(:content, :position, :status)
  end

  test "a delete waits for an open delivery and closes the gap where the delivery left the row" do
    # The processor delivers A, removes it and closes the gap behind it, and
    # holds its transaction open: B1 C2 D3, uncommitted. C, loaded at 3 before
    # that, is deleted meanwhile. Read from the stale 3, the gap would close
    # behind the wrong row.
    stale = EnqueuedMessage.find(@c.id)
    removed = nil
    contender_blocked = race(
      holding: -> {
        delivered = EnqueuedMessageProcessorService.new(Session.find(@session.id), revalidate: false).process_next_message
        raise "the delivery failed" unless delivered
      }
    ) { removed = Sessions::RemoveQueuedMessage.call(stale) }

    assert contender_blocked, "the delete must wait while a delivery holds the queue"
    assert_equal 2, removed
    assert_equal %w[B D], queue_contents
    assert_equal [ 1, 2 ], @session.enqueued_messages.order(:position).pluck(:position)
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
