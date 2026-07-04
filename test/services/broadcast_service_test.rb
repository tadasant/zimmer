# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"

class BroadcastServiceTest < ActiveSupport::TestCase
  setup do
    @session = sessions(:running)
    @mock_channel = mock("TurboChannel")
    @service = BroadcastService.new(turbo_channel: @mock_channel)
    # Reset circuit breaker before each test
    @service.reset_circuit_breaker
  end

  # === timeline_message tests ===

  test "timeline_message broadcasts to correct stream with message data" do
    message = {
      "type" => "assistant",
      "message" => {
        "role" => "assistant",
        "content" => [ { "type" => "text", "text" => "Hello" } ]
      },
      "timestamp" => "2025-11-20T10:00:00Z"
    }

    @mock_channel.expects(:broadcast_append_to).with(
      "session_#{@session.id}_timeline",
      has_entries(
        target: "session_#{@session.id}_timeline",
        partial: "timeline_items/item"
      )
    )

    @service.timeline_message(@session, message)
  end

  test "timeline_message fans an assistant line into assistant message + tool call events" do
    message = {
      "type" => "assistant",
      "message" => {
        "role" => "assistant",
        "content" => [
          { "type" => "text", "text" => "Let me check that" },
          { "type" => "tool_use", "name" => "Read", "id" => "t1", "input" => {} }
        ]
      }
    }

    stream = "session_#{@session.id}_timeline"
    @mock_channel.expects(:broadcast_append_to)
      .with(stream, has_entry(:locals, has_entry(:item, has_entry(:type, OpenTranscript::Types::ASSISTANT_MESSAGE)))).once
    @mock_channel.expects(:broadcast_append_to)
      .with(stream, has_entry(:locals, has_entry(:item, has_entry(:type, OpenTranscript::Types::TOOL_CALL)))).once

    @service.timeline_message(@session, message)
  end

  # Regression for PR #3942 / commit 0a00cec4: a text-less assistant line
  # (only thinking/tool_use blocks) normalizes into a content-less
  # AssistantMessage that must NOT be streamed as a bare row. Only its Thinking
  # and ToolCall events are broadcast.
  test "timeline_message skips the content-less assistant message of a text-less line" do
    message = {
      "type" => "assistant",
      "message" => {
        "role" => "assistant",
        "content" => [
          { "type" => "thinking", "thinking" => "Let me check that" },
          { "type" => "tool_use", "name" => "Read", "id" => "t1", "input" => {} }
        ]
      }
    }

    stream = "session_#{@session.id}_timeline"
    # No AssistantMessage append for the empty message...
    @mock_channel.expects(:broadcast_append_to)
      .with(stream, has_entry(:locals, has_entry(:item, has_entry(:type, OpenTranscript::Types::ASSISTANT_MESSAGE)))).never
    # ...but the Thinking and ToolCall events still stream.
    @mock_channel.expects(:broadcast_append_to)
      .with(stream, has_entry(:locals, has_entry(:item, has_entry(:type, OpenTranscript::Types::THINKING)))).once
    @mock_channel.expects(:broadcast_append_to)
      .with(stream, has_entry(:locals, has_entry(:item, has_entry(:type, OpenTranscript::Types::TOOL_CALL)))).once

    @service.timeline_message(@session, message)
  end

  test "timeline_message maps a tool_result line to a ToolResult event" do
    message = {
      "type" => "user",
      "message" => {
        "role" => "user",
        "content" => [
          { "type" => "tool_result", "tool_use_id" => "t1", "content" => "file contents" }
        ]
      }
    }

    @mock_channel.expects(:broadcast_append_to).with(
      "session_#{@session.id}_timeline",
      has_entry(:locals, has_entry(:item, has_entry(:type, OpenTranscript::Types::TOOL_RESULT)))
    )

    @service.timeline_message(@session, message)
  end

  test "timeline_message falls back to session.created_at on an invalid timestamp" do
    message = {
      "type" => "assistant",
      "message" => { "role" => "assistant", "content" => "Hello" },
      "timestamp" => "invalid-timestamp"
    }

    @mock_channel.expects(:broadcast_append_to).with(
      "session_#{@session.id}_timeline",
      has_entry(:locals, has_entry(:item, has_entry(:sort_time, @session.created_at)))
    )

    @service.timeline_message(@session, message)
  end

  test "timeline_message emits a user message even when the message envelope is absent" do
    message = {
      "type" => "user",
      "role" => "user",
      "content" => "Direct message content"
    }

    @mock_channel.expects(:broadcast_append_to).with(
      "session_#{@session.id}_timeline",
      has_entry(:locals, has_entry(:item, has_entry(:type, OpenTranscript::Types::USER_MESSAGE)))
    )

    @service.timeline_message(@session, message)
  end

  # === timeline_log tests ===

  test "timeline_log broadcasts log entry to timeline" do
    log = @session.logs.create!(content: "Test log", level: "info")

    @mock_channel.expects(:broadcast_append_to).with(
      "session_#{@session.id}_timeline",
      has_entries(
        target: "session_#{@session.id}_timeline",
        partial: "timeline_items/item",
        locals: has_entry(:item, has_entries(
          type: "log",
          level: "info",
          content: "Test log"
        ))
      )
    )

    @service.timeline_log(@session, log)
  end

  # === running_loader tests ===

  test "running_loader broadcasts replace to running loader target" do
    @mock_channel.expects(:broadcast_replace_to).with(
      "session_#{@session.id}_timeline",
      has_entries(
        target: "session_#{@session.id}_running_loader",
        partial: "sessions/running_loader",
        locals: { agent_session: @session }
      )
    )

    @service.running_loader(@session)
  end

  # === remove_running_loader tests ===

  test "remove_running_loader broadcasts remove to running loader target" do
    @mock_channel.expects(:broadcast_remove_to).with(
      "session_#{@session.id}_timeline",
      has_entry(:target, "session_#{@session.id}_running_loader")
    )

    @service.remove_running_loader(@session)
  end

  # === remove_empty_timeline_message tests ===

  test "remove_empty_timeline_message broadcasts remove to empty-timeline-message target" do
    @mock_channel.expects(:broadcast_remove_to).with(
      "session_#{@session.id}_timeline",
      has_entry(:target, "empty-timeline-message")
    )

    @service.remove_empty_timeline_message(@session)
  end

  # === subagent_accordion tests ===

  test "subagent_accordion broadcasts replace to correct target" do
    subagent = @session.subagent_transcripts.create!(
      agent_id: "agent-explore-123",
      status: "completed",
      subagent_type: "Explore",
      description: "Explore codebase"
    )

    @mock_channel.expects(:broadcast_replace_to).with(
      "session_#{@session.id}_timeline",
      has_entries(
        target: "subagent_accordion_#{subagent.agent_id}",
        partial: "subagent_transcripts/accordion",
        locals: { subagent: subagent, session: @session }
      )
    )

    @service.subagent_accordion(@session, subagent)
  end

  test "subagent_accordion works with running subagent" do
    subagent = @session.subagent_transcripts.create!(
      agent_id: "agent-running-456",
      status: "running",
      subagent_type: "general-purpose"
    )

    @mock_channel.expects(:broadcast_replace_to).with(
      "session_#{@session.id}_timeline",
      has_entries(
        target: "subagent_accordion_#{subagent.agent_id}",
        partial: "subagent_transcripts/accordion"
      )
    )

    @service.subagent_accordion(@session, subagent)
  end

  # === subagent_messages tests ===

  test "subagent_messages broadcasts replace to correct target" do
    subagent = @session.subagent_transcripts.create!(
      agent_id: "agent-explore-123",
      status: "completed"
    )

    @mock_channel.expects(:broadcast_replace_to).with(
      "session_#{@session.id}_timeline",
      has_entries(
        target: "subagent_#{subagent.agent_id}_messages",
        partial: "subagent_transcripts/messages",
        locals: { subagent: subagent, session: @session }
      )
    )

    @service.subagent_messages(@session, subagent)
  end

  test "subagent_messages works with running subagent" do
    subagent = @session.subagent_transcripts.create!(
      agent_id: "agent-running-456",
      status: "running"
    )

    @mock_channel.expects(:broadcast_replace_to).with(
      "session_#{@session.id}_timeline",
      has_entries(
        target: "subagent_#{subagent.agent_id}_messages",
        partial: "subagent_transcripts/messages"
      )
    )

    @service.subagent_messages(@session, subagent)
  end

  # === enqueued_messages_list tests ===

  test "enqueued_messages_list broadcasts replace to correct stream and target" do
    @mock_channel.expects(:broadcast_replace_to).with(
      "session_#{@session.id}_enqueued_messages",
      has_entries(
        target: "session_#{@session.id}_enqueued_messages",
        partial: "enqueued_messages/enqueued_messages_list",
        locals: { agent_session: @session }
      )
    )

    @service.enqueued_messages_list(@session)
  end

  # === session_status tests ===

  test "session_status broadcasts header actions via the session_header_actions partial" do
    # Regression: session_status rendered the non-existent "sessions/header_actions"
    # partial, so SessionsController.render raised ActionView::MissingTemplate on every
    # status broadcast. The error was swallowed by session_status's rescue, so the
    # header-actions region silently stopped updating and sessions looked frozen in the
    # UI. Guard that the header-actions broadcast actually fires with the real partial.
    @mock_channel.stubs(:broadcast_replace_to)
    @mock_channel.expects(:broadcast_replace_to).with(
      "session_#{@session.id}_status",
      has_entry(:target, "session_#{@session.id}_header_actions")
    ).at_least_once

    @service.session_status(@session)
  end

  # === Retry logic tests ===

  test "retries on transient failure and succeeds" do
    call_count = 0
    @mock_channel.stubs(:broadcast_append_to).with do |*_args|
      call_count += 1
      raise StandardError, "Transient error" if call_count < 2
      true
    end

    message = { "type" => "user", "message" => { "role" => "user", "content" => "Hello" } }
    result = @service.timeline_message(@session, message)

    assert result, "Should return true after successful retry"
    assert_equal 2, call_count, "Should have retried once"
  end

  test "fails after max retries exceeded" do
    @mock_channel.stubs(:broadcast_append_to).raises(StandardError, "Persistent error")

    message = { "type" => "user", "message" => { "role" => "user", "content" => "Hello" } }
    result = @service.timeline_message(@session, message)

    assert_not result, "Should return false after max retries"
  end

  test "uses exponential backoff between retries" do
    sleep_times = []
    @service.stubs(:sleep).with { |time| sleep_times << time; true }
    @mock_channel.stubs(:broadcast_append_to).raises(StandardError, "Error")

    message = { "type" => "user", "message" => { "role" => "user", "content" => "Hello" } }
    @service.timeline_message(@session, message)

    # Should have 3 retries with exponential backoff: 0.1, 0.2, 0.4
    assert_equal 3, sleep_times.length
    assert_in_delta 0.1, sleep_times[0], 0.01
    assert_in_delta 0.2, sleep_times[1], 0.01
    assert_in_delta 0.4, sleep_times[2], 0.01
  end

  # === Circuit breaker tests ===

  test "circuit breaker opens after threshold failures" do
    @mock_channel.stubs(:broadcast_append_to).raises(StandardError, "Error")

    # Trigger failures up to threshold
    message = { "type" => "user", "message" => { "role" => "user", "content" => "Hello" } }
    BroadcastService::CIRCUIT_BREAKER_THRESHOLD.times do
      @service.timeline_message(@session, message)
    end

    assert @service.circuit_open?, "Circuit breaker should be open after threshold failures"
  end

  test "skips broadcast when circuit breaker is open" do
    # Open the circuit breaker
    BroadcastService.circuit_breaker_failures = BroadcastService::CIRCUIT_BREAKER_THRESHOLD
    BroadcastService.circuit_breaker_opened_at = Time.current

    @mock_channel.expects(:broadcast_append_to).never

    message = { "type" => "user", "message" => { "role" => "user", "content" => "Hello" } }
    result = @service.timeline_message(@session, message)

    assert_not result, "Should return false when circuit breaker is open"
  end

  test "circuit breaker resets after timeout" do
    # Open the circuit breaker
    BroadcastService.circuit_breaker_failures = BroadcastService::CIRCUIT_BREAKER_THRESHOLD
    BroadcastService.circuit_breaker_opened_at = Time.current - (BroadcastService::CIRCUIT_BREAKER_RESET_TIME + 1)

    assert_not @service.circuit_open?, "Circuit breaker should be closed after reset time"
    assert_equal 0, BroadcastService.circuit_breaker_failures
    assert_nil BroadcastService.circuit_breaker_opened_at
  end

  test "successful broadcast decrements failure count" do
    BroadcastService.circuit_breaker_failures = 3
    @mock_channel.stubs(:broadcast_append_to).returns(true)

    message = { "type" => "user", "message" => { "role" => "user", "content" => "Hello" } }
    @service.timeline_message(@session, message)

    assert_equal 2, BroadcastService.circuit_breaker_failures
  end

  test "reset_circuit_breaker clears all state" do
    BroadcastService.circuit_breaker_failures = 5
    BroadcastService.circuit_breaker_opened_at = Time.current

    @service.reset_circuit_breaker

    assert_equal 0, BroadcastService.circuit_breaker_failures
    assert_nil BroadcastService.circuit_breaker_opened_at
  end

  # === Error handling tests ===

  test "broadcast failures do not raise exceptions" do
    @mock_channel.stubs(:broadcast_append_to).raises(StandardError, "Fatal error")

    message = { "type" => "user", "message" => { "role" => "user", "content" => "Hello" } }

    assert_nothing_raised do
      @service.timeline_message(@session, message)
    end
  end

  test "broadcast failures are logged" do
    @mock_channel.stubs(:broadcast_append_to).raises(StandardError, "Test error")

    # We'd need to capture structured logger output, but at minimum verify no exception
    message = { "type" => "user", "message" => { "role" => "user", "content" => "Hello" } }

    assert_nothing_raised do
      @service.timeline_message(@session, message)
    end
  end

  # === notification_badge tests ===

  test "notification_badge broadcasts replace to global notification_badge stream" do
    @mock_channel.expects(:broadcast_replace_to).with(
      "notification_badge",
      has_entries(
        target: "notification_badge",
        partial: "notifications/notification_badge",
        locals: { pending_count: 5 }
      )
    )

    @service.notification_badge(5)
  end

  test "notification_badge broadcasts with zero count" do
    @mock_channel.expects(:broadcast_replace_to).with(
      "notification_badge",
      has_entries(
        target: "notification_badge",
        partial: "notifications/notification_badge",
        locals: { pending_count: 0 }
      )
    )

    @service.notification_badge(0)
  end

  # === Integration-like tests ===

  test "handles string (non-array) message content" do
    message = {
      "type" => "user",
      "message" => { "role" => "user", "content" => "Simple string content" }
    }

    @mock_channel.expects(:broadcast_append_to).with(
      "session_#{@session.id}_timeline",
      has_entry(:locals, has_entry(:item, has_entries(
        type: OpenTranscript::Types::USER_MESSAGE,
        content: [ { "type" => "text", "text" => "Simple string content" } ]
      )))
    )

    @service.timeline_message(@session, message)
  end

  test "handles nil timestamp via the created_at fallback" do
    message = {
      "type" => "assistant",
      "message" => { "role" => "assistant", "content" => "Hello" },
      "timestamp" => nil
    }

    @mock_channel.expects(:broadcast_append_to).with(
      "session_#{@session.id}_timeline",
      has_entry(:locals, has_entry(:item, has_entry(:sort_time, @session.created_at)))
    )

    @service.timeline_message(@session, message)
  end
end
