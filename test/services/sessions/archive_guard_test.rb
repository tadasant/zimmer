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

  # --- guarded_archive! (#1139) ---------------------------------------------
  #
  # Production session 16494, 2026-09-11T10:47:02Z: a held backstop wake was
  # enqueued in the same second the woken turn self-archived. The guard had read
  # an empty queue unlocked, the archive went through, and the retirement
  # callback stranded the wake and paged. The helper's queue read has to happen
  # under the row lock the enqueuers serialize on.

  # Simulates an enqueuer that held the session row, inserted, and committed just
  # before the archive took the lock — the interleaving the unlocked read lost.
  # Outside the lock's transaction, so the refusal's rollback does not take the
  # row with it: the real enqueuer had already committed.
  def enqueue_as_the_lock_is_taken(session, content)
    session.define_singleton_method(:with_lock) do |*args, **kwargs, &block|
      enqueued_messages.create!(content: content, position: 1, status: "pending")
      super(*args, **kwargs, &block)
    end
  end

  test "guarded_archive! refuses a message that was committed just before the lock" do
    session = sessions(:running)
    enqueue_as_the_lock_is_taken(session, "Backstop wake: re-poll child")
    ErrorReporter.expects(:report_message).never

    error = assert_raises(Sessions::ArchiveGuard::Refused) do
      Sessions::ArchiveGuard.guarded_archive!(session, force: false, actor: "a test")
    end

    assert_equal [ "Backstop wake: re-poll child" ], error.messages.map(&:content)
    assert_equal "running", session.reload.status, "a refusal must not archive"
    assert_equal "pending", session.enqueued_messages.sole.status, "the wake is still owed delivery"
  end

  test "guarded_archive! reads the queue only after taking the row lock" do
    session = sessions(:running)
    sql = []
    subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
      sql << payload[:sql]
    end
    Sessions::ArchiveGuard.guarded_archive!(session, force: false, actor: "a test")
    ActiveSupport::Notifications.unsubscribe(subscriber)

    lock_at = sql.index { |query| query.match?(/FROM "sessions".*FOR UPDATE/m) }
    queue_at = sql.index { |query| query.match?(/SELECT "enqueued_messages"\.\* FROM "enqueued_messages"/) }
    assert lock_at, "expected a FOR UPDATE on the session row, got: #{sql.inspect}"
    assert queue_at, "expected a read of the pending queue, got: #{sql.inspect}"
    assert_operator lock_at, :<, queue_at, "the queue must be read under the lock, not before it"
  end

  test "guarded_archive! archives an empty queue and records the actor" do
    session = sessions(:running)

    assert Sessions::ArchiveGuard.guarded_archive!(session, force: false, actor: "a test caller")

    assert_equal "archived", session.reload.status
    assert session.logs.where("content LIKE ?", "%Session moved to trash by a test caller%").exists?
  end

  # The forced branch still retires and records rather than pages — the
  # strand callback's own specs cover the ledger line.
  test "guarded_archive! with force archives over the queue without paging" do
    session = sessions(:running)
    queued = session.enqueued_messages.create!(content: "read and discarded", position: 1, status: "pending")
    ErrorReporter.expects(:report_message).never

    assert Sessions::ArchiveGuard.guarded_archive!(session, force: true, actor: "a test")

    assert_equal "archived", session.reload.status
    assert_equal "undelivered", queued.reload.status
  end

  test "guarded_archive! runs the caller's block after the queue check and before the transition" do
    session = sessions(:running)
    session.enqueued_messages.create!(content: "queued", position: 1, status: "pending")
    ran = false

    assert_raises(Sessions::ArchiveGuard::Refused) do
      Sessions::ArchiveGuard.guarded_archive!(session, force: false, actor: "a test") { ran = true }
    end
    assert_not ran, "a live-turn refusal must not come ahead of the queue refusal"

    statuses = []
    Sessions::ArchiveGuard.guarded_archive!(session, force: true, actor: "a test") { statuses << session.status }
    assert_equal [ "running" ], statuses
    assert_equal "archived", session.reload.status
  end

  test "guarded_archive! lets the block refuse without archiving" do
    session = sessions(:running)

    assert_raises(RuntimeError) do
      Sessions::ArchiveGuard.guarded_archive!(session, force: false, actor: "a test") { raise "live turn" }
    end
    assert_equal "running", session.reload.status
  end

  test "guarded_archive! answers false when a concurrent archive won the lock" do
    session = sessions(:running)
    Session.find(session.id).archive!

    assert_equal false, Sessions::ArchiveGuard.guarded_archive!(session, force: false, actor: "a test")
    assert_equal "archived", session.status, "the lock reloaded the row"
  end

  test "message_count is not part of the module's surface" do
    assert_not Sessions::ArchiveGuard.respond_to?(:message_count)
  end
end
