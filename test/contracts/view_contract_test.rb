# frozen_string_literal: true

require "test_helper"

# Contract tests for view rendering
#
# These tests ensure that all session partials render without errors,
# particularly verifying that route helpers are available and work correctly.
#
# Historical context:
# 25% of production bugs were caused by view rendering errors, specifically
# partials failing with "undefined method 'session_path'" or similar route
# helper errors. Related commits:
# - 49e5ff16: Fix undefined method session_path error in session card partial
# - 9f469b8b: Fix undefined method 'session_path' error in session partials (again!)
# - 151320ec: Fix background job broadcast rendering failures
# - ca7d609d: Fix session broadcast errors by using SessionsController
#
# Root causes addressed:
# 1. Controller context mismatch: Partials rendered from ApplicationController
#    or background jobs don't have access to route helpers
# 2. Variable shadowing: Local variable `session` shadowing Rails' session method
#
class ViewContractTest < ActionView::TestCase
  include Rails.application.routes.url_helpers

  # Define all session statuses to test (must match Session.statuses keys)
  SESSION_STATUSES = %w[running waiting needs_input archived failed].freeze

  # Define all session partials that use route helpers
  SESSION_PARTIALS = %w[
    session_card
    status_badge
    follow_up_form
    running_loader
    session_metadata
    session_header_actions
  ].freeze

  setup do
    # Use various session fixtures to test different states
    @running_session = sessions(:running)
    @waiting_session = sessions(:waiting)
    @needs_input_session = sessions(:needs_input)
    @archived_session = sessions(:archived)
    @failed_session = sessions(:failed)

    # Ensure sessions have required attributes for rendering
    @running_session.update!(
      status: :running,
      title: "Test Running Session",
      last_timeline_entry_at: Time.current
    )

    @waiting_session.update!(
      status: :waiting,
      title: "Test Waiting Session"
    )

    @needs_input_session.update!(
      status: :needs_input,
      title: "Test Needs Input Session"
    )

    # Set up metadata for session_metadata partial testing
    @waiting_session.update!(
      metadata: {
        "clone_path" => "/tmp/test-clone",
        "full_clone_path" => "/tmp/test-clone/subdir",
        "agent_root_key" => "agent-orchestrator"
      },
      subdirectory: "subdir"
    )
  end

  # =========================================================================
  # Contract: All session partials must render without undefined method errors
  # =========================================================================

  test "all session partials render without undefined method errors" do
    sessions_to_test = [
      @running_session,
      @waiting_session,
      @needs_input_session,
      @archived_session,
      @failed_session
    ]

    SESSION_PARTIALS.each do |partial|
      sessions_to_test.each do |session|
        html = render_partial_with_controller(partial, session)

        # Verify no undefined method errors in output
        refute_match(/undefined method/i, html,
          "Partial sessions/#{partial} raised undefined method error for #{session.status} session")
        refute_match(/NoMethodError/i, html,
          "Partial sessions/#{partial} raised NoMethodError for #{session.status} session")
      end
    end
  end

  # =========================================================================
  # Contract: Route helpers must generate valid paths
  # =========================================================================

  test "session_card partial generates valid session_path" do
    html = render_partial_with_controller("session_card", @running_session)

    # Verify the link contains a valid session path
    assert_includes html, "/sessions/#{@running_session.id}",
      "session_card partial should contain valid session_path"
  end

  test "session_card partial generates valid archive_session_path for non-archived sessions" do
    html = render_partial_with_controller("session_card", @running_session)

    # Verify the archive button contains valid path
    assert_includes html, "/sessions/#{@running_session.id}/archive",
      "session_card partial should contain valid archive_session_path"
  end

  test "session_card partial shows restart button for failed sessions" do
    html = render_partial_with_controller("session_card", @failed_session)

    assert_includes html, "/sessions/#{@failed_session.id}/restart",
      "session_card partial should contain restart button for failed sessions"
    assert_includes html, "Restart",
      "session_card partial should show Restart label for failed sessions"
  end

  test "session_card partial omits restart button for non-failed sessions" do
    html = render_partial_with_controller("session_card", @running_session)

    refute_includes html, "/sessions/#{@running_session.id}/restart",
      "session_card partial should not show restart button for running sessions"
  end

  test "session_card partial omits archive button for archived sessions" do
    html = render_partial_with_controller("session_card", @archived_session)

    # Verify no archive button for already archived sessions
    refute_includes html, "/sessions/#{@archived_session.id}/archive",
      "session_card partial should not show archive button for archived sessions"
  end

  test "follow_up_form partial generates valid follow_up_session_path for waiting sessions" do
    html = render_partial_with_controller("follow_up_form", @waiting_session)

    # Verify the form action contains valid path
    assert_includes html, "/sessions/#{@waiting_session.id}/follow_up",
      "follow_up_form partial should contain valid follow_up_session_path"
  end

  test "follow_up_form partial generates valid follow_up_session_path for needs_input sessions" do
    html = render_partial_with_controller("follow_up_form", @needs_input_session)

    # Verify the form action contains valid path
    assert_includes html, "/sessions/#{@needs_input_session.id}/follow_up",
      "follow_up_form partial should contain valid follow_up_session_path"
  end

  test "follow_up_form partial is empty for running sessions" do
    html = render_partial_with_controller("follow_up_form", @running_session)

    # Running sessions should not show the follow-up form
    refute_includes html, "follow_up_session_path",
      "follow_up_form partial should be empty for running sessions"
  end

  # =========================================================================
  # Contract: Broadcast methods must render partials successfully
  # =========================================================================

  test "broadcast_update_to_sessions_index renders successfully" do
    # This test verifies that the Session model's broadcast method works
    # when called from outside a controller context (like from a background job)
    assert_nothing_raised do
      @running_session.send(:broadcast_update_to_sessions_index)
    end
  end

  test "broadcast_create_to_sessions_index renders successfully" do
    assert_nothing_raised do
      @running_session.send(:broadcast_create_to_sessions_index)
    end
  end

  test "broadcast_status_change renders all related partials successfully" do
    # Test with each status to ensure all code paths work
    sessions_by_status = {
      "running" => @running_session,
      "waiting" => @waiting_session,
      "needs_input" => @needs_input_session,
      "archived" => @archived_session,
      "failed" => @failed_session
    }

    tested_count = 0
    SESSION_STATUSES.each do |status|
      session = sessions_by_status[status]
      session.update!(status: status)

      begin
        session.send(:broadcast_status_change)
        tested_count += 1
      rescue => e
        flunk "broadcast_status_change failed for #{status} session - #{e.message}"
      end
    end

    assert_equal SESSION_STATUSES.length, tested_count, "All statuses should be tested"
  end

  test "broadcast_custom_metadata_change renders session_header_actions successfully" do
    # Test with each status to ensure all code paths work
    sessions_by_status = {
      "running" => @running_session,
      "waiting" => @waiting_session,
      "needs_input" => @needs_input_session,
      "archived" => @archived_session,
      "failed" => @failed_session
    }

    tested_count = 0
    SESSION_STATUSES.each do |status|
      session = sessions_by_status[status]
      session.update!(status: status)

      begin
        session.send(:broadcast_custom_metadata_change)
        tested_count += 1
      rescue => e
        flunk "broadcast_custom_metadata_change failed for #{status} session - #{e.message}"
      end
    end

    assert_equal SESSION_STATUSES.length, tested_count, "All statuses should be tested"
  end

  # =========================================================================
  # Contract: SessionsController.render must work for all partials
  # =========================================================================

  test "SessionsController.render works for session_card partial" do
    html = SessionsController.render(
      partial: "sessions/session_card",
      locals: { agent_session: @running_session }
    )

    assert html.present?, "SessionsController.render should return non-empty HTML"
    refute_match(/undefined method/i, html)
  end

  test "SessionsController.render works for status_badge partial" do
    html = SessionsController.render(
      partial: "sessions/status_badge",
      locals: { agent_session: @running_session }
    )

    assert html.present?, "SessionsController.render should return non-empty HTML"
    assert_includes html, "Running"
  end

  test "SessionsController.render works for follow_up_form partial" do
    html = SessionsController.render(
      partial: "sessions/follow_up_form",
      locals: { agent_session: @waiting_session }
    )

    assert html.present?, "SessionsController.render should return non-empty HTML"
    assert_includes html, "Follow-up Prompt"
  end

  test "SessionsController.render works for running_loader partial" do
    html = SessionsController.render(
      partial: "sessions/running_loader",
      locals: { agent_session: @running_session }
    )

    assert html.present?, "SessionsController.render should return non-empty HTML"
    assert_includes html, "running_loader"
  end

  test "SessionsController.render works for session_metadata partial" do
    html = SessionsController.render(
      partial: "sessions/session_metadata",
      locals: { agent_session: @waiting_session }
    )

    assert html.present?, "SessionsController.render should return non-empty HTML"
    assert_includes html, "Root:"
    assert_includes html, "agent-orchestrator",
      "Root row should display the agent root key from roots.json"
    refute_includes html, "Agent:",
      "Agent row should no longer be rendered"
  end

  test "SessionsController.render displays detailed MCP failure error in session_metadata" do
    # Set up a session with MCP connection failure
    # Note: mcp_servers is empty because the server already failed and was cleared,
    # but custom_metadata retains the failure details for display purposes
    @failed_session.update!(
      status: :failed,
      metadata: {
        "failure_reason" => "mcp_connection_failed"
      },
      custom_metadata: {
        "mcp_failed_servers" => [
          {
            "name" => "test-server",
            "status" => "failed",
            "error" => "Connection failed after 7900ms: MCP error -32000: Connection closed"
          }
        ],
        "mcp_servers_status" => {
          "test-server" => {
            "status" => "failed",
            "error" => "Connection failed after 7900ms: MCP error -32000: Connection closed",
            "failed_at" => "2026-01-09T22:05:01.963Z"
          }
        }
      },
      mcp_servers: []
    )

    html = SessionsController.render(
      partial: "sessions/session_metadata",
      locals: { agent_session: @failed_session }
    )

    assert html.present?, "SessionsController.render should return non-empty HTML"
    # Should show the detailed MCP error, naming the failed server in the label
    # rather than a generic "Mcp connection failed"
    assert_includes html, "MCP server(s) failed to connect",
      "Should display MCP connection failure label naming the server"
    assert_includes html, "Connection failed after 7900ms",
      "Should display the specific error message from mcp_failed_servers"
    assert_includes html, "test-server",
      "Should display the server name"
  end

  test "SessionsController.render displays fallback mcp_failure_reason when mcp_failed_servers is empty" do
    # Edge case: mcp_failed_servers is empty but mcp_failure_reason exists
    @failed_session.update!(
      status: :failed,
      metadata: {
        "failure_reason" => "mcp_connection_failed"
      },
      custom_metadata: {
        "mcp_failed_servers" => [],
        "mcp_failure_reason" => "MCP server(s) failed to connect: legacy-server"
      },
      mcp_servers: []
    )

    html = SessionsController.render(
      partial: "sessions/session_metadata",
      locals: { agent_session: @failed_session }
    )

    assert html.present?, "SessionsController.render should return non-empty HTML"
    # Should fall back to mcp_failure_reason from custom_metadata
    assert_includes html, "MCP server(s) failed to connect: legacy-server",
      "Should display fallback mcp_failure_reason when mcp_failed_servers is empty"
  end

  test "SessionsController.render works for session_header_actions partial" do
    html = SessionsController.render(
      partial: "sessions/session_header_actions",
      locals: { agent_session: @running_session }
    )

    assert html.present?, "SessionsController.render should return non-empty HTML"
    # Should include the header_actions target ID
    assert_includes html, "header_actions"
    # Should include the refresh button (always present)
    assert_includes html, "refresh"
  end

  # =========================================================================
  # Contract: Timeline item partials must render without errors
  # =========================================================================

  test "timeline_items/item partial renders an OpenTranscripts message event successfully" do
    item = OpenTranscript.event(
      type: OpenTranscript::Types::ASSISTANT_MESSAGE,
      id: "evt-1",
      parent_id: nil,
      ts: Time.current.iso8601,
      sort_time: Time.current,
      content: [ OpenTranscript.text_part("Hello, world!") ]
    )

    assert_nothing_raised do
      render partial: "timeline_items/item", locals: { item: item }
    end
  end

  test "timeline_items/item partial renders an OpenTranscripts tool call event successfully" do
    item = OpenTranscript.event(
      type: OpenTranscript::Types::TOOL_CALL,
      id: "evt-2",
      parent_id: nil,
      ts: Time.current.iso8601,
      sort_time: Time.current,
      tool_name: "Bash",
      arguments: { "command" => "ls -la" }
    )

    assert_nothing_raised do
      render partial: "timeline_items/item", locals: { item: item }
    end
  end

  # Regression for PR #3942 / commit 0a00cec4: a content-less message event
  # (e.g. a Claude assistant line carrying only tool_use/thinking blocks) must
  # render NOTHING — no bare "Assistant" row, no data-timeline-item wrapper that
  # would inflate the infinite-scroll counter. The event is kept in the
  # normalized stream for metrics/parent-linkage but is suppressed at render.
  test "timeline_items/item partial renders nothing for a content-less message event" do
    item = OpenTranscript.event(
      type: OpenTranscript::Types::ASSISTANT_MESSAGE,
      id: "evt-empty",
      parent_id: nil,
      ts: Time.current.iso8601,
      sort_time: Time.current,
      content: []
    )

    html = render partial: "timeline_items/item", locals: { item: item }
    assert_equal "", html.strip,
      "a content-less message event must render no visible row"
    refute_includes html, "data-timeline-item",
      "a suppressed message must not emit the infinite-scroll counter hook"
    refute_includes html, "Assistant",
      "a suppressed message must not draw the Assistant header label"
  end

  test "timeline_items/item partial still renders a message event that has text content" do
    item = OpenTranscript.event(
      type: OpenTranscript::Types::ASSISTANT_MESSAGE,
      id: "evt-nonempty",
      parent_id: nil,
      ts: Time.current.iso8601,
      sort_time: Time.current,
      content: [ OpenTranscript.text_part("Real content") ]
    )

    html = render partial: "timeline_items/item", locals: { item: item }
    assert_includes html, "data-timeline-item"
    assert_includes html, "Assistant"
    assert_includes html, "Real content"
  end

  # Regression: nested (subagent-accordion) items must NOT emit the parent
  # timeline's filter/scroll hooks. The parent infinite-scroll counter and
  # log-level filter query [data-timeline-item] / [data-filter-category]
  # unscoped, so a nested item carrying those attributes would inflate the
  # parent item count and let the parent filter reach into accordion contents.
  test "timeline_items/item partial omits timeline hooks when rendered nested" do
    item = OpenTranscript.event(
      type: OpenTranscript::Types::ASSISTANT_MESSAGE,
      id: "evt-nested",
      parent_id: nil,
      ts: Time.current.iso8601,
      sort_time: Time.current,
      content: [ OpenTranscript.text_part("Nested subagent message") ]
    )

    top_level = render partial: "timeline_items/item", locals: { item: item }
    assert_includes top_level, "data-timeline-item",
      "top-level items must carry data-timeline-item for the parent counter"
    assert_includes top_level, "data-filter-category",
      "top-level items must carry data-filter-category for the parent filter"

    nested = render partial: "timeline_items/item", locals: { item: item, nested: true }
    refute_includes nested, "data-timeline-item",
      "nested items must NOT carry data-timeline-item (leaks into parent count)"
    refute_includes nested, "data-filter-category",
      "nested items must NOT carry data-filter-category (leaks into parent filter)"
    assert_includes nested, "Nested subagent message",
      "nested items must still render their content"
  end

  test "timeline_items/item partial renders log type successfully" do
    item = {
      type: "log",
      level: "info",
      content: "Test log message",
      timestamp: Time.current,
      sort_time: Time.current
    }

    assert_nothing_raised do
      render partial: "timeline_items/item", locals: { item: item }
    end
  end

  test "timeline_items/log partial renders all log levels" do
    levels = %w[info error warning debug verbose]
    tested_count = 0

    levels.each do |level|
      item = {
        type: "log",
        level: level,
        content: "Test #{level} message",
        timestamp: Time.current,
        sort_time: Time.current
      }

      begin
        render partial: "timeline_items/log", locals: { item: item }
        tested_count += 1
      rescue => e
        flunk "timeline_items/log failed for level: #{level} - #{e.message}"
      end
    end

    assert_equal levels.length, tested_count, "All log levels should be tested"
  end

  test "timeline_items/mcp_log partial renders all log levels with markdown" do
    levels = %w[info error debug]
    tested_count = 0

    levels.each do |level|
      item = {
        type: "mcp_log",
        level: level,
        server_name: "test-server",
        content: "Test #{level} message with `code` and **bold**",
        timestamp: Time.current,
        sort_time: Time.current
      }

      begin
        render partial: "timeline_items/mcp_log", locals: { item: item }
        tested_count += 1
      rescue => e
        flunk "timeline_items/mcp_log failed for level: #{level} - #{e.message}"
      end
    end

    assert_equal levels.length, tested_count, "All MCP log levels should be tested"
  end

  test "timeline_items/mcp_log partial renders error level with distinct styling" do
    item = {
      type: "mcp_log",
      level: "error",
      server_name: "test-server",
      content: "Connection failed",
      timestamp: Time.current,
      sort_time: Time.current
    }

    result = render partial: "timeline_items/mcp_log", locals: { item: item }
    assert_includes result, "mcp-log-error", "Error level MCP logs should have error styling class"
  end

  test "timeline_items/mcp_log partial renders non-error with standard styling" do
    item = {
      type: "mcp_log",
      level: "info",
      server_name: "test-server",
      content: "Connected successfully",
      timestamp: Time.current,
      sort_time: Time.current
    }

    result = render partial: "timeline_items/mcp_log", locals: { item: item }
    assert_includes result, "mcp-log", "Non-error MCP logs should have standard styling class"
    refute_includes result, "mcp-log-error", "Non-error MCP logs should not have error styling"
  end

  private

  # Helper to render a session partial using SessionsController context
  # This ensures route helpers are available, mimicking how broadcasts work
  def render_partial_with_controller(partial, session)
    SessionsController.render(
      partial: "sessions/#{partial}",
      locals: { agent_session: session }
    )
  end
end
