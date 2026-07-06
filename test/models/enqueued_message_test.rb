require "test_helper"

class EnqueuedMessageTest < ActiveSupport::TestCase
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
end
