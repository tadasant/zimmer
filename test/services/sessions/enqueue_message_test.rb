require "test_helper"
require "mocha/minitest"

# Sessions::EnqueueMessage is the single writer behind the three "add to queue"
# doors: the web queue form, the REST enqueued-messages endpoint and the
# `create` action of the `manage_enqueued_messages` MCP tool. What matters here
# is what it leaves behind — a pending message at the tail and one log row in
# one wording, committed together — that the tail is read under a lock on the
# session, and that an invalid message comes back with its errors rather than
# raising.
class Sessions::EnqueueMessageTest < ActiveSupport::TestCase
  def setup
    Session.any_instance.stubs(:broadcast_status_change)
    Session.any_instance.stubs(:broadcast_update_to_sessions_index)
    Session.any_instance.stubs(:broadcast_create_to_sessions_index)
  end

  def make_session(**attrs)
    Session.create!({
      agent_runtime: "claude_code",
      status: :needs_input,
      prompt: "p",
      mcp_servers: [],
      config: {},
      git_root: "https://github.com/test/repo.git",
      branch: "main"
    }.merge(attrs))
  end

  def enqueue(session, **overrides)
    Sessions::EnqueueMessage.call(**{
      session: session,
      content: "Run the tests",
      goal: nil,
      source_context: { "surface" => "web" }
    }.merge(overrides))
  end

  test "enqueues a pending message at position 1 on an empty queue" do
    session = make_session

    message = enqueue(session, goal: "All tests pass", source_context: { "surface" => "api" })

    assert message.persisted?
    assert_equal session, message.session
    assert_equal "Run the tests", message.content
    assert_equal "All tests pass", message.goal
    assert_equal 1, message.position
    assert_equal "pending", message.status
    assert_equal({ "surface" => "api" }, message.source_context)
  end

  test "enqueues behind the highest position, whatever its status" do
    session = make_session
    session.enqueued_messages.create!(content: "first", position: 1, status: "pending")
    session.enqueued_messages.create!(content: "parked", position: 4, status: "undelivered")

    assert_equal 5, enqueue(session).position
    assert_equal 6, enqueue(session).position
  end

  test "lands after a follow-up queued through Sessions::QueueFollowUp, and before the next one" do
    session = make_session

    first = enqueue(session)
    follow_up = Sessions::QueueFollowUp.call(session: session, prompt: "f", goal: nil, source_context: {})
    last = enqueue(session)

    assert_equal [ 1, 2, 3 ], [ first, follow_up, last ].map(&:position)
  end

  test "writes one log row in the enqueue wording" do
    session = make_session
    session.enqueued_messages.create!(content: "ahead", position: 1, status: "pending")

    assert_difference -> { session.logs.count }, 1 do
      enqueue(session)
    end

    log = session.logs.order(:id).last
    assert_equal "Enqueued message added at position 2", log.content
    assert_equal "info", log.level
  end

  test "records attachment descriptors when given and leaves the defaults when not" do
    session = make_session
    image = { "path" => "/tmp/x.png", "filename" => "x.png" }

    with = enqueue(session, images: [ image ], files: [])
    without = enqueue(session)

    assert_equal [ image ], with.images
    assert_equal [], with.files
    assert_equal EnqueuedMessage.new.images, without.images
    assert_equal EnqueuedMessage.new.files, without.files
  end

  test "reads the tail under a row lock on the session, inside the insert's transaction" do
    session = make_session
    statements = []
    subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
      statements << payload[:sql]
    end

    begin
      enqueue(session)
    ensure
      ActiveSupport::Notifications.unsubscribe(subscriber)
    end
    lock_index = statements.index { |sql| sql.include?('FROM "sessions"') && sql.include?("FOR NO KEY UPDATE") }
    max_index = statements.index { |sql| sql.include?("MAX(") && sql.include?("enqueued_messages") }
    insert_index = statements.index { |sql| sql.start_with?('INSERT INTO "enqueued_messages"') }
    assert lock_index, "expected a SELECT ... FOR NO KEY UPDATE on the session"
    assert max_index, "expected the MAX(position) read"
    assert insert_index, "expected the INSERT"
    assert_operator lock_index, :<, max_index, "the lock must be taken before the tail is read"
    assert_operator max_index, :<, insert_index
    assert_not statements[lock_index..insert_index].any? { |sql| sql.start_with?("RELEASE SAVEPOINT", "COMMIT") },
      "the lock must still be held when the row is inserted"
  end

  test "an invalid message comes back unpersisted with its errors, and writes nothing" do
    session = make_session

    message = nil
    assert_no_difference [ "EnqueuedMessage.count", "Log.count" ] do
      message = enqueue(session, content: "x" * (Session::PROMPT_MAX_LENGTH + 1))
    end

    assert_not message.persisted?
    assert message.errors[:content].any?
  end

  test "a log row that fails to write takes the queued message back with it" do
    session = make_session
    Log.any_instance.stubs(:save!).raises(ActiveRecord::RecordInvalid.new(Log.new))

    assert_no_difference "EnqueuedMessage.count" do
      assert_raises(ActiveRecord::RecordInvalid) { enqueue(session) }
    end
  end

  test "does not reload the caller's instance" do
    session = make_session
    session.title = "unsaved edit"

    enqueue(session)

    assert_equal "unsaved edit", session.title
  end
end
