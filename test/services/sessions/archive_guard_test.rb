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

  test "a session with a pending message is blocked" do
    session = sessions(:running)
    session.enqueued_messages.create!(content: "still queued", position: 1, status: "pending")

    assert Sessions::ArchiveGuard.blocked?(session)
  end

  # The bulk paths ask this per session and never read a body, so it must not
  # load one — content is validated up to PROMPT_MAX_LENGTH.
  test "blocked? answers without loading message bodies" do
    session = sessions(:running)
    session.enqueued_messages.create!(content: "x" * 5_000, position: 1, status: "pending")

    sql = []
    subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
      sql << payload[:sql]
    end
    Sessions::ArchiveGuard.blocked?(session)
    ActiveSupport::Notifications.unsubscribe(subscriber)

    assert sql.any? { |query| query.match?(/SELECT 1 AS one/i) },
      "expected an existence check, got: #{sql.inspect}"
  end

  # A caller that reads a per-session error inside a batch and does what it says
  # would otherwise force-discard queues it was never shown.
  test "the batch refusal names its own blast radius" do
    session = sessions(:running)
    messages = [ session.enqueued_messages.create!(content: "queued", position: 1) ]

    single = Sessions::ArchiveGuard.refusal_message(session, messages)
    batch = Sessions::ArchiveGuard.refusal_message(session, messages, batch: true)

    assert_not_includes single, "every session in the batch"
    assert_includes batch, "applies to every session in the batch"
  end

  test "message_count is not part of the module's surface" do
    assert_not Sessions::ArchiveGuard.respond_to?(:message_count)
  end
end
