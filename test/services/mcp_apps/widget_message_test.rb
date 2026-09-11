# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"

class McpApps::WidgetMessageTest < ActiveSupport::TestCase
  setup do
    @session = sessions(:needs_input)
  end

  def deliver(text: "roll again", kind: "message", session: @session)
    McpApps::WidgetMessage.deliver(
      session: session, server_name: "notion", tool: "open_panel", text: text, kind: kind
    )
  end

  test "a ui/message on a waiting session becomes a real turn" do
    AgentSessionJob.expects(:enqueue_with_prompt).once.returns(stub(job_id: "job-1"))
    BroadcastService.any_instance.stubs(:optimistic_user_message)

    result = deliver

    assert_equal :delivered, result.status
    # `resume` lands on `waiting`; the job it enqueued is what makes it running.
    assert @session.reload.waiting?
  end

  test "the prompt says where it came from" do
    captured = nil
    AgentSessionJob.expects(:enqueue_with_prompt).with { |_id, prompt, **| captured = prompt }.returns(stub(job_id: "j"))
    BroadcastService.any_instance.stubs(:optimistic_user_message)

    deliver

    assert_match "[MCP App message from notion/open_panel]", captured
    assert_match "roll again", captured
  end

  test "a ui/message lands in the queue when a turn is already underway" do
    Sessions::LiveTurn.stubs(:underway?).returns(true)
    AgentSessionJob.expects(:enqueue_with_prompt).never

    result = deliver

    assert_equal :queued, result.status
    assert_equal 1, @session.enqueued_messages.where(status: "pending").count
  end

  test "a context update never spends a turn, even on an idle session" do
    AgentSessionJob.expects(:enqueue_with_prompt).never

    result = deliver(kind: "context", text: '{"selected":3}')

    assert_equal :queued, result.status
    assert_match "context update", @session.enqueued_messages.last.content
  end

  test "an empty, oversized, or unknown-kind message is refused" do
    assert_equal :rejected, deliver(text: "   ").status
    assert_equal :rejected, deliver(text: "x" * (McpApps::WidgetMessage::MAX_LENGTH + 1)).status
    assert_equal :rejected, deliver(kind: "eval").status
  end

  test "a session that cannot take a message says so instead of raising" do
    result = deliver(session: sessions(:archived))

    assert_equal :rejected, result.status
    refute result.ok?
  end
end
