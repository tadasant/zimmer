# frozen_string_literal: true

require "test_helper"

class Mcp::Tools::RespondToElicitationTest < ActiveSupport::TestCase
  setup do
    @session = sessions(:elicitation_session)
    @tool = Mcp::Tools::RespondToElicitation.new(context: Mcp::Context.new(tool_groups: "sessions"))
  end

  test "accept resolves the elicitation and echoes the content" do
    elicitation = create_elicitation

    output = @tool.call(
      "request_id" => elicitation.request_id,
      "action_type" => "accept",
      "content" => { "approved" => true }
    )

    elicitation.reload
    assert_equal "accept", elicitation.status
    assert_equal({ "approved" => true }, elicitation.response_content)
    assert_not_nil elicitation.responded_at
    assert_includes output, "## Elicitation Accepted"
    assert_includes output, "- **Request ID:** #{elicitation.request_id}"
    assert_includes output, "- **Action:** accept"
    assert_includes output, '- **Content:** {"approved":true}'
  end

  test "accept without content omits the content line" do
    elicitation = create_elicitation

    output = @tool.call("request_id" => elicitation.request_id, "action_type" => "accept")

    assert_equal "accept", elicitation.reload.status
    assert_not_includes output, "- **Content:**"
  end

  test "decline resolves the elicitation" do
    elicitation = create_elicitation

    output = @tool.call("request_id" => elicitation.request_id, "action_type" => "decline")

    assert_equal "decline", elicitation.reload.status
    assert_includes output, "## Elicitation Declined"
    assert_includes output, "- **Action:** decline"
  end

  test "unknown request_id raises" do
    error = assert_raises(Mcp::ToolError) do
      @tool.call("request_id" => "missing-req", "action_type" => "accept")
    end
    assert_includes error.message, "Elicitation not found"
  end

  test "an already-resolved elicitation raises" do
    elicitation = create_elicitation
    elicitation.resolve!(action: "accept")

    error = assert_raises(Mcp::ToolError) do
      @tool.call("request_id" => elicitation.request_id, "action_type" => "decline")
    end
    assert_includes error.message, "already been resolved"
  end

  test "an invalid action_type raises" do
    elicitation = create_elicitation

    error = assert_raises(Mcp::ToolError) do
      @tool.call("request_id" => elicitation.request_id, "action_type" => "maybe")
    end
    assert_includes error.message, "action_type must be one of"
    assert_equal "pending", elicitation.reload.status
  end

  test "non-object content raises" do
    elicitation = create_elicitation

    error = assert_raises(Mcp::ToolError) do
      @tool.call("request_id" => elicitation.request_id, "action_type" => "accept", "content" => "yes")
    end
    assert_includes error.message, "content must be a JSON object"
    assert_equal "pending", elicitation.reload.status
  end

  test "a missing request_id raises" do
    assert_raises(Mcp::ToolError) { @tool.call("action_type" => "accept") }
  end

  private

  def create_elicitation
    Elicitation.create!(
      session: @session,
      request_id: "req-#{SecureRandom.hex(4)}",
      mode: "form",
      message: "Approve this action?",
      requested_schema: {},
      status: "pending",
      expires_at: 10.minutes.from_now
    )
  end
end
