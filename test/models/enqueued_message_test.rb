require "test_helper"

class EnqueuedMessageTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  # Test associations
  test "should belong to session" do
    session = sessions(:running)
    message = session.enqueued_messages.create!(
      content: "Test message",
      position: 1
    )
    assert_respond_to message, :session
    assert_kind_of Session, message.session
  end

  test "should require session association" do
    message = EnqueuedMessage.new(content: "Test message", position: 1)
    assert_not message.valid?
    assert_raises(ActiveRecord::RecordInvalid) do
      message.save!
    end
  end

  # Test validations
  test "should require content presence" do
    session = sessions(:running)
    message = EnqueuedMessage.new(session: session, position: 1)
    assert_not message.valid?
    assert_includes message.errors[:content], "can't be blank"
  end

  test "should validate content length" do
    session = sessions(:running)
    message = EnqueuedMessage.new(
      session: session,
      content: "a" * (Session::PROMPT_MAX_LENGTH + 1),
      position: 1
    )
    assert_not message.valid?
    assert_includes message.errors[:content], "is too long (maximum #{Session::PROMPT_MAX_LENGTH.to_fs(:delimited)} characters)"
  end

  test "should accept valid content length" do
    session = sessions(:running)
    message = EnqueuedMessage.new(
      session: session,
      content: "a" * Session::PROMPT_MAX_LENGTH,
      position: 1
    )
    assert message.valid?
  end

  test "should validate goal length when present" do
    session = sessions(:running)
    message = EnqueuedMessage.new(
      session: session,
      content: "Test message",
      goal: "a" * (Session::GOAL_MAX_LENGTH + 1),
      position: 1
    )
    assert_not message.valid?
    assert_includes message.errors[:goal], "is too long (maximum #{Session::GOAL_MAX_LENGTH.to_fs(:delimited)} characters)"
  end

  test "should accept valid goal length" do
    session = sessions(:running)
    message = EnqueuedMessage.new(
      session: session,
      content: "Test message",
      goal: "a" * Session::GOAL_MAX_LENGTH,
      position: 1
    )
    assert message.valid?
  end

  test "should allow nil goal" do
    session = sessions(:running)
    message = EnqueuedMessage.new(
      session: session,
      content: "Test message",
      goal: nil,
      position: 1
    )
    assert message.valid?
  end

  test "should require position presence" do
    session = sessions(:running)
    message = EnqueuedMessage.new(session: session, content: "Test message")
    assert_not message.valid?
    assert_includes message.errors[:position], "can't be blank"
  end

  test "should validate position is greater than zero" do
    session = sessions(:running)
    message = EnqueuedMessage.new(
      session: session,
      content: "Test message",
      position: 0
    )
    assert_not message.valid?
    assert_includes message.errors[:position], "must be greater than 0"
  end

  test "should validate status inclusion" do
    session = sessions(:running)
    message = EnqueuedMessage.new(
      session: session,
      content: "Test message",
      position: 1,
      status: "invalid_status"
    )
    assert_not message.valid?
    assert_includes message.errors[:status], "invalid_status is not a valid status"
  end

  test "should accept pending status" do
    session = sessions(:running)
    message = EnqueuedMessage.new(
      session: session,
      content: "Test message",
      position: 1,
      status: "pending"
    )
    assert message.valid?
  end

  test "should accept processing status" do
    session = sessions(:running)
    message = EnqueuedMessage.new(
      session: session,
      content: "Test message",
      position: 1,
      status: "processing"
    )
    assert message.valid?
  end

  test "should accept sent status" do
    session = sessions(:running)
    message = EnqueuedMessage.new(
      session: session,
      content: "Test message",
      position: 1,
      status: "sent"
    )
    assert message.valid?
  end

  test "should default status to pending" do
    session = sessions(:running)
    message = session.enqueued_messages.create!(
      content: "Test message",
      position: 1
    )
    assert_equal "pending", message.status
  end

  # Test scopes
  test "pending scope should return only pending messages" do
    session = sessions(:running)
    pending_msg = session.enqueued_messages.create!(
      content: "Pending message",
      position: 1,
      status: "pending"
    )
    processing_msg = session.enqueued_messages.create!(
      content: "Processing message",
      position: 2,
      status: "processing"
    )
    sent_msg = session.enqueued_messages.create!(
      content: "Sent message",
      position: 3,
      status: "sent"
    )

    pending_messages = session.enqueued_messages.pending
    assert_includes pending_messages, pending_msg
    assert_not_includes pending_messages, processing_msg
    assert_not_includes pending_messages, sent_msg
  end

  test "ordered scope should return messages ordered by position" do
    session = sessions(:running)
    msg3 = session.enqueued_messages.create!(content: "Third", position: 3)
    msg1 = session.enqueued_messages.create!(content: "First", position: 1)
    msg2 = session.enqueued_messages.create!(content: "Second", position: 2)

    ordered_messages = session.enqueued_messages.ordered
    assert_equal [ msg1, msg2, msg3 ], ordered_messages.to_a
  end

  # Test mark_as_sent! method
  test "mark_as_sent! should update status to sent" do
    session = sessions(:running)
    message = session.enqueued_messages.create!(
      content: "Test message",
      position: 1,
      status: "processing"
    )

    message.mark_as_sent!
    assert_equal "sent", message.status
  end

  # Test reorder_to method
  test "reorder_to should move message down and adjust other positions" do
    session = sessions(:running)
    msg1 = session.enqueued_messages.create!(content: "First", position: 1)
    msg2 = session.enqueued_messages.create!(content: "Second", position: 2)
    msg3 = session.enqueued_messages.create!(content: "Third", position: 3)
    msg4 = session.enqueued_messages.create!(content: "Fourth", position: 4)

    # Move msg1 to position 3
    msg1.reorder_to(3)

    msg1.reload
    msg2.reload
    msg3.reload
    msg4.reload

    assert_equal 3, msg1.position
    assert_equal 1, msg2.position
    assert_equal 2, msg3.position
    assert_equal 4, msg4.position
  end

  test "reorder_to should move message up and adjust other positions" do
    session = sessions(:running)
    msg1 = session.enqueued_messages.create!(content: "First", position: 1)
    msg2 = session.enqueued_messages.create!(content: "Second", position: 2)
    msg3 = session.enqueued_messages.create!(content: "Third", position: 3)
    msg4 = session.enqueued_messages.create!(content: "Fourth", position: 4)

    # Move msg4 to position 2
    msg4.reorder_to(2)

    msg1.reload
    msg2.reload
    msg3.reload
    msg4.reload

    assert_equal 1, msg1.position
    assert_equal 3, msg2.position
    assert_equal 4, msg3.position
    assert_equal 2, msg4.position
  end

  test "reorder_to should not change positions if moving to same position" do
    session = sessions(:running)
    msg1 = session.enqueued_messages.create!(content: "First", position: 1)
    msg2 = session.enqueued_messages.create!(content: "Second", position: 2)

    initial_updated_at = msg1.updated_at

    # Move msg1 to its current position
    msg1.reorder_to(1)

    msg1.reload
    msg2.reload

    assert_equal 1, msg1.position
    assert_equal 2, msg2.position
  end

  # Test Session association methods
  test "session should have enqueued_messages association" do
    session = sessions(:running)
    assert_respond_to session, :enqueued_messages
  end

  test "session next_enqueued_message should return first pending message by position" do
    session = sessions(:running)
    msg1 = session.enqueued_messages.create!(
      content: "First",
      position: 1,
      status: "sent"
    )
    msg2 = session.enqueued_messages.create!(
      content: "Second",
      position: 2,
      status: "pending"
    )
    msg3 = session.enqueued_messages.create!(
      content: "Third",
      position: 3,
      status: "pending"
    )

    assert_equal msg2, session.next_enqueued_message
  end

  test "session next_enqueued_message should return nil when no pending messages" do
    session = sessions(:running)
    session.enqueued_messages.create!(
      content: "First",
      position: 1,
      status: "sent"
    )

    assert_nil session.next_enqueued_message
  end

  test "session process_next_enqueued_message! should mark message as processing" do
    session = sessions(:running)
    message = session.enqueued_messages.create!(
      content: "Test message",
      position: 1,
      status: "pending"
    )

    result = session.process_next_enqueued_message!
    assert_equal message, result
    assert_equal "processing", result.status
  end

  test "session process_next_enqueued_message! should return nil when no pending messages" do
    session = sessions(:running)
    assert_nil session.process_next_enqueued_message!
  end

  # Test dependent destroy
  test "destroying session should destroy associated enqueued messages" do
    session = sessions(:running)
    message = session.enqueued_messages.create!(
      content: "Test message",
      position: 1
    )

    assert_difference "EnqueuedMessage.count", -1 do
      session.destroy
    end
  end

  # (session_id, position) uniqueness is DEFERRABLE INITIALLY DEFERRED.
  #
  # Every renumbering path on this table transiently puts two rows on the same
  # position — a bulk `position = position - 1` is only collision-free if rows
  # are visited in ascending position order, and nothing in a bulk UPDATE pins
  # the planner's scan order. Deferring the check to commit makes the
  # intermediate state legal without weakening the invariant. See
  # db/migrate/20260803170000_defer_enqueued_message_position_uniqueness.rb.
  test "position uniqueness constraint is deferred" do
    constraint = ActiveRecord::Base.connection
                                   .unique_constraints("enqueued_messages")
                                   .find { |c| c.column == [ "session_id", "position" ] }

    assert constraint, "expected a unique constraint on (session_id, position)"
    assert_equal :deferred, constraint.deferrable
  end

  test "deferred constraint tolerates a transient duplicate position" do
    session = sessions(:running)
    messages = (1..3).map { |i| session.enqueued_messages.create!(content: "m#{i}", position: i) }

    # The hazardous order: 3 -> 2 lands while another row still holds 2. Under a
    # non-deferred unique index this raises RecordNotUnique on the first move.
    messages[0].destroy!
    messages[2].update_column(:position, 2)
    messages[1].update_column(:position, 1)

    # Prove the end state is actually committable, not merely unchecked: forcing
    # the deferred constraint to IMMEDIATE runs the check the COMMIT would run.
    ActiveRecord::Base.connection.execute("SET CONSTRAINTS ALL IMMEDIATE")

    assert_equal [ 1, 2 ], session.enqueued_messages.ordered.pluck(:position)
  end

  test "duplicate positions are still rejected, at commit time" do
    session = sessions(:running)
    session.enqueued_messages.create!(content: "first", position: 1)
    second = session.enqueued_messages.create!(content: "second", position: 2)

    assert_raises(ActiveRecord::RecordNotUnique) do
      ActiveRecord::Base.transaction(requires_new: true) do
        # Deferred: the write itself succeeds and leaves two rows on position 1.
        second.update_column(:position, 1)
        # Whatever the transaction would have hit at COMMIT, hit here instead.
        ActiveRecord::Base.connection.execute("SET CONSTRAINTS ALL IMMEDIATE")
      end
    end
  end

  test "undelivered is a valid status and is not pending" do
    session = sessions(:running)
    message = session.enqueued_messages.create!(content: "never sent", position: 1)

    message.mark_undelivered!

    assert_equal "undelivered", message.reload.status
    assert_empty session.enqueued_messages.pending
    assert_equal [ message ], session.enqueued_messages.undelivered.to_a
  end

  # `undelivered` is terminal: the claim query only ever takes `pending` rows, so
  # a retired message cannot resurface as a surprise turn if the session is
  # unarchived weeks later.
  test "an undelivered message is never claimed for delivery" do
    session = sessions(:running)
    session.enqueued_messages.create!(content: "never sent", position: 1, status: "undelivered")

    assert_nil session.process_next_enqueued_message!
  end

  # The `pause` callback catches a message that arrives before a session comes
  # to rest. This catches one that arrives after it already has: none of the
  # three create surfaces checks the session's state, and all three answer that
  # the message will go out "when the session becomes idle" — which, for a
  # session in needs_input, it already is. Nothing would have come back for it:
  # HeartbeatSweepJob, the only sweep that wakes an idle session, skips one that
  # has a pending message.
  test "queueing onto an already-idle session schedules its delivery" do
    session = sessions(:needs_input)

    assert_enqueued_with(job: EnqueuedMessageDrainJob, args: [ session.id ]) do
      session.enqueued_messages.create!(content: "you are already idle", position: 1)
    end
  end

  test "queueing onto a running session schedules nothing" do
    session = sessions(:running)

    assert_no_enqueued_jobs(only: EnqueuedMessageDrainJob) do
      session.enqueued_messages.create!(content: "wait your turn", position: 1)
    end
  end

  # Only a message that is actually waiting to be delivered is worth a drain.
  test "a message created already claimed schedules nothing" do
    session = sessions(:needs_input)

    assert_no_enqueued_jobs(only: EnqueuedMessageDrainJob) do
      session.enqueued_messages.create!(content: "in flight", position: 1, status: "processing")
    end
  end

  test "an unknown status is still rejected" do
    session = sessions(:running)
    message = session.enqueued_messages.new(content: "x", position: 1, status: "dropped")

    assert_not message.valid?
    assert_includes message.errors[:status], "dropped is not a valid status"
  end

  # Origin — who wrote the message. See EnqueuedMessage::ORIGINS.
  test "defaults to the caller origin" do
    message = sessions(:running).enqueued_messages.create!(content: "queued by a human", position: 1)

    assert_equal "caller", message.origin
    assert_not message.archive_satisfied?
  end

  test "rejects an origin that is not in the vocabulary" do
    message = EnqueuedMessage.new(session: sessions(:running), content: "x", position: 1, origin: "nonsense")

    assert_not message.valid?
    assert_includes message.errors[:origin], "nonsense is not a valid origin"
  end

  # An archive complies with the PR-merged notice rather than discarding it: its
  # whole instruction is "the PR merged, archive if nothing is left in scope".
  test "only the PR-merged notice is satisfied by an archive" do
    session = sessions(:running)

    merged = session.enqueued_messages.create!(content: "merged", position: 1, origin: "automated_pr_merged")
    conflict = session.enqueued_messages.create!(content: "conflict", position: 2, origin: "automated_merge_conflict")

    assert merged.archive_satisfied?
    assert_not conflict.archive_satisfied?,
      "an unresolved merge conflict stays true after the archive, and nothing else reports it"
  end
end
