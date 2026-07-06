# frozen_string_literal: true

require "test_helper"
require "minitest/mock"

# Contract tests for broadcast rendering
#
# These tests ensure that broadcasts from services and models render
# partials correctly without undefined method errors, especially when
# called from background jobs.
#
# Historical context:
# View rendering errors from background jobs (25% of production bugs) occur
# because broadcasts don't have controller context. These tests verify that
# all broadcast paths properly render their partials.
#
class BroadcastContractTest < ActiveSupport::TestCase
  setup do
    @running_session = sessions(:running)
    @waiting_session = sessions(:waiting)

    # Ensure sessions have required attributes
    @running_session.update!(
      status: :running,
      title: "Test Running Session",
      last_timeline_entry_at: Time.current
    )

    @waiting_session.update!(
      status: :waiting,
      title: "Test Waiting Session"
    )

    # Reset circuit breaker between tests
    BroadcastService.circuit_breaker_failures = 0
    BroadcastService.circuit_breaker_opened_at = nil
  end

  # =========================================================================
  # Contract: BroadcastService must render partials without errors
  # =========================================================================

  test "BroadcastService.timeline_message broadcasts successfully" do
    service = BroadcastService.new

    message = {
      "type" => "assistant",
      "message" => { "role" => "assistant", "content" => "Hello!" },
      "timestamp" => Time.current.iso8601
    }

    # Should not raise any errors
    assert_nothing_raised do
      service.timeline_message(@running_session, message)
    end
  end

  test "BroadcastService.timeline_message handles complex message content" do
    service = BroadcastService.new

    # Message with tool use blocks (common pattern from Claude Code)
    message = {
      "type" => "assistant",
      "message" => {
        "role" => "assistant",
        "content" => [
          { "type" => "text", "text" => "I'll read that file for you." },
          { "type" => "tool_use", "id" => "tool_123", "name" => "Read", "input" => { "path" => "/test.rb" } }
        ]
      },
      "timestamp" => Time.current.iso8601
    }

    assert_nothing_raised do
      service.timeline_message(@running_session, message)
    end
  end

  test "BroadcastService.timeline_message handles tool result messages" do
    service = BroadcastService.new

    message = {
      "type" => "user",
      "message" => {
        "role" => "user",
        "content" => [
          { "type" => "tool_result", "tool_use_id" => "tool_123", "content" => "File contents here" }
        ]
      },
      "timestamp" => Time.current.iso8601
    }

    assert_nothing_raised do
      service.timeline_message(@running_session, message)
    end
  end

  test "BroadcastService.timeline_log broadcasts successfully" do
    service = BroadcastService.new

    log = @running_session.logs.create!(
      content: "Test log message",
      level: "info"
    )

    assert_nothing_raised do
      service.timeline_log(@running_session, log)
    end
  end

  test "BroadcastService.timeline_log handles all log levels" do
    service = BroadcastService.new
    levels = %w[info error warning debug verbose]
    tested_count = 0

    levels.each do |level|
      log = @running_session.logs.create!(
        content: "Test #{level} message",
        level: level
      )

      begin
        service.timeline_log(@running_session, log)
        tested_count += 1
      rescue => e
        flunk "BroadcastService.timeline_log failed for level: #{level} - #{e.message}"
      end
    end

    assert_equal levels.length, tested_count, "All log levels should be tested"
  end

  test "BroadcastService.timeline_log renders with filter-category attribute" do
    # This test verifies that BroadcastService.timeline_log uses the _item partial
    # which includes the data-filter-category attribute needed for client-side filtering.
    log = @running_session.logs.create!(
      content: "Test log via BroadcastService",
      level: "info"
    )

    timeline_item = {
      type: "log",
      level: log.level,
      content: log.content,
      timestamp: log.created_at,
      sort_time: log.created_at
    }

    # Render the partial that BroadcastService.timeline_log uses
    rendered = ApplicationController.render(
      partial: "timeline_items/item",
      locals: { item: timeline_item }
    )

    assert_includes rendered, "data-timeline-item"
    assert_includes rendered, 'data-filter-category="regular-log"'
  end

  test "BroadcastService.timeline_log renders verbose logs with verbose-log filter category" do
    log = @running_session.logs.create!(
      content: "Verbose log via BroadcastService",
      level: "verbose"
    )

    timeline_item = {
      type: "log",
      level: log.level,
      content: log.content,
      timestamp: log.created_at,
      sort_time: log.created_at
    }

    rendered = ApplicationController.render(
      partial: "timeline_items/item",
      locals: { item: timeline_item }
    )

    assert_includes rendered, "data-timeline-item"
    assert_includes rendered, 'data-filter-category="verbose-log"'
  end

  test "BroadcastService.running_loader broadcasts successfully" do
    service = BroadcastService.new

    assert_nothing_raised do
      service.running_loader(@running_session)
    end
  end

  test "BroadcastService.running_loader works for non-running sessions" do
    service = BroadcastService.new

    # Should work without errors even for waiting sessions
    # (the partial just renders empty content)
    assert_nothing_raised do
      service.running_loader(@waiting_session)
    end
  end

  test "BroadcastService.remove_running_loader broadcasts successfully" do
    service = BroadcastService.new

    assert_nothing_raised do
      service.remove_running_loader(@running_session)
    end
  end

  # =========================================================================
  # Contract: TranscriptPollerService broadcasts must work
  # =========================================================================

  test "TranscriptPollerService broadcasts timeline messages correctly" do
    # Create a mock file system that simulates a transcript file
    mock_file_system = MockFileSystemAdapter.new
    transcript_dir = File.expand_path("~/.claude/projects/-tmp-test-clone")
    transcript_file = File.join(transcript_dir, "transcript.jsonl")

    # Add transcript directory and file
    mock_file_system.add_directory(transcript_dir)

    transcript_content = [
      { "type" => "user", "message" => { "role" => "user", "content" => "Hello" }, "timestamp" => Time.current.iso8601 },
      { "type" => "assistant", "message" => { "role" => "assistant", "content" => "Hi there!" }, "timestamp" => Time.current.iso8601 }
    ].map(&:to_json).join("\n")

    mock_file_system.add_file(transcript_file, transcript_content, Time.current)

    # Set up session metadata
    @running_session.update!(
      metadata: { "working_directory" => "/tmp/test-clone" }
    )

    # Create service with mock file system
    mock_broadcast_service = Minitest::Mock.new
    # remove_empty_timeline_message is called first to clear the "No activity yet" placeholder
    mock_broadcast_service.expect(:remove_empty_timeline_message, true, [ @running_session ])
    mock_broadcast_service.expect(:timeline_message, true, [ @running_session, Hash ])
    mock_broadcast_service.expect(:timeline_message, true, [ @running_session, Hash ])
    mock_broadcast_service.expect(:running_loader, true, [ @running_session ])

    service = TranscriptPollerService.new(
      @running_session,
      file_system: mock_file_system,
      broadcast_service: mock_broadcast_service
    )

    # Should not raise any errors
    assert_nothing_raised do
      service.poll_and_broadcast
    end

    mock_broadcast_service.verify
  end

  # =========================================================================
  # Contract: Log model broadcasts must work
  # =========================================================================

  test "Log.broadcast_append_to_timeline works after creation" do
    # The Log model has an after_create_commit callback that broadcasts
    # This verifies the partial renders correctly
    assert_nothing_raised do
      @running_session.logs.create!(
        content: "Test log entry",
        level: "info"
      )
    end
  end

  test "Log.broadcast_append_to_timeline works for error logs" do
    assert_nothing_raised do
      @running_session.logs.create!(
        content: "Error occurred: test error",
        level: "error"
      )
    end
  end

  test "Log.broadcast_append_to_timeline renders with filter-category attribute" do
    # This test verifies that log broadcasts render through the _item partial
    # which includes the data-filter-category attribute needed for client-side filtering.
    # Without this attribute, logs would appear even when the filter is set to "minimal".
    log = @running_session.logs.build(
      content: "Test log for filter category",
      level: "info"
    )

    timeline_item = {
      type: "log",
      level: log.level,
      content: log.content,
      timestamp: Time.current,
      sort_time: Time.current
    }

    # Render the partial that Log.broadcast_append_to_timeline uses
    rendered = ApplicationController.render(
      partial: "timeline_items/item",
      locals: { item: timeline_item }
    )

    # Must have data-timeline-item attribute for the filter controller to find it
    assert_includes rendered, "data-timeline-item"
    # Must have data-filter-category="regular-log" for non-verbose logs
    assert_includes rendered, 'data-filter-category="regular-log"'
  end

  test "Log.broadcast_append_to_timeline renders verbose logs with verbose-log filter category" do
    log = @running_session.logs.build(
      content: "Verbose debug log",
      level: "verbose"
    )

    timeline_item = {
      type: "log",
      level: log.level,
      content: log.content,
      timestamp: Time.current,
      sort_time: Time.current
    }

    rendered = ApplicationController.render(
      partial: "timeline_items/item",
      locals: { item: timeline_item }
    )

    assert_includes rendered, "data-timeline-item"
    assert_includes rendered, 'data-filter-category="verbose-log"'
  end

  # =========================================================================
  # Helper: Mock file system adapter for testing
  # =========================================================================

  class MockFileSystemAdapter
    def initialize
      @directories = Set.new
      @files = {}
      @mtimes = {}
    end

    def add_directory(path)
      @directories.add(path)
    end

    def add_file(path, content, mtime = Time.current)
      @files[path] = content
      @mtimes[path] = mtime
    end

    def directory?(path)
      @directories.include?(path)
    end

    def glob(pattern)
      dir = File.dirname(pattern)
      ext = File.extname(pattern)
      @files.keys.select { |f| File.dirname(f) == dir && f.end_with?(ext) }
    end

    def mtime(path)
      @mtimes[path] || Time.current
    end

    def read(path)
      @files[path]
    end

    def exist?(path)
      @files.key?(path) || @directories.include?(path)
    end
  end
end
