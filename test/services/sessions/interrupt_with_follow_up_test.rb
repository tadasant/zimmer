require "test_helper"
require "mocha/minitest"

# Sessions::InterruptWithFollowUp is the single writer behind every "send this
# new message now" door: REST and MCP `follow_up` with `force_immediate`,
# `manage_enqueued_messages` `send_now`, and a child's `message_parent` with
# `force_immediate`. InterruptService is stubbed throughout: what is under test
# is the staging around it — where the message lands, that it is committed and
# handed over, and that a failed or raised interrupt takes it back unless a
# concurrent interrupt already claimed it.
class Sessions::InterruptWithFollowUpTest < ActiveSupport::TestCase
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

  def send_now(session, **overrides, &block)
    Sessions::InterruptWithFollowUp.call(**{
      session: session,
      prompt: "Stop and fix the test",
      actor: "test_actor"
    }.merge(overrides), &block)
  end

  # Stubs InterruptService.new, recording what it was handed, and answers `result`.
  def stub_interrupt(result = Sessions::Result.new(success: true), &on_call)
    captured = {}
    service = Object.new
    service.define_singleton_method(:call) do
      on_call&.call(captured[:enqueued_message])
      result
    end
    Sessions::InterruptService.stubs(:new).with do |session:, enqueued_message:, actor:|
      captured.merge!(session: session, enqueued_message: enqueued_message, actor: actor)
      true
    end.returns(service)
    captured
  end

  test "stages a pending message at the tail and hands it to the interrupt" do
    session = make_session
    session.enqueued_messages.create!(content: "ahead", position: 1, status: "pending")
    session.enqueued_messages.create!(content: "parked", position: 4, status: "undelivered")
    captured = stub_interrupt
    image = { "path" => "/tmp/x.png", "filename" => "x.png" }

    result = send_now(session, goal: "Tests pass", source_context: { "surface" => "api" },
                               origin: "caller", images: [ image ], files: [])

    assert result.success?
    refute result.withdrawn?
    message = result.enqueued_message
    assert_equal session.id, captured[:session].id
    assert_equal message, captured[:enqueued_message]
    assert_equal "test_actor", captured[:actor]
    assert_equal "Stop and fix the test", message.content
    assert_equal "Tests pass", message.goal
    assert_equal 5, message.position
    assert_equal "pending", message.status
    assert_equal "caller", message.origin
    assert_equal({ "surface" => "api" }, message.source_context)
    assert_equal [ image ], message.images
    assert_equal [], message.files
  end

  test "leaves the column defaults when the optional attributes are omitted" do
    session = make_session
    stub_interrupt

    message = send_now(session).enqueued_message

    defaults = EnqueuedMessage.new
    assert_nil message.goal
    %i[origin source_context images files].each do |attribute|
      expected = defaults.public_send(attribute)
      expected.nil? ? assert_nil(message.public_send(attribute)) : assert_equal(expected, message.public_send(attribute))
    end
  end

  test "reads the tail under the same row lock as QueueFollowUp" do
    session = make_session
    stub_interrupt
    statements = []
    subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
      statements << payload[:sql]
    end

    begin
      send_now(session)
    ensure
      ActiveSupport::Notifications.unsubscribe(subscriber)
    end
    lock_index = statements.index { |sql| sql.include?('FROM "sessions"') && sql.include?("FOR NO KEY UPDATE") }
    max_index = statements.index { |sql| sql.include?("MAX(") && sql.include?("enqueued_messages") }
    assert lock_index, "expected a SELECT ... FOR NO KEY UPDATE on the session"
    assert max_index, "expected the MAX(position) read"
    assert_operator lock_index, :<, max_index, "the lock must be taken before the tail is read"
  end

  test "takes the next position after one QueueFollowUp wrote, and vice versa" do
    session = make_session
    stub_interrupt

    queued = Sessions::QueueFollowUp.call(session: session, prompt: "q", goal: nil, source_context: {})
    staged = send_now(session).enqueued_message

    assert_equal queued.position + 1, staged.position
    assert_equal staged.position + 1,
                 Sessions::QueueFollowUp.call(session: session, prompt: "q2", goal: nil, source_context: {}).position
  end

  # InterruptService takes a per-session advisory lock; holding the staging
  # transaction (and its row lock) open across it is how two locks deadlock.
  test "commits the staged message before the interrupt runs" do
    session = make_session
    depth_outside = ActiveRecord::Base.connection.open_transactions
    depth_during = nil
    stub_interrupt { depth_during = ActiveRecord::Base.connection.open_transactions }

    send_now(session)

    assert_equal depth_outside, depth_during
  end

  test "runs the caller's block with the staged message, before the interrupt" do
    session = make_session
    order = []
    stub_interrupt { order << :interrupt }

    yielded = nil
    result = send_now(session) do |message|
      yielded = message
      order << :block
    end

    assert_equal result.enqueued_message, yielded
    assert yielded.persisted?
    assert_equal %i[block interrupt], order
  end

  test "a failed interrupt withdraws the still-pending message and reports why" do
    session = make_session
    stub_interrupt(Sessions::Result.new(success: false, error: "nope", error_code: :conflict))

    result = send_now(session)

    refute result.success?
    assert result.withdrawn?
    assert_equal "nope", result.error
    assert_equal :conflict, result.error_code
    assert_empty session.enqueued_messages.reload
  end

  test "a failed interrupt leaves a message a concurrent interrupt already claimed" do
    session = make_session
    stub_interrupt(Sessions::Result.new(success: false, error: "busy")) { |message| message.update!(status: "processing") }

    result = send_now(session)

    refute result.success?
    refute result.withdrawn?
    assert_equal [ "processing" ], session.enqueued_messages.reload.map(&:status)
  end

  test "a failed interrupt whose message was already delivered and destroyed withdraws nothing" do
    session = make_session
    stub_interrupt(Sessions::Result.new(success: false, error: "gone")) { |message| EnqueuedMessage.where(id: message.id).delete_all }

    result = send_now(session)

    refute result.success?
    refute result.withdrawn?
  end

  test "an interrupt that raises withdraws the message and re-raises" do
    session = make_session
    stub_interrupt { raise "kaboom" }

    error = assert_raises(RuntimeError) { send_now(session) }

    assert_equal "kaboom", error.message
    assert_empty session.enqueued_messages.reload
  end

  test "a block that raises withdraws the message and never interrupts" do
    session = make_session
    Sessions::InterruptService.expects(:new).never

    assert_raises(ArgumentError) { send_now(session) { raise ArgumentError, "capture failed" } }

    assert_empty session.enqueued_messages.reload
  end

  test "an invalid message stages nothing and never interrupts" do
    session = make_session
    Sessions::InterruptService.expects(:new).never

    assert_no_difference "EnqueuedMessage.count" do
      assert_raises(ActiveRecord::RecordInvalid) do
        send_now(session, prompt: "x" * (Session::PROMPT_MAX_LENGTH + 1))
      end
    end
  end
end
