# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"

# Sessions::RemoveQueuedMessage is the single writer behind the three delete
# doors: the web delete, the REST DELETE and `manage_enqueued_messages`
# `delete`. What matters here is that it takes the queue lock, closes the gap
# from the position the row really holds (read under that lock, not from the
# caller's copy), leaves a vanished row's neighbours alone, and writes one log
# row with the position it really removed from. `withdraw_pending` does the
# same, only while the row is still `pending`, and writes no log row.
# `remove_delivered` does the same for a row the processor claimed and marked
# `sent`, also with no log row.
class Sessions::RemoveQueuedMessageTest < ActiveSupport::TestCase
  setup do
    @session = sessions(:running)
    @a, @b, @c, @d = %w[A B C D].each_with_index.map do |content, i|
      @session.enqueued_messages.create!(content: content, status: "pending", position: i + 1)
    end
  end

  test "removes the message, closes the gap and logs the position" do
    assert_difference -> { @session.logs.count }, 1 do
      assert_equal 2, Sessions::RemoveQueuedMessage.call(@b)
    end

    assert_equal [ [ "A", 1 ], [ "C", 2 ], [ "D", 3 ] ], queue
    assert_equal "Enqueued message at position 2 removed", @session.logs.order(:id).last.content
  end

  test "takes the session's queue lock" do
    Sessions::QueueTail.expects(:lock!).with(@session.id).once

    Sessions::RemoveQueuedMessage.call(@b)
  end

  test "closes the gap where the row really is, not where the caller's copy says" do
    stale = EnqueuedMessage.find(@a.id)
    EnqueuedMessage.find(@a.id).reorder_to(3) # B1 C2 A3 D4

    assert_equal 3, Sessions::RemoveQueuedMessage.call(stale)

    assert_equal [ [ "B", 1 ], [ "C", 2 ], [ "D", 3 ] ], queue
    assert_equal "Enqueued message at position 3 removed", @session.logs.order(:id).last.content
  end

  test "a row deleted since it was loaded removes nothing and logs nothing" do
    stale = EnqueuedMessage.find(@b.id)
    @b.destroy!

    assert_no_difference -> { @session.logs.count } do
      assert_nil Sessions::RemoveQueuedMessage.call(stale)
    end

    assert_equal [ [ "A", 1 ], [ "C", 3 ], [ "D", 4 ] ], queue
  end

  test "closes the gap in the message's own session only" do
    other = sessions(:needs_input)
    other_rows = (1..3).map { |i| other.enqueued_messages.create!(content: "other #{i}", status: "pending", position: i) }

    Sessions::RemoveQueuedMessage.call(@a)

    assert_equal [ 1, 2, 3 ], other_rows.map { |m| m.reload.position }
  end

  test "withdraw_pending removes a pending message and closes the gap without a log row" do
    assert_no_difference -> { @session.logs.count } do
      assert_equal 2, Sessions::RemoveQueuedMessage.withdraw_pending(@b)
    end

    assert_equal [ [ "A", 1 ], [ "C", 2 ], [ "D", 3 ] ], queue
  end

  test "withdraw_pending takes the session's queue lock" do
    Sessions::QueueTail.expects(:lock!).with(@session.id).once

    Sessions::RemoveQueuedMessage.withdraw_pending(@b)
  end

  test "withdraw_pending leaves a message that is no longer pending" do
    stale = EnqueuedMessage.find(@b.id)
    @b.update!(status: "processing")

    assert_nil Sessions::RemoveQueuedMessage.withdraw_pending(stale)

    assert_equal [ [ "A", 1 ], [ "B", 2 ], [ "C", 3 ], [ "D", 4 ] ], queue
  end

  test "withdraw_pending on a row deleted since it was loaded removes nothing" do
    stale = EnqueuedMessage.find(@b.id)
    @b.destroy!

    assert_nil Sessions::RemoveQueuedMessage.withdraw_pending(stale)

    assert_equal [ [ "A", 1 ], [ "C", 3 ], [ "D", 4 ] ], queue
  end

  test "remove_delivered removes a sent message and closes the gap without a log row" do
    @b.mark_as_sent!

    assert_no_difference -> { @session.logs.count } do
      assert_equal 2, Sessions::RemoveQueuedMessage.remove_delivered(@b)
    end

    assert_equal [ [ "A", 1 ], [ "C", 2 ], [ "D", 3 ] ], queue
  end

  test "remove_delivered takes the session's queue lock" do
    @b.mark_as_sent!
    Sessions::QueueTail.expects(:lock!).with(@session.id).once

    Sessions::RemoveQueuedMessage.remove_delivered(@b)
  end

  test "remove_delivered leaves a message that was not marked sent" do
    assert_nil Sessions::RemoveQueuedMessage.remove_delivered(@b)

    assert_equal [ [ "A", 1 ], [ "B", 2 ], [ "C", 3 ], [ "D", 4 ] ], queue
  end

  private

  def queue
    @session.enqueued_messages.order(:position).pluck(:content, :position)
  end
end
