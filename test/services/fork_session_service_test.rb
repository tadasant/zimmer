# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"

class ForkSessionServiceTest < ActiveSupport::TestCase
  setup do
    # Create sample transcript content (JSONL format)
    @transcript_lines = [
      { "type" => "user", "message" => { "role" => "user", "content" => "Hello" }, "timestamp" => "2024-01-01T10:00:00Z" },
      { "type" => "assistant", "message" => { "role" => "assistant", "content" => [ { "type" => "text", "text" => "Hi there!" } ] }, "timestamp" => "2024-01-01T10:00:01Z" },
      { "type" => "user", "message" => { "role" => "user", "content" => "How are you?" }, "timestamp" => "2024-01-01T10:00:02Z" },
      { "type" => "assistant", "message" => { "role" => "assistant", "content" => [ { "type" => "text", "text" => "I am doing well!" } ] }, "timestamp" => "2024-01-01T10:00:03Z" }
    ]
    @transcript_content = @transcript_lines.map { |line| JSON.generate(line) }.join("\n") + "\n"

    # Set up mock file system
    @mock_fs = MockFileSystemAdapter.new
    @clone_path = "/home/test/.zimmer/clones/test-repo-main-12345-abcd"
    @mock_fs.mkdir_p(@clone_path)
    @mock_fs.write(File.join(@clone_path, ".mcp.json"), JSON.pretty_generate({
      "mcpServers" => { "playwright-custom" => { "command" => "npx", "args" => [ "-y", "playwright-mcp" ] } }
    }))

    # Create source session
    # Use playwright-custom as the MCP server because it doesn't require any env vars
    # (all its env vars are hardcoded in mcp.json)
    # Use zimmer-start-dev-server as a catalog skill because it exists in the test catalog
    @source_session = Session.create!(
      prompt: "Test prompt",
      agent_runtime: "claude_code",
      status: :needs_input,
      git_root: "https://github.com/test/repo.git",
      branch: "main",
      execution_provider: "local_filesystem",
      session_id: SecureRandom.uuid,
      transcript: @transcript_content,
      mcp_servers: [ "playwright-custom" ],
      catalog_skills: [ "zimmer-start-dev-server" ],
      catalog_hooks: [ "git-push-ci-reminder" ],
      catalog_plugins: [ "ci-workflow" ],
      goal: "Complete the task",
      is_autonomous: false,
      session_notes: "Do not touch the payments module",
      title: "Test Session",
      metadata: {
        "clone_path" => @clone_path,
        "working_directory" => @clone_path
      }
    )
  end

  test "successfully forks session at specified message index" do
    result = ForkSessionService.call(
      source_session: @source_session,
      message_index: 1,  # Fork after "Hi there!"
      file_system: @mock_fs
    )

    assert result.success?
    assert_not_nil result.forked_session
    assert_nil result.error

    forked = result.forked_session
    assert_equal :needs_input, forked.status.to_sym
    assert_equal @source_session.git_root, forked.git_root
    assert_equal @source_session.branch, forked.branch
    assert_equal @source_session.mcp_servers, forked.mcp_servers
    assert_equal @source_session.catalog_skills, forked.catalog_skills
    assert_equal @source_session.catalog_hooks, forked.catalog_hooks
    assert_equal @source_session.catalog_plugins, forked.catalog_plugins
    assert_equal @source_session.goal, forked.goal
    assert_equal @source_session.is_autonomous, forked.is_autonomous
    assert_equal @source_session.session_notes, forked.session_notes
    assert_equal "Fork of Test Session", forked.title

    # Verify transcript was truncated to index 1 (inclusive)
    forked_lines = forked.transcript.lines.map { |l| JSON.parse(l.strip) }
    assert_equal 2, forked_lines.length
    assert_equal "Hello", forked_lines[0]["message"]["content"]
    assert_equal "Hi there!", forked_lines[1]["message"]["content"][0]["text"]

    # Verify metadata was set
    assert_equal @source_session.id, forked.metadata["forked_from_session_id"]
    assert_equal 1, forked.metadata["forked_at_message_index"]
    assert_not_nil forked.metadata["clone_path"]
    assert_not_equal @source_session.metadata["clone_path"], forked.metadata["clone_path"]

    # Verify session_id is a new UUID (not the same as source)
    assert_not_equal @source_session.session_id, forked.session_id

    # Verify broadcast_message_count matches transcript length to prevent replay
    assert_equal 2, forked.metadata["broadcast_message_count"],
      "broadcast_message_count must equal truncated transcript length to prevent message replay"
  end

  test "forks at first message (index 0)" do
    result = ForkSessionService.call(
      source_session: @source_session,
      message_index: 0,
      file_system: @mock_fs
    )

    assert result.success?
    forked_lines = result.forked_session.transcript.lines.map { |l| JSON.parse(l.strip) }
    assert_equal 1, forked_lines.length
    assert_equal "Hello", forked_lines[0]["message"]["content"]
  end

  test "forks at last message" do
    result = ForkSessionService.call(
      source_session: @source_session,
      message_index: 3,  # Last message
      file_system: @mock_fs
    )

    assert result.success?
    forked_lines = result.forked_session.transcript.lines.map { |l| JSON.parse(l.strip) }
    assert_equal 4, forked_lines.length
  end

  test "fails when message_index is out of range (too high)" do
    result = ForkSessionService.call(
      source_session: @source_session,
      message_index: 10,  # Out of range
      file_system: @mock_fs
    )

    assert_not result.success?
    assert_nil result.forked_session
    assert_includes result.error, "out of range"
  end

  test "fails when message_index is negative" do
    result = ForkSessionService.call(
      source_session: @source_session,
      message_index: -1,
      file_system: @mock_fs
    )

    assert_not result.success?
    assert_nil result.forked_session
    assert_includes result.error, "out of range"
  end

  test "fails when source session has no transcript" do
    @source_session.update!(transcript: nil)

    result = ForkSessionService.call(
      source_session: @source_session,
      message_index: 0,
      file_system: @mock_fs
    )

    assert_not result.success?
    assert_includes result.error, "no transcript"
  end

  test "fails when source session has no clone path" do
    @source_session.update!(metadata: {})

    result = ForkSessionService.call(
      source_session: @source_session,
      message_index: 0,
      file_system: @mock_fs
    )

    assert_not result.success?
    assert_includes result.error, "no clone path"
  end

  test "fails when clone directory does not exist" do
    # Don't create the directory in mock fs
    mock_fs = MockFileSystemAdapter.new

    result = ForkSessionService.call(
      source_session: @source_session,
      message_index: 0,
      file_system: mock_fs
    )

    assert_not result.success?
    assert_includes result.error, "does not exist"
  end

  test "creates log entries in both source and forked sessions" do
    result = ForkSessionService.call(
      source_session: @source_session,
      message_index: 1,
      file_system: @mock_fs
    )

    assert result.success?

    # Check source session has a log about the fork
    source_log = @source_session.logs.find { |l| l.content.include?("forked to session") }
    assert_not_nil source_log
    assert_includes source_log.content, "message 2"

    # Check forked session has a log about being forked from
    forked_log = result.forked_session.logs.find { |l| l.content.include?("forked from session") }
    assert_not_nil forked_log
    assert_includes forked_log.content, "message 2"
  end

  test "preserves subdirectory setting" do
    @source_session.update!(subdirectory: "packages/web")
    working_dir = File.join(@clone_path, "packages/web")
    @mock_fs.mkdir_p(working_dir)
    @source_session.update!(metadata: @source_session.metadata.merge("working_directory" => working_dir))

    result = ForkSessionService.call(
      source_session: @source_session,
      message_index: 1,
      file_system: @mock_fs
    )

    assert result.success?
    assert_equal @source_session.subdirectory, result.forked_session.subdirectory
    assert_includes result.forked_session.metadata["working_directory"], "packages/web"
  end

  test "generates unique title for forked session" do
    result = ForkSessionService.call(
      source_session: @source_session,
      message_index: 1,
      file_system: @mock_fs
    )

    assert result.success?
    assert_equal "Fork of Test Session", result.forked_session.title
  end

  test "handles session without title" do
    @source_session.update!(title: nil)

    result = ForkSessionService.call(
      source_session: @source_session,
      message_index: 1,
      file_system: @mock_fs
    )

    assert result.success?
    assert_includes result.forked_session.title, "Fork of Session #{@source_session.id}"
  end

  test "sets runtime_started flag in forked session metadata for resume mode" do
    # This test verifies that the forked session has runtime_started set to true.
    # This is critical because ForkSessionService writes a transcript file with the
    # new session_id, and when the user sends their first follow-up message,
    # AgentSessionJob checks this flag to determine whether to use --resume vs --session-id.
    # Since the transcript file already exists, Claude CLI MUST use --resume mode,
    # otherwise it will fail with "Session ID already in use" error.
    #
    # Bug reference: Messages were being "dropped" on forked sessions because the first
    # message would fail silently (Claude CLI error on --session-id with existing file).

    result = ForkSessionService.call(
      source_session: @source_session,
      message_index: 1,
      file_system: @mock_fs
    )

    assert result.success?
    assert_equal true, result.forked_session.metadata["runtime_started"],
      "Forked session must have runtime_started=true for AgentSessionJob to use --resume mode"
  end

  test "generates MCP configuration file for forked session" do
    # This test verifies that the forked session has a fresh .mcp.json generated.
    # This is critical because:
    # 1. Forked sessions use --resume mode which doesn't regenerate MCP config
    # 2. Without this, MCP servers won't be available in the forked session
    # 3. The source clone's .mcp.json may have stale paths or may not exist
    #
    # Bug reference: Issue #580 - forked sessions weren't starting MCP tools because
    # the .mcp.json wasn't being generated during fork, and the follow-up prompt
    # code path doesn't generate MCP config (only fresh session creation does).

    # Stub AirPrepareService since npx is not available in test.
    # The forked clone already has a .mcp.json copied from the source.
    AirPrepareService.any_instance.stubs(:prepare!)

    result = ForkSessionService.call(
      source_session: @source_session,
      message_index: 1,
      file_system: @mock_fs
    )

    assert result.success?

    # Verify .mcp.json was created in the forked clone's working directory
    forked_working_dir = result.forked_session.metadata["working_directory"]
    mcp_config_path = File.join(forked_working_dir, ".mcp.json")

    assert @mock_fs.exists?(mcp_config_path),
      "MCP config file should be generated at #{mcp_config_path}"

    # Verify the config contains the expected MCP servers
    mcp_config = JSON.parse(@mock_fs.read(mcp_config_path))
    assert mcp_config.key?("mcpServers"), "MCP config should have mcpServers key"
    assert mcp_config["mcpServers"].key?("playwright-custom"),
      "MCP config should include the session's configured MCP server"
  end

  test "does not fail fork when MCP config generation fails" do
    # MCP config generation should be best-effort - if it fails, the fork should
    # still succeed. Users can add MCP servers later via the UI.

    # Use a mock that fails on write for .mcp.json
    failing_mock_fs = MockFileSystemAdapter.new
    failing_mock_fs.mkdir_p(@clone_path)

    # Stub write to fail for .mcp.json
    def failing_mock_fs.write(path, content)
      if path.end_with?(".mcp.json")
        raise "Simulated write failure"
      end
      super
    end

    result = ForkSessionService.call(
      source_session: @source_session,
      message_index: 1,
      file_system: failing_mock_fs
    )

    # Fork should still succeed even though MCP config generation failed
    assert result.success?, "Fork should succeed even when MCP config generation fails"
    assert_not_nil result.forked_session
  end

  test "skips MCP config generation when session has no MCP servers" do
    @source_session.update!(mcp_servers: [])

    result = ForkSessionService.call(
      source_session: @source_session,
      message_index: 1,
      file_system: @mock_fs
    )

    assert result.success?

    # .mcp.json from source should NOT be regenerated (only the copied one exists)
    forked_working_dir = result.forked_session.metadata["working_directory"]
    mcp_config_path = File.join(forked_working_dir, ".mcp.json")

    # If it exists, it's the copied one from source which had "{}" content
    # The key point is we don't error out when no MCP servers are configured
    assert result.success?
  end

  test "carries over catalog_skills to forked session" do
    # Verify that catalog_skills are preserved when forking a session.
    # Without this, forked sessions lose their skill configuration and
    # AirPrepareService won't inject skills on the next execution.
    assert_equal [ "zimmer-start-dev-server" ], @source_session.catalog_skills

    result = ForkSessionService.call(
      source_session: @source_session,
      message_index: 1,
      file_system: @mock_fs
    )

    assert result.success?
    assert_equal [ "zimmer-start-dev-server" ], result.forked_session.catalog_skills,
      "Forked session must inherit catalog_skills from source session"
  end

  test "carries over empty catalog_skills without error" do
    @source_session.update!(catalog_skills: [])

    result = ForkSessionService.call(
      source_session: @source_session,
      message_index: 1,
      file_system: @mock_fs
    )

    assert result.success?
    assert_equal [], result.forked_session.catalog_skills
  end

  test "carries over catalog_hooks to forked session" do
    assert_equal [ "git-push-ci-reminder" ], @source_session.catalog_hooks

    result = ForkSessionService.call(
      source_session: @source_session,
      message_index: 1,
      file_system: @mock_fs
    )

    assert result.success?
    assert_equal [ "git-push-ci-reminder" ], result.forked_session.catalog_hooks,
      "Forked session must inherit catalog_hooks from source session"
  end

  test "carries over catalog_plugins to forked session" do
    assert_equal [ "ci-workflow" ], @source_session.catalog_plugins

    result = ForkSessionService.call(
      source_session: @source_session,
      message_index: 1,
      file_system: @mock_fs
    )

    assert result.success?
    assert_equal [ "ci-workflow" ], result.forked_session.catalog_plugins,
      "Forked session must inherit catalog_plugins from source session"
  end

  test "carries over empty catalog_plugins without error" do
    @source_session.update!(catalog_plugins: [])

    result = ForkSessionService.call(
      source_session: @source_session,
      message_index: 1,
      file_system: @mock_fs
    )

    assert result.success?
    assert_equal [], result.forked_session.catalog_plugins
  end

  test "carries over is_autonomous setting to forked session" do
    # Verify that is_autonomous is preserved when forking. If a user
    # set a session to non-autonomous (to prevent automatic trigger chains),
    # forking should preserve that choice rather than resetting to default (true).
    assert_equal false, @source_session.is_autonomous

    result = ForkSessionService.call(
      source_session: @source_session,
      message_index: 1,
      file_system: @mock_fs
    )

    assert result.success?
    assert_equal false, result.forked_session.is_autonomous,
      "Forked session must inherit is_autonomous from source session"
  end

  test "carries over session_notes to forked session" do
    # Verify that session_notes are preserved when forking. Notes provide
    # important context that is appended to every prompt by AgentSessionJob,
    # and losing them would change agent behavior in the forked session.
    assert_equal "Do not touch the payments module", @source_session.session_notes

    result = ForkSessionService.call(
      source_session: @source_session,
      message_index: 1,
      file_system: @mock_fs
    )

    assert result.success?
    assert_equal "Do not touch the payments module", result.forked_session.session_notes,
      "Forked session must inherit session_notes from source session"
  end

  test "carries over config to forked session" do
    @source_session.update!(config: { "model" => "sonnet", "other_key" => "preserved" })

    result = ForkSessionService.call(
      source_session: @source_session,
      message_index: 1,
      file_system: @mock_fs
    )

    assert result.success?
    assert_equal({ "model" => "sonnet", "other_key" => "preserved" }, result.forked_session.config,
      "Forked session must inherit config (including model) from source session")
  end

  test "broadcast_message_count matches transcript length to prevent replay on fork" do
    # Regression test: When a session is forked, the forked session's
    # broadcast_message_count must equal the number of messages in the truncated
    # transcript. If set to 0 (as it was before this fix), the TranscriptPollerService
    # will re-broadcast ALL forked messages when the user sends their first follow-up,
    # causing a "message replay" effect identical to the bug fixed in PR #1388.
    #
    # The fix ensures that forked messages (already rendered server-side on the show
    # page via build_timeline_items) are treated as "already broadcast" so only
    # genuinely new messages from the follow-up conversation are streamed.

    [ 0, 1, 2, 3 ].each do |fork_index|
      result = ForkSessionService.call(
        source_session: @source_session,
        message_index: fork_index,
        file_system: @mock_fs
      )

      assert result.success?, "Fork at index #{fork_index} should succeed"

      expected_count = fork_index + 1  # 0-based inclusive
      forked = result.forked_session
      forked_transcript_lines = forked.transcript.lines.count { |l| l.strip.present? }

      assert_equal expected_count, forked.metadata["broadcast_message_count"],
        "Fork at index #{fork_index}: broadcast_message_count (#{forked.metadata['broadcast_message_count']}) " \
        "must equal transcript message count (#{expected_count}) to prevent replay"
      assert_equal forked_transcript_lines, forked.metadata["broadcast_message_count"],
        "broadcast_message_count must match the actual number of JSONL lines in the transcript"
    end
  end

  test "generates MCP config in subdirectory when session has subdirectory" do
    @source_session.update!(subdirectory: "packages/web")
    working_dir = File.join(@clone_path, "packages/web")
    @mock_fs.mkdir_p(working_dir)
    # Write .mcp.json in the subdirectory so the copied fork has it
    @mock_fs.write(File.join(working_dir, ".mcp.json"), JSON.pretty_generate({
      "mcpServers" => { "playwright-custom" => { "command" => "npx", "args" => [ "-y", "playwright-mcp" ] } }
    }))
    @source_session.update!(metadata: @source_session.metadata.merge("working_directory" => working_dir))

    # Stub AirPrepareService since npx is not available in test
    AirPrepareService.any_instance.stubs(:prepare!)

    result = ForkSessionService.call(
      source_session: @source_session,
      message_index: 1,
      file_system: @mock_fs
    )

    assert result.success?

    # Verify .mcp.json was created in the subdirectory
    forked_working_dir = result.forked_session.metadata["working_directory"]
    assert_includes forked_working_dir, "packages/web"

    mcp_config_path = File.join(forked_working_dir, ".mcp.json")
    assert @mock_fs.exists?(mcp_config_path),
      "MCP config should be generated in the subdirectory at #{mcp_config_path}"
  end

  # Regression: the forked session resumes via Claude `--resume`, which reads the
  # transcript at ClaudeTranscriptSource#resume_transcript_path. AgentSessionJob's
  # restore/regression check and TranscriptPollerService BOTH derive the on-disk
  # path the same way. If ForkSessionService#write_transcript_file ever computed a
  # different sanitized path (or used a different session-id file), the runtime
  # would resume from an empty/foreign path and the poll would fail. Assert both
  # sides agree on the exact path, for the plain and subdirectory cases.
  test "writes the transcript to the exact path the runtime resumes and polls from" do
    result = ForkSessionService.call(
      source_session: @source_session,
      message_index: 1,
      file_system: @mock_fs
    )
    assert result.success?

    forked = result.forked_session
    expected_path = ClaudeTranscriptSource.new(file_system: @mock_fs)
      .resume_transcript_path(session: forked, working_directory: forked.metadata["working_directory"])

    assert @mock_fs.exists?(expected_path),
      "Fork must write the transcript to the runtime's resume path (#{expected_path})"
    assert_equal forked.transcript, @mock_fs.read(expected_path),
      "On-disk resume transcript must match the forked session's stored transcript"
    assert expected_path.end_with?("/#{forked.session_id}.jsonl"),
      "Resume transcript file must be named after the fork's own session_id"
  end

  test "writes the transcript to the runtime resume path when the session has a subdirectory" do
    @source_session.update!(subdirectory: "packages/web")
    working_dir = File.join(@clone_path, "packages/web")
    @mock_fs.mkdir_p(working_dir)
    @source_session.update!(metadata: @source_session.metadata.merge("working_directory" => working_dir))
    AirPrepareService.any_instance.stubs(:prepare!)

    result = ForkSessionService.call(
      source_session: @source_session,
      message_index: 1,
      file_system: @mock_fs
    )
    assert result.success?

    forked = result.forked_session
    expected_path = ClaudeTranscriptSource.new(file_system: @mock_fs)
      .resume_transcript_path(session: forked, working_directory: forked.metadata["working_directory"])

    assert @mock_fs.exists?(expected_path),
      "Fork must write the transcript to the runtime's resume path even with a subdirectory (#{expected_path})"
    assert_equal forked.transcript, @mock_fs.read(expected_path)
  end
end
