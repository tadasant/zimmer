# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"

class TranscriptPollerServiceTest < ActiveSupport::TestCase
  setup do
    @session = sessions(:running)
    @mock_file_system = MockFileSystemAdapter.new
    # Stub broadcasts globally for all tests in this file
    Turbo::StreamsChannel.stubs(:broadcast_append_to)
    Turbo::StreamsChannel.stubs(:broadcast_replace_to)
    Turbo::StreamsChannel.stubs(:broadcast_remove_to)
  end

  # === Tests for runtime-pluggable MCP status detector resolution (#3991) ===

  test "resolves the Claude Code MCP status detector for a claude_code session" do
    @session.update!(agent_runtime: "claude_code")
    service = TranscriptPollerService.new(@session, file_system: @mock_file_system)
    assert_instance_of McpLogPollerService, service.mcp_status_detector
  end

  test "resolves the Codex MCP status detector for a codex session" do
    @session.update!(agent_runtime: "codex")
    service = TranscriptPollerService.new(@session, file_system: @mock_file_system)
    assert_instance_of CodexMcpStatusDetector, service.mcp_status_detector
  end

  test "an explicitly injected detector overrides runtime resolution" do
    injected = Object.new
    service = TranscriptPollerService.new(@session, file_system: @mock_file_system, mcp_status_detector: injected)
    assert_same injected, service.mcp_status_detector
  end

  # === Tests for broadcast error handling (Issue #321) ===
  # Ensure broadcast failures don't stop transcript polling or crash jobs

  test "broadcast_new_messages should not raise when Turbo broadcast fails" do
    service = TranscriptPollerService.new(@session, file_system: @mock_file_system)

    # Stub Turbo::StreamsChannel methods to raise errors
    Turbo::StreamsChannel.stubs(:broadcast_remove_to).raises(StandardError, "Broadcast failed")
    Turbo::StreamsChannel.stubs(:broadcast_append_to).raises(StandardError, "Broadcast failed")

    # Create a simple message to broadcast
    messages = [
      { "type" => "user", "message" => { "role" => "user", "content" => "Hello" }, "timestamp" => "2025-11-20T10:00:00Z" }
    ]

    # Should not raise - error should be caught and logged
    # Use is_first_broadcast: true to exercise both the remove and append broadcast paths
    assert_nothing_raised do
      service.send(:broadcast_new_messages, messages, is_first_broadcast: true)
    end
  end

  test "broadcast_new_messages delegates to BroadcastService on first broadcast" do
    # Create mock broadcast service
    mock_broadcast_service = mock("BroadcastService")
    service = TranscriptPollerService.new(@session, file_system: @mock_file_system, broadcast_service: mock_broadcast_service)

    messages = [
      { "type" => "user", "message" => { "role" => "user", "content" => "Hello" }, "timestamp" => "2025-11-20T10:00:00Z" }
    ]

    # Verify BroadcastService methods are called in the correct order
    mock_broadcast_service.expects(:remove_empty_timeline_message).with(@session)
    mock_broadcast_service.expects(:timeline_message).with(@session, messages[0])

    service.send(:broadcast_new_messages, messages, is_first_broadcast: true)
  end

  test "broadcast_new_messages removes empty timeline message before first message" do
    # Create mock broadcast service
    mock_broadcast_service = mock("BroadcastService")
    service = TranscriptPollerService.new(@session, file_system: @mock_file_system, broadcast_service: mock_broadcast_service)

    messages = [
      { "type" => "user", "message" => { "role" => "user", "content" => "First" } },
      { "type" => "assistant", "message" => { "role" => "assistant", "content" => "Second" } }
    ]

    # Verify remove_empty_timeline_message is called exactly once (before any messages)
    call_sequence = sequence("broadcast_sequence")
    mock_broadcast_service.expects(:remove_empty_timeline_message).with(@session).once.in_sequence(call_sequence)
    mock_broadcast_service.expects(:timeline_message).with(@session, messages[0]).in_sequence(call_sequence)
    mock_broadcast_service.expects(:timeline_message).with(@session, messages[1]).in_sequence(call_sequence)

    service.send(:broadcast_new_messages, messages, is_first_broadcast: true)
  end

  test "broadcast_new_messages does not remove empty timeline message on subsequent broadcasts" do
    # Create mock broadcast service
    mock_broadcast_service = mock("BroadcastService")
    service = TranscriptPollerService.new(@session, file_system: @mock_file_system, broadcast_service: mock_broadcast_service)

    messages = [
      { "type" => "user", "message" => { "role" => "user", "content" => "Hello" } }
    ]

    # Verify remove_empty_timeline_message is NOT called when is_first_broadcast is false
    mock_broadcast_service.expects(:remove_empty_timeline_message).never
    mock_broadcast_service.expects(:timeline_message).with(@session, messages[0])

    service.send(:broadcast_new_messages, messages, is_first_broadcast: false)
  end

  test "broadcast_running_loader should not raise when Turbo broadcast fails" do
    service = TranscriptPollerService.new(@session, file_system: @mock_file_system)

    # Stub Turbo::StreamsChannel.broadcast_replace_to to raise an error
    Turbo::StreamsChannel.stubs(:broadcast_replace_to).raises(StandardError, "Broadcast failed")

    # Should not raise - error should be caught and logged
    assert_nothing_raised do
      service.send(:broadcast_running_loader)
    end
  end

  test "broadcast_running_loader delegates to BroadcastService" do
    # Create mock broadcast service
    mock_broadcast_service = mock("BroadcastService")
    service = TranscriptPollerService.new(@session, file_system: @mock_file_system, broadcast_service: mock_broadcast_service)

    # Verify BroadcastService is called with the session
    mock_broadcast_service.expects(:running_loader).with(@session)

    service.send(:broadcast_running_loader)
  end

  # === Tests for return value behavior (Issue #316) ===
  # Ensure poll_and_broadcast returns appropriate values for tracking failures

  test "poll_and_broadcast returns false when working_directory is missing" do
    # Create a session without working_directory in metadata
    session_without_working_dir = Session.create!(
      agent_runtime: "claude_code",
      status: :running,
      prompt: "Test prompt",
      git_root: "https://github.com/test/repo.git",
      branch: "main",
      execution_provider: "local_filesystem",
      metadata: {}  # No working_directory
    )

    service = TranscriptPollerService.new(session_without_working_dir, file_system: @mock_file_system)
    result = service.poll_and_broadcast

    assert_equal false, result, "Should return false when working_directory is missing"
  end

  test "poll_and_broadcast returns nil when waiting for transcript directory" do
    # Setup session with working_directory
    @session.update!(metadata: { "working_directory" => "/tmp/test-clone" })

    # Mock file system without the transcript directory
    @mock_file_system.stubs(:directory?).returns(false)

    service = TranscriptPollerService.new(@session, file_system: @mock_file_system)
    result = service.poll_and_broadcast

    assert_nil result, "Should return nil when waiting for transcript directory"
  end

  test "poll_and_broadcast returns nil when waiting for transcript files" do
    # Setup session with working_directory
    @session.update!(metadata: { "working_directory" => "/tmp/test-clone" })

    # Mock file system with transcript directory but no files
    @mock_file_system.stubs(:directory?).returns(true)
    @mock_file_system.stubs(:glob).returns([])

    service = TranscriptPollerService.new(@session, file_system: @mock_file_system)
    result = service.poll_and_broadcast

    assert_nil result, "Should return nil when waiting for transcript files"
  end

  test "poll_and_broadcast returns true on successful poll" do
    # Setup session with working_directory
    @session.update!(metadata: { "working_directory" => "/tmp/test-clone" })

    # Mock file system with transcript directory and files
    @mock_file_system.stubs(:directory?).returns(true)
    @mock_file_system.stubs(:glob).returns([ "/transcript/file.jsonl" ])
    @mock_file_system.stubs(:mtime).returns(Time.current)
    @mock_file_system.stubs(:read).returns('{"type":"user","message":{"role":"user","content":"Hello"}}')

    service = TranscriptPollerService.new(@session, file_system: @mock_file_system)
    result = service.poll_and_broadcast

    assert_equal true, result, "Should return true on successful poll"
  end

  test "poll_and_broadcast returns false when exception occurs" do
    # Setup session with working_directory
    @session.update!(metadata: { "working_directory" => "/tmp/test-clone" })

    # Mock file system to raise an error
    @mock_file_system.stubs(:directory?).raises(StandardError, "Test error")

    service = TranscriptPollerService.new(@session, file_system: @mock_file_system)
    result = service.poll_and_broadcast

    assert_equal false, result, "Should return false when exception occurs"
  end

  # === Tests for path sanitization (Issue #385) ===
  # Ensure underscores are replaced with dashes to match Claude CLI behavior

  test "get_transcript_directory replaces underscores with dashes in path" do
    # Setup session with working_directory containing underscores
    path_with_underscores = "/Users/admin/.agent-orchestrator/clones/agents-main-1764135379-fb59401d/agent-roots/pulsemcp-server-queue/00_preparer"
    @session.update!(metadata: { "working_directory" => path_with_underscores })

    service = TranscriptPollerService.new(@session, file_system: @mock_file_system)
    result = service.send(:get_transcript_directory)

    # Verify underscores are replaced with dashes
    assert_includes result, "00-preparer", "Underscores should be replaced with dashes"
    refute_includes result, "00_preparer", "Original underscores should not be present"
  end

  test "get_transcript_directory replaces all special characters with dashes" do
    # Setup session with working_directory containing multiple special characters
    path_with_special_chars = "/Users/test_user/.hidden_dir/project_name/sub_dir"
    @session.update!(metadata: { "working_directory" => path_with_special_chars })

    service = TranscriptPollerService.new(@session, file_system: @mock_file_system)
    result = service.send(:get_transcript_directory)

    # Build expected path
    home_dir = File.expand_path("~")
    expected_sanitized = "-Users-test-user--hidden-dir-project-name-sub-dir"
    expected_path = File.join(home_dir, ".claude", "projects", expected_sanitized)

    assert_equal expected_path, result, "All special characters (/, ., _) should be replaced with dashes"
  end

  # === Tests for nested agent transcript handling (Issue #405) ===
  # Ensure main transcript is selected by session_id, not by mtime

  test "find_main_transcript_file returns session_id file when present" do
    @session.update!(
      session_id: "abc123-def456",
      metadata: { "working_directory" => "/tmp/test-clone" }
    )

    transcript_dir = "/transcript/dir"

    # Create files in mock file system
    session_file = "#{transcript_dir}/abc123-def456.jsonl"
    agent_file = "#{transcript_dir}/agent-xyz789.jsonl"

    @mock_file_system.mkdir_p(transcript_dir)
    @mock_file_system.write(session_file, '{"type":"user"}')
    @mock_file_system.write(agent_file, '{"type":"user"}')

    # Make agent file more recent
    @mock_file_system.set_mtime(session_file, 1.hour.ago)
    @mock_file_system.set_mtime(agent_file, Time.current)

    service = TranscriptPollerService.new(@session, file_system: @mock_file_system)
    result = service.send(:find_main_transcript_file, transcript_dir)

    assert_equal session_file, result
  end

  test "find_main_transcript_file excludes agent files in fallback" do
    @session.update!(
      session_id: nil,
      metadata: { "working_directory" => "/tmp/test-clone" }
    )

    transcript_dir = "/transcript/dir"

    # Create only agent files and a main file
    main_file = "#{transcript_dir}/some-uuid.jsonl"
    agent_file1 = "#{transcript_dir}/agent-abc.jsonl"
    agent_file2 = "#{transcript_dir}/agent-xyz.jsonl"

    @mock_file_system.mkdir_p(transcript_dir)
    @mock_file_system.write(main_file, '{"type":"user"}')
    @mock_file_system.write(agent_file1, '{"type":"user"}')
    @mock_file_system.write(agent_file2, '{"type":"user"}')

    # Make agent files more recent
    @mock_file_system.set_mtime(main_file, 1.hour.ago)
    @mock_file_system.set_mtime(agent_file1, 30.minutes.ago)
    @mock_file_system.set_mtime(agent_file2, Time.current)

    service = TranscriptPollerService.new(@session, file_system: @mock_file_system)
    result = service.send(:find_main_transcript_file, transcript_dir)

    # Should return main file, not the more recent agent files
    assert_equal main_file, result
  end

  test "find_main_transcript_file returns nil when only agent files exist" do
    @session.update!(
      session_id: nil,
      metadata: { "working_directory" => "/tmp/test-clone" }
    )

    transcript_dir = "/transcript/dir"

    # Create only agent files
    @mock_file_system.mkdir_p(transcript_dir)
    @mock_file_system.write("#{transcript_dir}/agent-abc.jsonl", '{"type":"user"}')
    @mock_file_system.write("#{transcript_dir}/agent-xyz.jsonl", '{"type":"user"}')

    service = TranscriptPollerService.new(@session, file_system: @mock_file_system)
    result = service.send(:find_main_transcript_file, transcript_dir)

    assert_nil result
  end

  test "poll_subagent_transcripts stores agent files in database" do
    @session.update!(metadata: { "working_directory" => "/tmp/test-clone" })

    transcript_dir = File.join(File.expand_path("~"), ".claude", "projects", "-tmp-test-clone")
    agent_file = "#{transcript_dir}/agent-test123.jsonl"
    agent_content = "{\"type\":\"user\"}\n{\"type\":\"assistant\"}\n"

    @mock_file_system.mkdir_p(transcript_dir)
    @mock_file_system.write(agent_file, agent_content)

    service = TranscriptPollerService.new(@session, file_system: @mock_file_system)

    assert_difference "@session.subagent_transcripts.count", 1 do
      service.send(:poll_subagent_transcripts)
    end

    subagent = @session.subagent_transcripts.find_by(agent_id: "agent-test123")
    assert_not_nil subagent
    assert_equal "agent-test123.jsonl", subagent.filename
    assert_equal agent_content, subagent.transcript
    assert_equal 2, subagent.message_count
  end

  test "poll_subagent_transcripts updates existing records" do
    @session.update!(metadata: { "working_directory" => "/tmp/test-clone" })

    # Create existing subagent transcript
    @session.subagent_transcripts.create!(
      agent_id: "agent-existing",
      transcript: '{"old":"content"}',
      message_count: 1
    )

    transcript_dir = File.join(File.expand_path("~"), ".claude", "projects", "-tmp-test-clone")
    agent_file = "#{transcript_dir}/agent-existing.jsonl"
    new_content = "{\"type\":\"user\"}\n{\"type\":\"assistant\"}\n{\"type\":\"user\"}\n"

    @mock_file_system.mkdir_p(transcript_dir)
    @mock_file_system.write(agent_file, new_content)

    service = TranscriptPollerService.new(@session, file_system: @mock_file_system)

    assert_no_difference "@session.subagent_transcripts.count" do
      service.send(:poll_subagent_transcripts)
    end

    subagent = @session.subagent_transcripts.find_by(agent_id: "agent-existing")
    assert_equal new_content, subagent.transcript
    assert_equal 3, subagent.message_count
  end

  test "poll_subagent_transcripts handles multiple agent files" do
    @session.update!(metadata: { "working_directory" => "/tmp/test-clone" })

    transcript_dir = File.join(File.expand_path("~"), ".claude", "projects", "-tmp-test-clone")

    @mock_file_system.mkdir_p(transcript_dir)
    @mock_file_system.write("#{transcript_dir}/agent-one.jsonl", '{"type":"user"}')
    @mock_file_system.write("#{transcript_dir}/agent-two.jsonl", "{\"type\":\"user\"}\n{\"type\":\"assistant\"}")
    @mock_file_system.write("#{transcript_dir}/agent-three.jsonl", '{"type":"user"}')

    service = TranscriptPollerService.new(@session, file_system: @mock_file_system)

    assert_difference "@session.subagent_transcripts.count", 3 do
      service.send(:poll_subagent_transcripts)
    end

    assert @session.subagent_transcripts.exists?(agent_id: "agent-one")
    assert @session.subagent_transcripts.exists?(agent_id: "agent-two")
    assert @session.subagent_transcripts.exists?(agent_id: "agent-three")
  end

  test "poll_subagent_transcripts does nothing when no agent files exist" do
    @session.update!(metadata: { "working_directory" => "/tmp/test-clone" })

    transcript_dir = File.join(File.expand_path("~"), ".claude", "projects", "-tmp-test-clone")

    @mock_file_system.mkdir_p(transcript_dir)
    @mock_file_system.write("#{transcript_dir}/main-session.jsonl", '{"type":"user"}')

    service = TranscriptPollerService.new(@session, file_system: @mock_file_system)

    assert_no_difference "@session.subagent_transcripts.count" do
      service.send(:poll_subagent_transcripts)
    end
  end

  test "poll_and_broadcast uses session_id for main transcript" do
    @session.update!(
      session_id: "main-session-id",
      metadata: { "working_directory" => "/tmp/test-clone" }
    )

    # Calculate transcript directory path
    home_dir = File.expand_path("~")
    transcript_dir = File.join(home_dir, ".claude", "projects", "-tmp-test-clone")

    main_file = "#{transcript_dir}/main-session-id.jsonl"
    agent_file = "#{transcript_dir}/agent-newer.jsonl"

    @mock_file_system.mkdir_p(transcript_dir)
    @mock_file_system.write(main_file, '{"type":"user","message":{"role":"user","content":"Main session content"}}')
    @mock_file_system.write(agent_file, '{"type":"user","message":{"role":"user","content":"Agent content"}}')

    # Make agent file more recent
    @mock_file_system.set_mtime(main_file, 1.hour.ago)
    @mock_file_system.set_mtime(agent_file, Time.current)

    service = TranscriptPollerService.new(@session, file_system: @mock_file_system)
    result = service.poll_and_broadcast

    assert_equal true, result
    @session.reload
    assert_includes @session.transcript, "Main session content"
    refute_includes @session.transcript, "Agent content"
  end

  # === Tests for transcript regression guard (history-loss prevention) ===
  # When a clone is recreated at a new path, the runtime starts a fresh, shorter
  # transcript file. session.transcript is the only durable record, so the poller
  # must never overwrite a longer stored transcript with a shorter filesystem one.

  test "poll_and_broadcast preserves longer stored transcript when filesystem transcript is shorter" do
    long_transcript = (1..5).map { |i| %({"type":"user","message":{"role":"user","content":"msg #{i}"}}) }.join("\n")

    @session.update!(
      session_id: "sess-regression",
      transcript: long_transcript,
      metadata: { "working_directory" => "/tmp/test-clone", "broadcast_message_count" => 5 }
    )

    transcript_dir = File.join(File.expand_path("~"), ".claude", "projects", "-tmp-test-clone")
    main_file = "#{transcript_dir}/sess-regression.jsonl"

    # Recreated clone: fresh, shorter transcript file (2 messages)
    short_transcript = (1..2).map { |i| %({"type":"user","message":{"role":"user","content":"new #{i}"}}) }.join("\n")
    @mock_file_system.mkdir_p(transcript_dir)
    @mock_file_system.write(main_file, short_transcript)

    service = TranscriptPollerService.new(@session, file_system: @mock_file_system)
    result = service.poll_and_broadcast

    assert_equal true, result
    @session.reload
    assert_equal long_transcript, @session.transcript,
      "Stored transcript must not be overwritten by the shorter filesystem transcript"
    assert @session.metadata["transcript_regression_detected"],
      "Should flag that a regression was detected"
  end

  test "poll_and_broadcast updates stored transcript when filesystem transcript grows" do
    initial_transcript = (1..2).map { |i| %({"type":"user","message":{"role":"user","content":"msg #{i}"}}) }.join("\n")

    @session.update!(
      session_id: "sess-growth",
      transcript: initial_transcript,
      metadata: { "working_directory" => "/tmp/test-clone", "broadcast_message_count" => 2 }
    )

    transcript_dir = File.join(File.expand_path("~"), ".claude", "projects", "-tmp-test-clone")
    main_file = "#{transcript_dir}/sess-growth.jsonl"

    grown_transcript = (1..4).map { |i| %({"type":"user","message":{"role":"user","content":"msg #{i}"}}) }.join("\n")
    @mock_file_system.mkdir_p(transcript_dir)
    @mock_file_system.write(main_file, grown_transcript)

    service = TranscriptPollerService.new(@session, file_system: @mock_file_system)
    result = service.poll_and_broadcast

    assert_equal true, result
    @session.reload
    assert_equal grown_transcript, @session.transcript, "Grown transcript should be persisted"
    refute @session.metadata["transcript_regression_detected"]
  end

  test "poll_and_broadcast updates transcript when same line count but content changed" do
    stored_transcript = (1..3).map { |i| %({"type":"user","message":{"role":"user","content":"msg #{i}"}}) }.join("\n")

    @session.update!(
      session_id: "sess-edit",
      transcript: stored_transcript,
      metadata: { "working_directory" => "/tmp/test-clone", "broadcast_message_count" => 3 }
    )

    transcript_dir = File.join(File.expand_path("~"), ".claude", "projects", "-tmp-test-clone")
    main_file = "#{transcript_dir}/sess-edit.jsonl"

    # Same number of lines, but the last event was edited in place (not a regression)
    edited_transcript = [
      %({"type":"user","message":{"role":"user","content":"msg 1"}}),
      %({"type":"user","message":{"role":"user","content":"msg 2"}}),
      %({"type":"user","message":{"role":"user","content":"msg 3 EDITED"}})
    ].join("\n")
    @mock_file_system.mkdir_p(transcript_dir)
    @mock_file_system.write(main_file, edited_transcript)

    service = TranscriptPollerService.new(@session, file_system: @mock_file_system)
    result = service.poll_and_broadcast

    assert_equal true, result
    @session.reload
    assert_equal edited_transcript, @session.transcript, "Equal-length in-place edits should persist"
    refute @session.metadata["transcript_regression_detected"]
  end

  # === Tests for extract_subagent_links (Issue #509) ===
  # Ensure Array toolUseResult values don't crash the subagent linking logic

  test "extract_subagent_links handles Hash toolUseResult with agentId" do
    # Create a subagent transcript to be linked
    subagent = @session.subagent_transcripts.create!(
      agent_id: "agent-abc123",
      transcript: '{"type":"user"}',
      message_count: 1
    )

    # Build transcript messages with a Task tool_use and corresponding tool_result
    messages = [
      {
        "type" => "assistant",
        "message" => {
          "role" => "assistant",
          "content" => [
            {
              "type" => "tool_use",
              "id" => "tool-use-id-1",
              "name" => "Task",
              "input" => {
                "subagent_type" => "Explore",
                "description" => "Search for files"
              }
            }
          ]
        }
      },
      {
        "type" => "user",
        "message" => {
          "role" => "user",
          "content" => [
            {
              "type" => "tool_result",
              "tool_use_id" => "tool-use-id-1",
              "toolUseResult" => {
                "agentId" => "abc123",
                "status" => "completed",
                "totalDurationMs" => 5000,
                "totalTokens" => 1000,
                "totalToolUseCount" => 5
              }
            }
          ]
        }
      }
    ]

    mock_broadcast_service = mock("BroadcastService")
    mock_broadcast_service.expects(:subagent_accordion).with(@session, anything)

    service = TranscriptPollerService.new(@session, file_system: @mock_file_system, broadcast_service: mock_broadcast_service)
    task_tool_uses = service.send(:extract_task_tool_uses, messages)
    service.send(:extract_subagent_links, messages, task_tool_uses)

    subagent.reload
    assert_equal "tool-use-id-1", subagent.tool_use_id
    assert_equal "Explore", subagent.subagent_type
    assert_equal "Search for files", subagent.description
    assert_equal "completed", subagent.status
    assert_equal 5000, subagent.duration_ms
    assert_equal 1000, subagent.total_tokens
    assert_equal 5, subagent.tool_use_count
  end

  test "extract_subagent_links skips Array toolUseResult without crashing" do
    # Create a subagent transcript that should remain unlinked
    subagent = @session.subagent_transcripts.create!(
      agent_id: "agent-xyz789",
      transcript: '{"type":"user"}',
      message_count: 1
    )

    # Build transcript messages with Array toolUseResult (e.g., from TodoWrite)
    # This is the exact scenario from Issue #509 that caused TypeError
    messages = [
      {
        "type" => "user",
        "message" => {
          "role" => "user",
          "content" => [
            {
              "type" => "tool_result",
              "tool_use_id" => "todo-tool-use-id",
              "toolUseResult" => [
                { "content" => "Task 1", "status" => "pending" },
                { "content" => "Task 2", "status" => "in_progress" }
              ]
            }
          ]
        }
      }
    ]

    service = TranscriptPollerService.new(@session, file_system: @mock_file_system)

    # Should NOT raise TypeError: no implicit conversion of String into Integer
    assert_nothing_raised do
      service.send(:extract_subagent_links, messages, {})
    end

    # Subagent should remain unlinked
    subagent.reload
    assert_nil subagent.tool_use_id
  end

  test "extract_subagent_links processes Hash results after Array results without failing" do
    # Create subagents
    subagent1 = @session.subagent_transcripts.create!(
      agent_id: "agent-first",
      transcript: '{"type":"user"}',
      message_count: 1
    )

    # Build transcript with Array toolUseResult followed by Hash toolUseResult
    # This tests that Array results don't prevent later Hash results from being processed
    messages = [
      {
        "type" => "assistant",
        "message" => {
          "role" => "assistant",
          "content" => [
            {
              "type" => "tool_use",
              "id" => "task-tool-id",
              "name" => "Task",
              "input" => {
                "subagent_type" => "Plan",
                "description" => "Create implementation plan"
              }
            }
          ]
        }
      },
      {
        "type" => "user",
        "message" => {
          "role" => "user",
          "content" => [
            {
              # Array toolUseResult (e.g., TodoWrite) - should be skipped
              "type" => "tool_result",
              "tool_use_id" => "todo-id",
              "toolUseResult" => [ { "status" => "pending" } ]
            },
            {
              # Hash toolUseResult (Task tool) - should be processed
              "type" => "tool_result",
              "tool_use_id" => "task-tool-id",
              "toolUseResult" => {
                "agentId" => "first",
                "status" => "completed",
                "totalDurationMs" => 3000
              }
            }
          ]
        }
      }
    ]

    mock_broadcast_service = mock("BroadcastService")
    mock_broadcast_service.expects(:subagent_accordion).with(@session, anything)

    service = TranscriptPollerService.new(@session, file_system: @mock_file_system, broadcast_service: mock_broadcast_service)
    task_tool_uses = service.send(:extract_task_tool_uses, messages)

    assert_nothing_raised do
      service.send(:extract_subagent_links, messages, task_tool_uses)
    end

    # First subagent should be linked
    subagent1.reload
    assert_equal "task-tool-id", subagent1.tool_use_id
    assert_equal "Plan", subagent1.subagent_type
    assert_equal "completed", subagent1.status
  end

  test "extract_subagent_links skips nil toolUseResult" do
    subagent = @session.subagent_transcripts.create!(
      agent_id: "agent-test",
      transcript: '{"type":"user"}',
      message_count: 1
    )

    # Build transcript with nil toolUseResult
    messages = [
      {
        "type" => "user",
        "message" => {
          "role" => "user",
          "content" => [
            {
              "type" => "tool_result",
              "tool_use_id" => "some-id",
              "toolUseResult" => nil
            }
          ]
        }
      }
    ]

    service = TranscriptPollerService.new(@session, file_system: @mock_file_system)

    assert_nothing_raised do
      service.send(:extract_subagent_links, messages, {})
    end

    subagent.reload
    assert_nil subagent.tool_use_id
  end

  test "extract_subagent_links skips Hash toolUseResult without agentId" do
    subagent = @session.subagent_transcripts.create!(
      agent_id: "agent-test",
      transcript: '{"type":"user"}',
      message_count: 1
    )

    # Build transcript with Hash toolUseResult but no agentId (e.g., Bash tool result)
    messages = [
      {
        "type" => "user",
        "message" => {
          "role" => "user",
          "content" => [
            {
              "type" => "tool_result",
              "tool_use_id" => "bash-id",
              "toolUseResult" => {
                "stdout" => "Hello, World!",
                "stderr" => "",
                "interrupted" => false
              }
            }
          ]
        }
      }
    ]

    service = TranscriptPollerService.new(@session, file_system: @mock_file_system)

    assert_nothing_raised do
      service.send(:extract_subagent_links, messages, {})
    end

    subagent.reload
    assert_nil subagent.tool_use_id
  end

  # === Tests for MCP log polling integration ===

  test "poll_and_broadcast polls MCP logs when session has mcp_servers configured" do
    # Configure session with MCP servers and working directory
    @session.update!(
      mcp_servers: [ "context7" ],
      metadata: { "working_directory" => "/tmp/test-clone" }
    )

    # Setup transcript directory
    home_dir = File.expand_path("~")
    transcript_dir = File.join(home_dir, ".claude", "projects", "-tmp-test-clone")
    transcript_file = "#{transcript_dir}/test-session.jsonl"

    @mock_file_system.mkdir_p(transcript_dir)
    @mock_file_system.write(transcript_file, '{"type":"user","message":{"role":"user","content":"Hello"}}')

    # Setup MCP log directory (uses .jsonl extension and JSONL format)
    cache_dir = File.join(PathSanitizer.cache_base, "-tmp-test-clone")
    mcp_log_dir = File.join(cache_dir, "mcp-logs-context7")
    mcp_log_file = File.join(mcp_log_dir, "2025-01-15T10-00-00.jsonl")

    @mock_file_system.mkdir_p(mcp_log_dir)
    @mock_file_system.write(mcp_log_file, '{"timestamp":"2025-01-15T10:00:00Z","debug":"Successfully connected to MCP server"}')

    # Create mock broadcast service to verify MCP logs are broadcast
    mock_broadcast_service = mock("BroadcastService")
    mock_broadcast_service.stubs(:remove_empty_timeline_message)
    mock_broadcast_service.stubs(:running_loader)

    # Capture calls to timeline_message
    mcp_log_received = false
    mock_broadcast_service.stubs(:timeline_message).with do |session, message|
      if message["type"] == "mcp_log" && message["server_name"] == "context7"
        mcp_log_received = true
      end
      true
    end

    service = TranscriptPollerService.new(@session, file_system: @mock_file_system, broadcast_service: mock_broadcast_service)
    result = service.poll_and_broadcast

    assert_equal true, result
    assert mcp_log_received, "Expected MCP log to be broadcast via timeline_message"

    # Verify session metadata was updated with MCP status
    @session.reload
    mcp_status = @session.custom_metadata&.dig("mcp_servers_status", "context7")
    assert_not_nil mcp_status
    assert_equal "connected", mcp_status["status"]
  end

  test "poll_and_broadcast marks session for failure when MCP server fails to connect" do
    # Configure session with MCP servers and working directory
    @session.update!(
      mcp_servers: [ "context7" ],
      metadata: { "working_directory" => "/tmp/test-clone" }
    )

    # Setup transcript directory
    home_dir = File.expand_path("~")
    transcript_dir = File.join(home_dir, ".claude", "projects", "-tmp-test-clone")
    transcript_file = "#{transcript_dir}/test-session.jsonl"

    @mock_file_system.mkdir_p(transcript_dir)
    @mock_file_system.write(transcript_file, '{"type":"user","message":{"role":"user","content":"Hello"}}')

    # Setup MCP log directory with a failure message (uses .jsonl extension and JSONL format)
    cache_dir = File.join(PathSanitizer.cache_base, "-tmp-test-clone")
    mcp_log_dir = File.join(cache_dir, "mcp-logs-context7")
    mcp_log_file = File.join(mcp_log_dir, "2025-01-15T10-00-00.jsonl")

    @mock_file_system.mkdir_p(mcp_log_dir)
    @mock_file_system.write(mcp_log_file, '{"timestamp":"2025-01-15T10:00:00Z","error":"Connection failed: timeout"}')

    mock_broadcast_service = mock("BroadcastService")
    mock_broadcast_service.stubs(:remove_empty_timeline_message)
    mock_broadcast_service.stubs(:timeline_message)
    mock_broadcast_service.stubs(:running_loader)
    mock_broadcast_service.stubs(:timeline_mcp_log)

    service = TranscriptPollerService.new(@session, file_system: @mock_file_system, broadcast_service: mock_broadcast_service)
    service.poll_and_broadcast

    # Verify session was marked for failure
    @session.reload
    assert_equal true, @session.custom_metadata["should_fail_session"]
    assert_equal true, @session.custom_metadata["mcp_connection_checked"]
    assert_includes @session.custom_metadata["mcp_failure_reason"], "context7"
  end

  test "poll_and_broadcast polls MCP logs when only injected mcp_servers present (no configured)" do
    # Sessions whose root has no mcp_servers of its own but receives auto-injected
    # servers (e.g. agent-orchestrator for subagent roots) should still get their
    # connection status tracked. Without this, the UI shows the injected server as
    # "pending" forever even though it's connected and serving tools.
    @session.update!(
      mcp_servers: [],
      metadata: { "working_directory" => "/tmp/test-clone" },
      custom_metadata: { "injected_mcp_servers" => [ "context7" ] }
    )

    home_dir = File.expand_path("~")
    transcript_dir = File.join(home_dir, ".claude", "projects", "-tmp-test-clone")
    transcript_file = "#{transcript_dir}/test-session.jsonl"
    @mock_file_system.mkdir_p(transcript_dir)
    @mock_file_system.write(transcript_file, '{"type":"user","message":{"role":"user","content":"Hello"}}')

    cache_dir = File.join(PathSanitizer.cache_base, "-tmp-test-clone")
    mcp_log_dir = File.join(cache_dir, "mcp-logs-context7")
    mcp_log_file = File.join(mcp_log_dir, "2025-01-15T10-00-00.jsonl")
    @mock_file_system.mkdir_p(mcp_log_dir)
    @mock_file_system.write(mcp_log_file, '{"timestamp":"2025-01-15T10:00:00Z","debug":"Successfully connected to MCP server"}')

    mock_broadcast_service = mock("BroadcastService")
    mock_broadcast_service.stubs(:remove_empty_timeline_message)
    mock_broadcast_service.stubs(:running_loader)
    mock_broadcast_service.stubs(:timeline_message)

    service = TranscriptPollerService.new(@session, file_system: @mock_file_system, broadcast_service: mock_broadcast_service)
    service.poll_and_broadcast

    @session.reload
    mcp_status = @session.custom_metadata&.dig("mcp_servers_status", "context7")
    assert_not_nil mcp_status, "Auto-injected server status must be tracked even when no servers are explicitly configured"
    assert_equal "connected", mcp_status["status"]
    # Injected-only failures should never auto-fail the session, but here we're connected anyway
    assert_nil @session.custom_metadata["should_fail_session"]
  end

  test "poll_and_broadcast skips MCP polling when no mcp_servers configured" do
    # Configure session without MCP servers
    @session.update!(
      mcp_servers: [],
      metadata: { "working_directory" => "/tmp/test-clone" }
    )

    # Setup transcript directory
    home_dir = File.expand_path("~")
    transcript_dir = File.join(home_dir, ".claude", "projects", "-tmp-test-clone")
    transcript_file = "#{transcript_dir}/test-session.jsonl"

    @mock_file_system.mkdir_p(transcript_dir)
    @mock_file_system.write(transcript_file, '{"type":"user","message":{"role":"user","content":"Hello"}}')

    mock_broadcast_service = mock("BroadcastService")
    mock_broadcast_service.stubs(:remove_empty_timeline_message)
    mock_broadcast_service.stubs(:timeline_message)
    mock_broadcast_service.stubs(:running_loader)
    # Should NOT receive any MCP log broadcasts
    mock_broadcast_service.expects(:timeline_mcp_log).never

    service = TranscriptPollerService.new(@session, file_system: @mock_file_system, broadcast_service: mock_broadcast_service)
    result = service.poll_and_broadcast

    assert_equal true, result
  end

  # === Tests for sent_message clearing (Issue: message persistence/recovery) ===
  # Ensure sent_message is cleared from metadata when it appears in transcript

  test "clear_sent_message_if_found clears sent_message when matching user message found" do
    @session.update!(
      metadata: {
        "working_directory" => "/tmp/test-clone",
        "sent_message" => "What is the weather today?",
        "sent_message_at" => Time.current.iso8601
      }
    )

    messages = [
      {
        "type" => "user",
        "message" => {
          "role" => "user",
          "content" => "What is the weather today?"
        }
      }
    ]

    metadata_updates = {}
    service = TranscriptPollerService.new(@session, file_system: @mock_file_system)
    service.send(:clear_sent_message_if_found, messages, metadata_updates)

    # Verify the keys were added to trigger clearing (not just that they're nil)
    assert metadata_updates.key?("sent_message"), "sent_message key should be present in metadata_updates"
    assert metadata_updates.key?("sent_message_at"), "sent_message_at key should be present in metadata_updates"
    assert_nil metadata_updates["sent_message"]
    assert_nil metadata_updates["sent_message_at"]
  end

  test "clear_sent_message_if_found clears sent_message when content is array format" do
    @session.update!(
      metadata: {
        "working_directory" => "/tmp/test-clone",
        "sent_message" => "Fix the bug in auth.rb",
        "sent_message_at" => Time.current.iso8601
      }
    )

    # Array content format (sometimes used in transcripts)
    messages = [
      {
        "type" => "user",
        "message" => {
          "role" => "user",
          "content" => [
            { "type" => "text", "text" => "Fix the bug in auth.rb" }
          ]
        }
      }
    ]

    metadata_updates = {}
    service = TranscriptPollerService.new(@session, file_system: @mock_file_system)
    service.send(:clear_sent_message_if_found, messages, metadata_updates)

    # Verify the keys were added to trigger clearing
    assert metadata_updates.key?("sent_message"), "sent_message key should be present in metadata_updates"
    assert metadata_updates.key?("sent_message_at"), "sent_message_at key should be present in metadata_updates"
    assert_nil metadata_updates["sent_message"]
    assert_nil metadata_updates["sent_message_at"]
  end

  test "clear_sent_message_if_found does not clear when no matching message" do
    @session.update!(
      metadata: {
        "working_directory" => "/tmp/test-clone",
        "sent_message" => "Original message",
        "sent_message_at" => Time.current.iso8601
      }
    )

    messages = [
      {
        "type" => "assistant",
        "message" => {
          "role" => "assistant",
          "content" => "This is a response"
        }
      }
    ]

    metadata_updates = {}
    service = TranscriptPollerService.new(@session, file_system: @mock_file_system)
    service.send(:clear_sent_message_if_found, messages, metadata_updates)

    refute metadata_updates.key?("sent_message")
    refute metadata_updates.key?("sent_message_at")
  end

  test "clear_sent_message_if_found does nothing when no sent_message in metadata" do
    @session.update!(
      metadata: { "working_directory" => "/tmp/test-clone" }
    )

    messages = [
      {
        "type" => "user",
        "message" => {
          "role" => "user",
          "content" => "Hello there"
        }
      }
    ]

    metadata_updates = {}
    service = TranscriptPollerService.new(@session, file_system: @mock_file_system)
    service.send(:clear_sent_message_if_found, messages, metadata_updates)

    # Should not modify metadata_updates when there's no sent_message
    refute metadata_updates.key?("sent_message")
  end

  test "clear_sent_message_if_found does NOT clear on partial match (prevents false positives)" do
    @session.update!(
      metadata: {
        "working_directory" => "/tmp/test-clone",
        "sent_message" => "fix bug",
        "sent_message_at" => Time.current.iso8601
      }
    )

    # Message contains the sent_message but is not an exact match
    # Should NOT clear to prevent false positives with short common strings
    messages = [
      {
        "type" => "user",
        "message" => {
          "role" => "user",
          "content" => "Please fix bug in auth module"
        }
      }
    ]

    metadata_updates = {}
    service = TranscriptPollerService.new(@session, file_system: @mock_file_system)
    service.send(:clear_sent_message_if_found, messages, metadata_updates)

    # Should NOT have added the keys since no exact match was found
    refute metadata_updates.key?("sent_message"), "sent_message key should NOT be present (no exact match)"
  end

  test "clear_sent_message_if_found handles whitespace differences" do
    @session.update!(
      metadata: {
        "working_directory" => "/tmp/test-clone",
        "sent_message" => "  fix bug  ",
        "sent_message_at" => Time.current.iso8601
      }
    )

    # Message has different whitespace but same content after stripping
    messages = [
      {
        "type" => "user",
        "message" => {
          "role" => "user",
          "content" => "fix bug"
        }
      }
    ]

    metadata_updates = {}
    service = TranscriptPollerService.new(@session, file_system: @mock_file_system)
    service.send(:clear_sent_message_if_found, messages, metadata_updates)

    # Should clear since the messages match after stripping whitespace
    assert metadata_updates.key?("sent_message"), "sent_message key should be present after whitespace-normalized match"
    assert_nil metadata_updates["sent_message"]
  end

  test "poll_and_broadcast clears sent_message when found in new transcript messages" do
    @session.update!(
      session_id: "test-session-123",
      metadata: {
        "working_directory" => "/tmp/test-clone",
        "sent_message" => "Test message content",
        "sent_message_at" => Time.current.iso8601,
        "broadcast_message_count" => 0
      }
    )

    # Setup transcript directory with matching message
    home_dir = File.expand_path("~")
    transcript_dir = File.join(home_dir, ".claude", "projects", "-tmp-test-clone")
    transcript_file = "#{transcript_dir}/test-session-123.jsonl"

    @mock_file_system.mkdir_p(transcript_dir)
    @mock_file_system.write(
      transcript_file,
      '{"type":"user","message":{"role":"user","content":"Test message content"}}'
    )

    mock_broadcast_service = mock("BroadcastService")
    mock_broadcast_service.stubs(:remove_empty_timeline_message)
    mock_broadcast_service.stubs(:timeline_message)
    mock_broadcast_service.stubs(:running_loader)

    service = TranscriptPollerService.new(@session, file_system: @mock_file_system, broadcast_service: mock_broadcast_service)
    result = service.poll_and_broadcast

    assert_equal true, result

    @session.reload
    assert_nil @session.metadata["sent_message"]
    assert_nil @session.metadata["sent_message_at"]
  end

  # === Tests for MCP activity tracking ===
  # Ensure MCP logs update last_timeline_entry_at to prevent hung process detection

  test "broadcast_mcp_logs updates last_timeline_entry_at to prevent hung process detection" do
    # Set last_timeline_entry_at to a time in the past to simulate an "inactive" session
    past_time = 20.minutes.ago
    @session.update!(last_timeline_entry_at: past_time)

    mock_broadcast_service = mock("BroadcastService")
    mock_broadcast_service.stubs(:timeline_message)

    service = TranscriptPollerService.new(@session, file_system: @mock_file_system, broadcast_service: mock_broadcast_service)

    # Simulate MCP logs from a subagent
    mcp_logs = [
      { server_name: "test-server", level: "info", message: "Tool 'search' started", timestamp: Time.current.iso8601 },
      { server_name: "test-server", level: "info", message: "Tool 'search' completed", timestamp: Time.current.iso8601 }
    ]

    # Call broadcast_mcp_logs directly
    service.send(:broadcast_mcp_logs, mcp_logs)

    @session.reload
    # last_timeline_entry_at should be updated to current time (not the past time)
    assert @session.last_timeline_entry_at > past_time,
      "Expected last_timeline_entry_at to be updated from #{past_time} but was #{@session.last_timeline_entry_at}"
    # Should be within the last few seconds
    assert @session.last_timeline_entry_at > 5.seconds.ago,
      "Expected last_timeline_entry_at to be recent but was #{@session.last_timeline_entry_at}"
    # Metadata should also be updated with broadcast count
    assert_equal 2, @session.metadata["broadcast_mcp_log_count"]
  end

  test "broadcast_mcp_logs does not update last_timeline_entry_at when no new logs" do
    # Set last_timeline_entry_at to a specific time
    original_time = 10.minutes.ago
    @session.update!(
      last_timeline_entry_at: original_time,
      metadata: { "broadcast_mcp_log_count" => 2 }
    )

    mock_broadcast_service = mock("BroadcastService")
    # Should not be called since there are no new logs
    mock_broadcast_service.expects(:timeline_message).never

    service = TranscriptPollerService.new(@session, file_system: @mock_file_system, broadcast_service: mock_broadcast_service)

    # Simulate MCP logs that have already been broadcast (count matches)
    mcp_logs = [
      { server_name: "test-server", level: "info", message: "Tool 'search' started", timestamp: Time.current.iso8601 },
      { server_name: "test-server", level: "info", message: "Tool 'search' completed", timestamp: Time.current.iso8601 }
    ]

    service.send(:broadcast_mcp_logs, mcp_logs)

    @session.reload
    # last_timeline_entry_at should NOT be updated since there were no new logs
    assert_in_delta original_time.to_f, @session.last_timeline_entry_at.to_f, 1.0,
      "Expected last_timeline_entry_at to remain unchanged"
  end

  # === Tests for stale broadcast_message_count after restart ===
  # Regression test for silent transcript bug: when a session is restarted,
  # a stale broadcast_message_count from the previous run causes the poller
  # to skip all messages in the new (shorter) transcript.

  test "stale broadcast_message_count causes messages to be silently skipped" do
    @session.update!(
      session_id: "test-session-stale",
      metadata: {
        "working_directory" => "/tmp/test-clone",
        # Simulate stale count from a previous run that had 42 messages
        "broadcast_message_count" => 42
      }
    )

    # New transcript after restart has only 2 messages
    home_dir = File.expand_path("~")
    transcript_dir = File.join(home_dir, ".claude", "projects", "-tmp-test-clone")
    transcript_file = "#{transcript_dir}/test-session-stale.jsonl"

    @mock_file_system.mkdir_p(transcript_dir)
    @mock_file_system.write(
      transcript_file,
      "{\"type\":\"user\",\"message\":{\"role\":\"user\",\"content\":\"Hello\"}}\n" \
      "{\"type\":\"assistant\",\"message\":{\"role\":\"assistant\",\"content\":\"Hi there\"}}"
    )

    mock_broadcast_service = mock("BroadcastService")
    mock_broadcast_service.stubs(:remove_empty_timeline_message)
    mock_broadcast_service.stubs(:running_loader)
    # With stale count of 42, no messages should be broadcast since the new
    # transcript only has 2 messages (index 0 and 1, both < 42)
    mock_broadcast_service.expects(:timeline_message).never

    service = TranscriptPollerService.new(@session, file_system: @mock_file_system, broadcast_service: mock_broadcast_service)
    result = service.poll_and_broadcast

    assert_equal true, result, "poll_and_broadcast should return true (transcript was read)"
  end

  test "nil broadcast_message_count with no stored transcript broadcasts all messages (fresh session)" do
    @session.update!(
      session_id: "test-session-fresh",
      transcript: nil, # No stored transcript yet (fresh session)
      metadata: {
        "working_directory" => "/tmp/test-clone"
        # broadcast_message_count is nil (fresh session, never polled before)
      }
    )

    # Transcript file has 2 messages
    home_dir = File.expand_path("~")
    transcript_dir = File.join(home_dir, ".claude", "projects", "-tmp-test-clone")
    transcript_file = "#{transcript_dir}/test-session-fresh.jsonl"

    @mock_file_system.mkdir_p(transcript_dir)
    @mock_file_system.write(
      transcript_file,
      "{\"type\":\"user\",\"message\":{\"role\":\"user\",\"content\":\"Hello\"}}\n" \
      "{\"type\":\"assistant\",\"message\":{\"role\":\"assistant\",\"content\":\"Hi there\"}}"
    )

    mock_broadcast_service = mock("BroadcastService")
    mock_broadcast_service.stubs(:remove_empty_timeline_message)
    mock_broadcast_service.stubs(:running_loader)
    # With no stored transcript, both messages should be broadcast
    mock_broadcast_service.expects(:timeline_message).twice

    service = TranscriptPollerService.new(@session, file_system: @mock_file_system, broadcast_service: mock_broadcast_service)
    result = service.poll_and_broadcast

    assert_equal true, result, "poll_and_broadcast should return true"

    @session.reload
    assert_equal 2, @session.metadata["broadcast_message_count"],
      "broadcast_message_count should be updated to reflect new transcript length"
  end

  # === Tests for message replay prevention after recovery ===
  # Regression test for message replay bug: when a session is recovered after
  # interruption (deploy, crash, etc.), broadcast_message_count is cleared via
  # STALE_RETRY_METADATA_KEYS. Without the fix, the poller defaults to 0 and
  # re-broadcasts the entire transcript, causing old messages to "replay" rapidly
  # when a user opens the session page.

  test "nil broadcast_message_count with stored transcript recovers count and skips old messages" do
    # Simulate a session that had 5 messages broadcast before recovery
    stored_transcript = (1..5).map { |i|
      "{\"type\":\"assistant\",\"message\":{\"role\":\"assistant\",\"content\":\"Message #{i}\"}}"
    }.join("\n")

    @session.update!(
      session_id: "test-session-recovery",
      transcript: stored_transcript, # 5 messages already stored in DB
      metadata: {
        "working_directory" => "/tmp/test-clone"
        # broadcast_message_count is nil — cleared by STALE_RETRY_METADATA_KEYS during recovery
      }
    )

    # Transcript file now has 7 messages (5 old + 2 new after recovery)
    home_dir = File.expand_path("~")
    transcript_dir = File.join(home_dir, ".claude", "projects", "-tmp-test-clone")
    transcript_file = "#{transcript_dir}/test-session-recovery.jsonl"

    file_transcript = (1..5).map { |i|
      "{\"type\":\"assistant\",\"message\":{\"role\":\"assistant\",\"content\":\"Message #{i}\"}}"
    }
    file_transcript += [
      "{\"type\":\"user\",\"message\":{\"role\":\"user\",\"content\":\"New message after recovery\"}}",
      "{\"type\":\"assistant\",\"message\":{\"role\":\"assistant\",\"content\":\"New response after recovery\"}}"
    ]

    @mock_file_system.mkdir_p(transcript_dir)
    @mock_file_system.write(transcript_file, file_transcript.join("\n"))

    mock_broadcast_service = mock("BroadcastService")
    mock_broadcast_service.stubs(:remove_empty_timeline_message)
    mock_broadcast_service.stubs(:running_loader)
    # Only the 2 NEW messages should be broadcast, not all 7
    mock_broadcast_service.expects(:timeline_message).twice

    service = TranscriptPollerService.new(@session, file_system: @mock_file_system, broadcast_service: mock_broadcast_service)
    result = service.poll_and_broadcast

    assert_equal true, result, "poll_and_broadcast should return true"

    @session.reload
    assert_equal 7, @session.metadata["broadcast_message_count"],
      "broadcast_message_count should be updated to total transcript length (7)"
  end

  test "nil broadcast_message_count with stored transcript and no new messages does not broadcast" do
    # Session was recovered but transcript file hasn't changed yet
    stored_transcript =
      "{\"type\":\"user\",\"message\":{\"role\":\"user\",\"content\":\"Hello\"}}\n" \
      "{\"type\":\"assistant\",\"message\":{\"role\":\"assistant\",\"content\":\"Hi there\"}}"

    @session.update!(
      session_id: "test-session-recovery-noop",
      transcript: stored_transcript, # 2 messages stored
      metadata: {
        "working_directory" => "/tmp/test-clone"
        # broadcast_message_count is nil — cleared during recovery
      }
    )

    # Transcript file has the same 2 messages (no new ones yet)
    home_dir = File.expand_path("~")
    transcript_dir = File.join(home_dir, ".claude", "projects", "-tmp-test-clone")
    transcript_file = "#{transcript_dir}/test-session-recovery-noop.jsonl"

    @mock_file_system.mkdir_p(transcript_dir)
    @mock_file_system.write(transcript_file, stored_transcript)

    mock_broadcast_service = mock("BroadcastService")
    mock_broadcast_service.stubs(:remove_empty_timeline_message)
    mock_broadcast_service.stubs(:running_loader)
    # No messages should be broadcast — stored transcript matches file
    mock_broadcast_service.expects(:timeline_message).never

    service = TranscriptPollerService.new(@session, file_system: @mock_file_system, broadcast_service: mock_broadcast_service)
    result = service.poll_and_broadcast

    assert_equal true, result, "poll_and_broadcast should return true"

    @session.reload
    assert_equal 2, @session.metadata["broadcast_message_count"],
      "broadcast_message_count should be recovered to stored transcript count (2)"
  end

  # === Runtime session id capture (#3884) ===
  # Codex mints its own rollout/thread UUID and ignores the Zimmer-supplied id; the
  # poller must capture that UUID from the transcript so resume can target it.
  # Claude honors the Zimmer-supplied id, so capture is gated off for it entirely
  # (mints_own_session_id? == false) — see the forked-session regression below.

  test "capture_runtime_session_id! persists a changed runtime id from the transcript (Codex)" do
    @session.update!(agent_runtime: "codex")
    @session.update_column(:session_id, "ao-supplied-uuid")
    service = TranscriptPollerService.new(@session, file_system: @mock_file_system)
    service.instance_variable_get(:@normalizer)
      .stubs(:extract_session_id).returns(nil, "codex-real-uuid")

    events = [ { "type" => "event_msg" }, { "type" => "session_meta" } ]
    service.send(:capture_runtime_session_id!, events)

    assert_equal "codex-real-uuid", @session.reload.session_id
  end

  test "capture_runtime_session_id! is a no-op when the runtime id already matches (Codex)" do
    @session.update!(agent_runtime: "codex")
    @session.update_column(:session_id, "same-uuid")
    service = TranscriptPollerService.new(@session, file_system: @mock_file_system)
    service.instance_variable_get(:@normalizer).stubs(:extract_session_id).returns("same-uuid")

    # No DB write should occur when the id is unchanged.
    Session.any_instance.expects(:update_column).never
    service.send(:capture_runtime_session_id!, [ { "type" => "session_meta" } ])

    assert_equal "same-uuid", @session.reload.session_id
  end

  test "capture_runtime_session_id! leaves session_id untouched when none is present (Codex)" do
    @session.update!(agent_runtime: "codex")
    @session.update_column(:session_id, "keep-me")
    service = TranscriptPollerService.new(@session, file_system: @mock_file_system)
    service.instance_variable_get(:@normalizer).stubs(:extract_session_id).returns(nil)

    service.send(:capture_runtime_session_id!, [ { "type" => "event_msg" } ])

    assert_equal "keep-me", @session.reload.session_id
  end

  # Regression for the forked-Claude-session "transcript_unavailable" failure:
  # a fork's transcript is copied from its source, so its early lines carry the
  # SOURCE session's sessionId. Claude honors the Zimmer-supplied id (capture is
  # gated off), so the fork's own session_id must survive untouched even though
  # a foreign id appears in the transcript. Capturing it would have tried to
  # rewrite the fork's session_id to the source's, colliding with the unique
  # session_id index (RecordNotUnique) and failing every poll.
  test "capture_runtime_session_id! never overwrites a Claude session id from a foreign (forked) transcript" do
    @session.update!(agent_runtime: "claude_code")
    @session.update_column(:session_id, "fork-own-uuid")

    service = TranscriptPollerService.new(@session, file_system: @mock_file_system)
    # No DB write should occur for Claude regardless of transcript content.
    Session.any_instance.expects(:update_column).never

    # Real (un-stubbed) Claude normalizer: the foreign sessionId is the source's.
    foreign_events = [
      { "type" => "queue-operation", "sessionId" => "source-session-uuid" },
      { "type" => "assistant", "sessionId" => "source-session-uuid" }
    ]
    service.send(:capture_runtime_session_id!, foreign_events)

    assert_equal "fork-own-uuid", @session.reload.session_id,
      "Claude fork's authoritative session_id must not be overwritten from copied source transcript lines"
  end
end
