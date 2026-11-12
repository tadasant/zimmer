require "test_helper"
require "mocha/minitest"

# Sessions::QueueFollowUp is the single writer behind the "a turn is already
# underway, so queue it" branch of all three follow-up doors: the web form, the
# REST endpoint and the `action_session` MCP tool. What matters here is the
# shape of what it leaves behind — a pending message at the tail of the queue
# and one log row in one wording — and that the position read is taken under a
# lock on the session, so concurrent follow-ups do not both read the same tail.
class Sessions::QueueFollowUpTest < ActiveSupport::TestCase
  def setup
    Session.any_instance.stubs(:broadcast_status_change)
    Session.any_instance.stubs(:broadcast_update_to_sessions_index)
    Session.any_instance.stubs(:broadcast_create_to_sessions_index)
  end

  def make_session(**attrs)
    Session.create!({
      agent_runtime: "claude_code",
      status: :running,
      prompt: "p",
      mcp_servers: [],
      config: {},
      git_root: "https://github.com/test/repo.git",
      branch: "main"
    }.merge(attrs))
  end

  def queue(session, **overrides)
    Sessions::QueueFollowUp.call(**{
      session: session,
      prompt: "Run the tests",
      goal: nil,
      source_context: { "surface" => "web" }
    }.merge(overrides))
  end

  test "queues a pending message at position 1 on an empty queue" do
    session = make_session

    message = queue(session, goal: "All tests pass", source_context: { "surface" => "api" })

    assert message.persisted?
    assert_equal session, message.session
    assert_equal "Run the tests", message.content
    assert_equal "All tests pass", message.goal
    assert_equal 1, message.position
    assert_equal "pending", message.status
    assert_equal({ "surface" => "api" }, message.source_context)
  end

  test "queues behind the highest position, whatever its status" do
    session = make_session
    session.enqueued_messages.create!(content: "first", position: 1, status: "pending")
    session.enqueued_messages.create!(content: "parked", position: 4, status: "undelivered")

    assert_equal 5, queue(session).position
    assert_equal 6, queue(session).position
  end

  test "writes one log row in the shared wording" do
    session = make_session
    session.enqueued_messages.create!(content: "ahead", position: 1, status: "pending")

    assert_difference -> { session.logs.count }, 1 do
      queue(session)
    end

    log = session.logs.order(:id).last
    assert_equal "Message queued at position 2 (a turn is already underway)", log.content
    assert_equal "info", log.level
  end

  test "records attachment descriptors when given and leaves the defaults when not" do
    session = make_session
    image = { "path" => "/tmp/x.png", "filename" => "x.png" }

    with = queue(session, images: [ image ], files: [])
    without = queue(session)

    assert_equal [ image ], with.images
    assert_equal [], with.files
    assert_equal EnqueuedMessage.new.images, without.images
    assert_equal EnqueuedMessage.new.files, without.files
  end

  test "reads the tail under a row lock on the session" do
    session = make_session
    statements = []
    subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
      statements << payload[:sql]
    end

    begin
      queue(session)
    ensure
      ActiveSupport::Notifications.unsubscribe(subscriber)
    end
    lock_index = statements.index { |sql| sql.include?('FROM "sessions"') && sql.include?("FOR NO KEY UPDATE") }
    max_index = statements.index { |sql| sql.include?("MAX(") && sql.include?("enqueued_messages") }
    assert lock_index, "expected a SELECT ... FOR NO KEY UPDATE on the session"
    assert max_index, "expected the MAX(position) read"
    assert_operator lock_index, :<, max_index, "the lock must be taken before the tail is read"
  end

  test "does not reload the caller's instance" do
    session = make_session
    session.title = "unsaved edit"

    queue(session)

    assert_equal "unsaved edit", session.title
  end

  test "an invalid message writes neither the message nor the log row" do
    session = make_session

    assert_no_difference [ "EnqueuedMessage.count", "Log.count" ] do
      assert_raises(ActiveRecord::RecordInvalid) do
        queue(session, prompt: "x" * (Session::PROMPT_MAX_LENGTH + 1))
      end
    end
  end

  test "a log row that fails to write takes the queued message back with it" do
    session = make_session
    Log.any_instance.stubs(:save!).raises(ActiveRecord::RecordInvalid.new(Log.new))

    assert_no_difference "EnqueuedMessage.count" do
      assert_raises(ActiveRecord::RecordInvalid) { queue(session) }
    end
  end
end
