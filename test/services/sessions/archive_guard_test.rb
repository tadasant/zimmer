# frozen_string_literal: true

require "test_helper"

class Sessions::ArchiveGuardTest < ActiveSupport::TestCase
  test "a session with nothing queued is not blocked" do
    assert_not Sessions::ArchiveGuard.blocked?(sessions(:running))
    assert_empty Sessions::ArchiveGuard.pending_messages(sessions(:running))
  end

  test "only pending messages block an archive" do
    session = sessions(:running)
    session.enqueued_messages.create!(content: "in flight", position: 1, status: "processing")
    session.enqueued_messages.create!(content: "already retired", position: 2, status: "undelivered")

    assert_not Sessions::ArchiveGuard.blocked?(session),
      "a claimed message is being delivered and a retired one is terminal — neither is a discard"
  end

  test "pending messages come back in queue order" do
    session = sessions(:running)
    session.enqueued_messages.create!(content: "second", position: 2, status: "pending")
    session.enqueued_messages.create!(content: "first", position: 1, status: "pending")

    assert_equal %w[first second], Sessions::ArchiveGuard.pending_messages(session).map(&:content)
  end

  # The refusal is what a self-archiving agent reads, so its job is to talk the
  # caller out of archiving before it mentions the way through.
  test "the refusal leads with not archiving and names force last" do
    session = sessions(:running)
    messages = [ session.enqueued_messages.create!(content: "add the onion back", position: 1) ]

    text = Sessions::ArchiveGuard.refusal_message(session, messages)

    assert_includes text, "Cannot archive session #{session.id}"
    assert_includes text, "1 queued message has not been delivered"
    assert_includes text, "add the onion back"
    assert_operator text.index("Do not archive"), :<, text.index("force"),
      "the discouragement has to come before the escape hatch"
  end

  test "the refusal pluralises and previews every message" do
    session = sessions(:running)
    messages = [
      session.enqueued_messages.create!(content: "first", position: 1),
      session.enqueued_messages.create!(content: "second", position: 2)
    ]

    text = Sessions::ArchiveGuard.refusal_message(session, messages)

    assert_includes text, "2 queued messages have not been delivered"
    assert_includes text, "Archiving discards them."
    assert_includes text, "1. first"
    assert_includes text, "2. second"
  end

  test "an over-long message is truncated rather than pasted whole into the error" do
    session = sessions(:running)
    messages = [ session.enqueued_messages.create!(content: "x" * 500, position: 1) ]

    text = Sessions::ArchiveGuard.refusal_message(session, messages)

    assert_includes text, "..."
    assert_operator text.length, :<, 500 + 800
  end

  test "the human summary says what is lost without the agent instructions" do
    session = sessions(:running)
    messages = [ session.enqueued_messages.create!(content: "add the onion back", position: 1) ]

    summary = Sessions::ArchiveGuard.summary(messages)

    assert_equal "This session has 1 queued message that has not been delivered. Archiving discards it.", summary
    assert_not_includes summary, "force"
  end
end
