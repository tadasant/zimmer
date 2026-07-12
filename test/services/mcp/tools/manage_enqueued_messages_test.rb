# frozen_string_literal: true

require "test_helper"

class Mcp::Tools::ManageEnqueuedMessagesTest < ActiveSupport::TestCase
  setup do
    @session = sessions(:needs_input)
    @tool = Mcp::Tools::ManageEnqueuedMessages.new(context: Mcp::Context.new(tool_groups: "sessions"))
  end

  test "create appends a message to the end of the queue" do
    @session.enqueued_messages.create!(content: "First", position: 1, status: "pending")

    output = @tool.call("session_id" => @session.id, "action" => "create", "content" => "Second", "goal" => "ship it")

    message = @session.enqueued_messages.order(:position).last
    assert_equal 2, message.position
    assert_equal "ship it", message.goal
    assert_includes output, "## Message Queued"
    assert_includes output, "- **Position:** 2"
    assert_includes output, "- **Status:** pending"
  end

  test "create without content raises" do
    error = assert_raises(Mcp::ToolError) do
      @tool.call("session_id" => @session.id, "action" => "create")
    end
    assert_includes error.message, '"content" is required'
  end

  test "list paginates and previews content" do
    @session.enqueued_messages.create!(content: "a" * 250, position: 1, status: "pending")
    @session.enqueued_messages.create!(content: "Second", position: 2, status: "pending")

    output = @tool.call("session_id" => @session.id, "action" => "list", "per_page" => 1)

    assert_includes output, "## Enqueued Messages (2 total, page 1 of 2)"
    assert_includes output, "### Position 1"
    assert_includes output, "#{'a' * 200}..."
    assert_not_includes output, "Second"
  end

  test "list with no messages" do
    assert_equal "## Enqueued Messages\n\nNo enqueued messages found.",
      @tool.call("session_id" => @session.id, "action" => "list")
  end

  test "get returns the full message" do
    message = @session.enqueued_messages.create!(content: "Full body", goal: "g", position: 1, status: "pending")

    output = @tool.call("session_id" => @session.id, "action" => "get", "message_id" => message.id)

    assert_includes output, "## Enqueued Message ##{message.id}"
    assert_includes output, "- **Content:** Full body"
    assert_includes output, "- **Goal:** g"
  end

  test "get without message_id raises" do
    error = assert_raises(Mcp::ToolError) do
      @tool.call("session_id" => @session.id, "action" => "get")
    end
    assert_includes error.message, '"message_id" is required'
  end

  test "get with unknown message_id raises" do
    assert_raises(Mcp::ToolError) do
      @tool.call("session_id" => @session.id, "action" => "get", "message_id" => 999_999)
    end
  end

  test "update changes content and goal" do
    message = @session.enqueued_messages.create!(content: "Old", position: 1, status: "pending")

    output = @tool.call(
      "session_id" => @session.id, "action" => "update", "message_id" => message.id,
      "content" => "New", "goal" => "new goal"
    )

    message.reload
    assert_equal "New", message.content
    assert_equal "new goal", message.goal
    assert_includes output, "## Message Updated"
  end

  test "update with blank content raises" do
    message = @session.enqueued_messages.create!(content: "Old", position: 1, status: "pending")

    assert_raises(Mcp::ToolError) do
      @tool.call("session_id" => @session.id, "action" => "update", "message_id" => message.id, "content" => "  ")
    end
    assert_equal "Old", message.reload.content
  end

  test "delete removes the message and renumbers the queue" do
    first = @session.enqueued_messages.create!(content: "First", position: 1, status: "pending")
    second = @session.enqueued_messages.create!(content: "Second", position: 2, status: "pending")

    output = @tool.call("session_id" => @session.id, "action" => "delete", "message_id" => first.id)

    assert_nil EnqueuedMessage.find_by(id: first.id)
    assert_equal 1, second.reload.position
    assert_includes output, "## Message Deleted"
  end

  test "reorder moves a message to a new position" do
    first = @session.enqueued_messages.create!(content: "First", position: 1, status: "pending")
    second = @session.enqueued_messages.create!(content: "Second", position: 2, status: "pending")

    output = @tool.call("session_id" => @session.id, "action" => "reorder", "message_id" => second.id, "position" => 1)

    assert_equal 1, second.reload.position
    assert_equal 2, first.reload.position
    assert_includes output, "- **New Position:** 1"
  end

  test "reorder rejects a position below 1" do
    message = @session.enqueued_messages.create!(content: "First", position: 1, status: "pending")

    assert_raises(Mcp::ToolError) do
      @tool.call("session_id" => @session.id, "action" => "reorder", "message_id" => message.id, "position" => 0)
    end
  end

  test "interrupt delegates to the interrupt service" do
    message = @session.enqueued_messages.create!(content: "Now", position: 1, status: "pending")
    Sessions::InterruptService.any_instance.expects(:call).returns(Sessions::Result.new(success: true))

    output = @tool.call("session_id" => @session.id, "action" => "interrupt", "message_id" => message.id)

    assert_includes output, "## Message Sent as Interrupt"
    assert_includes output, "- **Session ID:** #{@session.id}"
  end

  test "interrupt surfaces a service failure as a tool error" do
    session = sessions(:archived)
    message = session.enqueued_messages.create!(content: "Now", position: 1, status: "pending")

    error = assert_raises(Mcp::ToolError) do
      @tool.call("session_id" => session.id, "action" => "interrupt", "message_id" => message.id)
    end
    assert_includes error.message, "Cannot interrupt"
  end

  test "send_now stages a message and dispatches it immediately" do
    Sessions::InterruptService.any_instance.expects(:call).returns(Sessions::Result.new(success: true))

    output = @tool.call("session_id" => @session.id, "action" => "send_now", "content" => "Urgent", "goal" => "g")

    message = @session.enqueued_messages.last
    assert_equal "Urgent", message.content
    assert_equal "g", message.goal
    assert_includes output, "## Message Sent Immediately"
    assert_includes output, "- **Result:** Follow-up prompt sent immediately"
  end

  test "send_now discards the staged message when the interrupt fails" do
    Sessions::InterruptService.any_instance.expects(:call)
      .returns(Sessions::Result.new(success: false, error: "boom", error_code: :conflict))

    error = assert_raises(Mcp::ToolError) do
      @tool.call("session_id" => @session.id, "action" => "send_now", "content" => "Urgent")
    end

    assert_includes error.message, "boom"
    assert_equal 0, @session.enqueued_messages.count
  end

  test "send_now rejects a session that cannot receive follow-ups" do
    error = assert_raises(Mcp::ToolError) do
      @tool.call("session_id" => sessions(:archived).id, "action" => "send_now", "content" => "Urgent")
    end
    assert_includes error.message, "Cannot send follow-up"
    assert_equal 0, sessions(:archived).enqueued_messages.count
  end

  test "unknown action raises" do
    error = assert_raises(Mcp::ToolError) do
      @tool.call("session_id" => @session.id, "action" => "explode")
    end
    assert_includes error.message, 'Unknown action "explode"'
  end

  test "unknown session raises" do
    assert_raises(Mcp::ToolError) do
      @tool.call("session_id" => "nope-not-a-session", "action" => "list")
    end
  end
end
