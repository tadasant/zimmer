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

  # A clone directory is "<repo>-<branch>-<timestamp>-<random>" and <repo> can
  # itself contain dashes, so a fork name derived from the source directory's
  # first dash segment turned tadasant-internal-main-… into tadasant-main-…: a
  # directory claiming a repository the fork does not hold. The name comes from
  # the git root now, exactly as GitCloneService derives it.
  test "fork clone directory names the repository the fork actually holds" do
    source_clone = "/home/test/.zimmer/clones/tadasant-internal-main-1786519477-ad273769"
    @mock_fs.mkdir_p(source_clone)
    @source_session.update!(
      git_root: "https://github.com/tadasant/tadasant-internal.git",
      metadata: @source_session.metadata.merge(
        "clone_path" => source_clone, "working_directory" => source_clone
      )
    )

    result = ForkSessionService.call(
      source_session: @source_session,
      message_index: 1,
      file_system: @mock_fs
    )

    assert result.success?, result.error
    forked_dir = File.basename(result.forked_session.metadata["clone_path"])
    assert forked_dir.start_with?("tadasant-internal-main-"),
      "expected the fork to name the repository it actually holds, got #{forked_dir}"
  end

  # And the branch is sanitized the way GitCloneService sanitizes it, so a
  # slash-bearing branch cannot nest the fork below the clones base — where the
  # orphan sweeps, which scan the base's direct children, would never see it.
  test "fork clone directory sanitizes a branch containing a slash" do
    source_clone = "/home/test/.zimmer/clones/repo-claude-fix-x-1786519477-ad273769"
    @mock_fs.mkdir_p(source_clone)
    @source_session.update!(branch: "claude/fix-x", metadata: @source_session.metadata.merge(
      "clone_path" => source_clone, "working_directory" => source_clone
    ))

    result = ForkSessionService.call(
      source_session: @source_session,
      message_index: 1,
      file_system: @mock_fs
    )

    assert result.success?, result.error
    forked_clone = result.forked_session.metadata["clone_path"]
    assert_equal ClonesDirectory.base, File.dirname(forked_clone),
      "the fork must sit directly under the clones base, not nested under a branch directory"
    assert File.basename(forked_clone).start_with?("repo-claude-fix-x-"), File.basename(forked_clone)
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

  # A fork's title is the source's under an 8-character prefix, and Session caps
  # a title at 100 — so a source title over 92 characters composes a fork title
  # the model rejects, and the fork fails deterministically: no retry can produce
  # a shorter title. Titles that long are legal and routine (routers set them via
  # start_session, where "under 70 characters" is guidance, not enforcement).
  test "a source title that fills the budget exactly is carried over whole" do
    base = "a" * 92
    @source_session.update!(title: base)

    result = ForkSessionService.call(source_session: @source_session, message_index: 1, file_system: @mock_fs)

    assert result.success?, result.error
    assert_equal "Fork of #{base}", result.forked_session.title
    assert_equal 100, result.forked_session.title.length
  end

  test "a source title one character past the budget is truncated rather than failing the fork" do
    @source_session.update!(title: "a" * 93)

    result = ForkSessionService.call(source_session: @source_session, message_index: 1, file_system: @mock_fs)

    assert result.success?, result.error
    assert_equal 100, result.forked_session.title.length
    assert result.forked_session.title.end_with?("…"), "the truncation should read as one: #{result.forked_session.title}"
  end

  test "a source title at the cap produces a fork title the model accepts" do
    limit = ForkSessionService.title_length_limit
    base = "Investigate the GlitchTip alert " + ("x" * (limit - "Investigate the GlitchTip alert ".length))
    @source_session.update!(title: base)
    assert_equal limit, @source_session.reload.title.length, "the source title itself must be legal"

    result = ForkSessionService.call(source_session: @source_session, message_index: 1, file_system: @mock_fs)

    assert result.success?, result.error
    forked = result.forked_session
    assert forked.persisted?
    assert forked.valid?, forked.errors.full_messages.to_sentence
    assert_equal limit, forked.title.length
    assert forked.title.start_with?("Fork of Investigate the GlitchTip alert "),
      "a truncated fork title must still read as the session it forked: #{forked.title}"
  end

  # The budget is read off Session's own validator so that raising or lowering
  # the model's cap cannot leave this service composing titles it rejects.
  test "the title budget tracks the Session validator rather than a copy of it" do
    assert_equal 100, ForkSessionService.title_length_limit

    Session.stubs(:validators_on).returns([
      ActiveModel::Validations::LengthValidator.new(attributes: [ :title ], maximum: 40)
    ])
    @source_session.title = "b" * 60

    result = ForkSessionService.call(source_session: @source_session, message_index: 1, file_system: @mock_fs)

    assert result.success?, result.error
    assert_equal 40, result.forked_session.title.length
  end

  test "a model that caps nothing leaves the title untruncated" do
    Session.stubs(:validators_on).returns([])
    @source_session.title = "c" * 60

    assert_nil ForkSessionService.title_length_limit
    result = ForkSessionService.call(source_session: @source_session, message_index: 1, file_system: @mock_fs)

    assert result.success?, result.error
    assert_equal "Fork of #{"c" * 60}", result.forked_session.title
  end

  # A cap with no room for the prefix leaves no budget to truncate against, and
  # the composed title has to be cut instead — the one case where the fork's
  # title stops reading as "Fork of ...".
  test "a cap too small to hold the prefix truncates the composed title" do
    Session.stubs(:validators_on).returns([
      ActiveModel::Validations::LengthValidator.new(attributes: [ :title ], maximum: 6)
    ])
    @source_session.title = "d" * 60

    result = ForkSessionService.call(source_session: @source_session, message_index: 1, file_system: @mock_fs)

    assert result.success?, result.error
    assert_equal 6, result.forked_session.title.length
    assert_equal "Fork …", result.forked_session.title
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
    # Bug reference: forked sessions weren't starting MCP tools because
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

  # A fork copies the source's server list verbatim, and its metadata is built
  # from scratch rather than inherited — so the marker that says the empty list
  # was deliberate has to be carried across explicitly. Without it,
  # McpServerBackfill restores the agent root's defaults on the fork's first job
  # start, handing it the servers the source deliberately declined.
  test "a fork of a session that deliberately has no MCP servers stays empty" do
    @source_session.record_explicit_mcp_servers([])
    @source_session.update!(mcp_servers: [])

    result = ForkSessionService.call(
      source_session: @source_session,
      message_index: 1,
      file_system: @mock_fs
    )

    assert result.success?
    assert_equal [], result.forked_session.mcp_servers
    assert result.forked_session.mcp_servers_explicitly_empty?
  end

  test "a fork of a session with servers carries no deliberate-none marker" do
    result = ForkSessionService.call(
      source_session: @source_session,
      message_index: 1,
      file_system: @mock_fs
    )

    assert result.success?
    assert_equal [ "playwright-custom" ], result.forked_session.mcp_servers
    refute result.forked_session.mcp_servers_explicitly_empty?
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
    # causing a "message replay" effect identical to the bug fixed in PR pulsemcp/agents#1388.
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

  # --- Copying a live working tree ------------------------------------------
  #
  # Regression for the production page of 2026-08-02: the copy walked the source
  # clone for 33 seconds while a concurrently restarted BundleInstallJob rewrote
  # `vendor/bundle` underneath it, hit ENOENT on a gem file that had just been
  # unlinked, failed the fork, alerted, and left 45 MB of half-copied clone on
  # disk that nothing would collect for 48 hours.

  # Records every cp_r the service attempts, and fails the first `failures` of
  # them with `error` — leaving a half-written destination behind first, the way
  # a real recursive copy does when it dies partway through. Later attempts
  # perform the real mock copy.
  def failing_copy_adapter(adapter, failures:, error: Errno::ENOENT.new("/src/vendor/bundle/ruby/3.4.0/gems/activemodel-8.1.3/lib/active_model/railtie.rb"))
    attempts = []
    adapter.define_singleton_method(:copy_attempts) { attempts }
    adapter.define_singleton_method(:cp_r) do |src, dest, exclude: []|
      attempts << dest
      if attempts.size <= failures
        mkdir_p(dest)
        write(File.join(dest, "Gemfile.lock"), "partially copied")
        raise error
      end

      super(src, dest, exclude: exclude)
    end
    adapter
  end

  def assert_no_partial_clones(fs)
    fs.copy_attempts.uniq.each do |path|
      assert_not fs.directory?(path), "a failed fork must not strand a partial clone at #{path}"
      assert_not fs.exists?(File.join(path, "Gemfile.lock")), "a failed fork must not strand partially copied files under #{path}"
    end
  end

  # By the time record creation runs, the clone has been copied in full. If the
  # record does not save, nothing claims that copy — and
  # OrphanCloneFilesystemCleanupJob ignores anything younger than 48h, so a whole
  # working tree sits on disk for two days per failed fork.
  # The caller disposes of the clone when record creation answers nil, so nil
  # has to mean no record exists. A log insert that fails after the session row
  # was written would otherwise leave a live session whose metadata names a
  # clone the caller then deletes.
  test "a record creation that fails partway writes no session at all" do
    fs = failing_copy_adapter(@mock_fs, failures: 0)
    Log.any_instance.stubs(:save!).raises(ActiveRecord::RecordInvalid.new(Log.new))

    assert_no_difference -> { Session.count } do
      result = ForkSessionService.call(
        source_session: @source_session,
        message_index: 1,
        file_system: fs
      )

      assert_not result.success?
      assert_equal "Failed to create forked session record", result.error
    end

    assert_no_partial_clones(fs)
  end

  test "a fork whose record cannot be created leaves no clone behind" do
    fs = failing_copy_adapter(@mock_fs, failures: 0)
    ForkSessionService.any_instance.stubs(:create_forked_session).returns(nil)

    result = ForkSessionService.call(
      source_session: @source_session,
      message_index: 1,
      file_system: fs
    )

    assert_not result.success?
    assert_equal "Failed to create forked session record", result.error
    assert_equal 1, fs.copy_attempts.size, "the copy should have completed before record creation"
    assert_no_partial_clones(fs)
  end

  test "a source file vanishing mid-copy is retried and the fork succeeds" do
    ForkSessionService.any_instance.stubs(:sleep)
    fs = failing_copy_adapter(@mock_fs, failures: 1)

    result = ForkSessionService.call(
      source_session: @source_session,
      message_index: 1,
      file_system: fs
    )

    assert result.success?, "a file disappearing from a live tree is transient, not a fork failure: #{result.error}"
    assert_equal 2, fs.copy_attempts.size, "the copy should be retried once and then succeed"
    assert_equal result.forked_session.metadata["clone_path"], fs.copy_attempts.last
  end

  test "the partial destination is removed before each retry" do
    ForkSessionService.any_instance.stubs(:sleep)
    fs = failing_copy_adapter(@mock_fs, failures: 1)

    # The destination is cleared by AtomicCloneRemoval (#412), which renames it
    # aside before deleting it — so the path the retry needs empty is emptied in
    # one atomic step rather than unlinked out from under itself.
    renamed = []
    fs.define_singleton_method(:rename) do |src, dest|
      renamed << src
      super(src, dest)
    end

    result = ForkSessionService.call(source_session: @source_session, message_index: 1, file_system: fs)

    assert result.success?
    assert_includes renamed, fs.copy_attempts.first,
      "a half-written destination must be cleared, not merged into by the next attempt"
    # The effect, not just the call: the failing attempt wrote Gemfile.lock into
    # the destination, and the fork that succeeded must not have inherited it.
    assert_not fs.exists?(File.join(result.forked_session.metadata["clone_path"], "Gemfile.lock")),
      "the successful attempt must start from an empty destination"
  end

  # A cleanup reports nothing when it fails to clear the destination, and cp_r
  # given a destination that already exists copies INTO it — so a retry over a
  # surviving partial tree would produce a nested clone instead of a failure. The
  # rename-aside cleanup makes this much harder to reach (the path is cleared in
  # one step), which is why the adapter here has to defeat both halves of it.
  test "a destination that survives the cleanup fails the fork instead of being retried into" do
    ForkSessionService.any_instance.stubs(:sleep)
    fs = failing_copy_adapter(@mock_fs, failures: 1)
    fs.define_singleton_method(:rename) { |_src, _dest| nil } # a cleanup that silently moves nothing
    fs.define_singleton_method(:rm_rf) { |_path| nil } # ...and silently removes nothing

    result = ForkSessionService.call(source_session: @source_session, message_index: 1, file_system: fs)

    assert_not result.success?
    assert_equal 1, fs.copy_attempts.size, "no attempt may run against a destination that still exists"
  end

  test "an exhausted retry budget fails the fork and leaves no partial clone behind" do
    ForkSessionService.any_instance.stubs(:sleep)
    fs = failing_copy_adapter(@mock_fs, failures: 99)

    result = ForkSessionService.call(
      source_session: @source_session,
      message_index: 1,
      file_system: fs
    )

    assert_not result.success?
    assert_includes result.error, "Failed to create forked clone directory"
    assert_equal ForkSessionService::COPY_RETRY_DELAYS.length + 1, fs.copy_attempts.size,
      "the retry budget is the delay ladder plus the first attempt"
    assert_no_partial_clones(fs)
  end

  test "a non-transient copy error fails immediately without burning retries" do
    ForkSessionService.any_instance.stubs(:sleep)
    fs = failing_copy_adapter(@mock_fs, failures: 99, error: Errno::EACCES.new("/home/rails/.zimmer/clones"))

    result = ForkSessionService.call(
      source_session: @source_session,
      message_index: 1,
      file_system: fs
    )

    assert_not result.success?
    assert_equal 1, fs.copy_attempts.size, "EACCES will not fix itself — no point retrying it"
    assert_no_partial_clones(fs)
  end

  # A copy that dies the way DeferredCloneCleanupJob kills one: the source tree is
  # unlinked out from under the walk, so the ENOENT names a path inside a clone
  # that no longer exists. No later attempt can find what it deleted.
  def clone_deleting_copy_adapter(adapter, source_clone_path)
    attempts = []
    adapter.define_singleton_method(:copy_attempts) { attempts }
    adapter.define_singleton_method(:cp_r) do |src, dest, exclude: []|
      attempts << dest
      rm_rf(source_clone_path)
      raise Errno::ENOENT.new(File.join(src, ".git/objects/e8"))
    end
    adapter
  end

  # The severity is what pages, so it is what the assertions read — a message body
  # is free to contain the word "ERROR" at any level.
  def fork_service_errors(entries)
    entries.select { |severity, message| severity == "ERROR" && message.include?("service=ForkSessionService") }
  end

  # --- The archive pipeline deleting the clone mid-copy ----------------------
  #
  # Regression for the production page of 2026-08-12: a status-summary fork of
  # session 3762 started as the session self-archived, and DeferredCloneCleanupJob
  # deleted the clone 41 seconds into the copy. The copy died on `.git/objects/e8`
  # and logged `.error`, which paged a human about a fork that was moot the moment
  # the session reached the trash. The retry ladder cannot reach this — a deleted
  # file never comes back — so the classification has to change, not the budget.

  test "a source clone the trash deleted mid-copy fails quietly instead of paging" do
    ForkSessionService.any_instance.stubs(:sleep)
    @source_session.update_column(:status, Session.statuses[:archived])
    fs = clone_deleting_copy_adapter(@mock_fs, @clone_path)

    result = nil
    entries = capture_log_entries do
      result = ForkSessionService.call(source_session: @source_session, message_index: 1, file_system: fs)
    end

    assert_not result.success?
    assert result.source_clone_discarded,
      "the caller has to be able to tell this apart from a fork that genuinely could not be made"
    assert_empty fork_service_errors(entries),
      "an archived session's clone being deleted under the copy is expected, not a fault to page on"
    assert_equal 1, fs.copy_attempts.size
    assert_no_partial_clones(fs)
  end

  # The guard against over-quieting. A clone that vanishes while the session is
  # live is a genuine fault — a stray rm, a volume gone, a cleanup that ran
  # against the wrong path — and it has to keep paging.
  test "a source clone that vanishes while the session is live is not retried and still pages" do
    ForkSessionService.any_instance.stubs(:sleep)
    fs = clone_deleting_copy_adapter(@mock_fs, @clone_path)

    result = nil
    entries = capture_log_entries do
      result = ForkSessionService.call(source_session: @source_session, message_index: 1, file_system: fs)
    end

    assert_not result.success?
    assert_not result.source_clone_discarded, "only the trash deleting a clone is benign"
    assert_equal 1, fs.copy_attempts.size, "retrying a copy of a clone that no longer exists cannot succeed"
    errors = fork_service_errors(entries)
    assert_equal 1, errors.size, "an ENOENT on a clone that should still be there is still an error"
    assert_includes errors.first.last, "Failed to create forked clone"
  end

  # The window the production failure actually happened in. `rm_rf` unlinks
  # children bottom-up and removes the root LAST, so for the whole of a large
  # clone's deletion the root is still a directory while the copy is already
  # failing on paths inside it. A classification that asked whether the clone root
  # was gone would answer "still there", call this a genuine fault, and page —
  # which is why it asks the session's status instead.
  test "a clone still mid-deletion, root and all, is classified by the session rather than the tree" do
    ForkSessionService.any_instance.stubs(:sleep)
    @source_session.update_column(:status, Session.statuses[:archived])

    source = @clone_path
    fs = @mock_fs
    attempts = []
    fs.define_singleton_method(:copy_attempts) { attempts }
    fs.define_singleton_method(:cp_r) do |src, dest, exclude: []|
      attempts << dest
      # The cleanup is partway through: a child is gone, the root is not.
      raise Errno::ENOENT.new(File.join(src, ".git/objects/e8"))
    end

    result = nil
    entries = capture_log_entries do
      result = ForkSessionService.call(source_session: @source_session, message_index: 1, file_system: fs)
    end

    assert_not result.success?
    assert fs.directory?(@clone_path), "the premise: the clone root outlives the children being unlinked"
    assert result.source_clone_discarded
    assert_empty fork_service_errors(entries),
      "the root still being there does not make an archived session's disappearing clone a fault"
    assert_equal ForkSessionService::COPY_RETRY_DELAYS.length + 1, fs.copy_attempts.size,
      "a root that is still there still looks retryable, so the budget is spent — it just must not page"
  end

  # The same race, lost before the copy even started: the cleanup finished first,
  # so the clone is already gone at validation. Same benign outcome, same answer.
  test "an archived session whose clone is already gone reports a discarded source clone" do
    @source_session.update_column(:status, Session.statuses[:archived])
    @mock_fs.rm_rf(@clone_path)

    result = ForkSessionService.call(source_session: @source_session, message_index: 1, file_system: @mock_fs)

    assert_not result.success?
    assert_equal "Source clone directory does not exist", result.error
    assert result.source_clone_discarded
  end

  test "a live session whose clone is already gone does not report a discarded source clone" do
    @mock_fs.rm_rf(@clone_path)

    result = ForkSessionService.call(source_session: @source_session, message_index: 1, file_system: @mock_fs)

    assert_not result.success?
    assert_equal "Source clone directory does not exist", result.error
    assert_not result.source_clone_discarded
  end

  test "copy_exclusions keep installed-dependency trees out of the forked clone" do
    @mock_fs.write(File.join(@clone_path, "Gemfile"), "source 'https://rubygems.org'")
    @mock_fs.write(File.join(@clone_path, "vendor/bundle/ruby/3.4.0/gems/activemodel-8.1.3/lib/active_model/railtie.rb"), "gem")
    @mock_fs.write(File.join(@clone_path, "docs/node_modules/astro/package.json"), "{}")
    @mock_fs.write(File.join(@clone_path, "vendor/javascript/stimulus.js"), "js")

    result = ForkSessionService.call(
      source_session: @source_session,
      message_index: 1,
      file_system: @mock_fs,
      copy_exclusions: ForkSessionService::DEPENDENCY_DIRECTORIES
    )

    assert result.success?
    new_clone = result.forked_session.metadata["clone_path"]

    assert @mock_fs.exists?(File.join(new_clone, "Gemfile"))
    assert @mock_fs.exists?(File.join(new_clone, "vendor/javascript/stimulus.js")),
      "only the install trees are excluded, not everything under vendor/"
    assert_not @mock_fs.exists?(File.join(new_clone, "vendor/bundle/ruby/3.4.0/gems/activemodel-8.1.3/lib/active_model/railtie.rb"))
    assert_not @mock_fs.exists?(File.join(new_clone, "docs/node_modules/astro/package.json"))
  end

  test "a fork copies the whole tree by default" do
    @mock_fs.write(File.join(@clone_path, "vendor/bundle/ruby/3.4.0/gems/rails-8.1.3/README.md"), "gem")

    result = ForkSessionService.call(
      source_session: @source_session,
      message_index: 1,
      file_system: @mock_fs
    )

    assert result.success?
    assert @mock_fs.exists?(File.join(result.forked_session.metadata["clone_path"], "vendor/bundle/ruby/3.4.0/gems/rails-8.1.3/README.md")),
      "a user-initiated fork is a working session and keeps its installed dependencies"
  end

  # --- Scaffolding a clone that is no longer there ---------------------------

  # For a caller whose fork never reads the tree — SessionStatusSummaryGenerator's
  # summarizer answers from the conversation and is told not to run tools. The
  # session's clone is reclaimed about ten seconds after it is archived, so
  # without this every fork of an archived session fails on a missing directory.
  test "a missing source clone is scaffolded when the caller allows it" do
    @source_session.update_column(:status, Session.statuses[:archived])
    @mock_fs.rm_rf(@clone_path)

    result = ForkSessionService.call(
      source_session: @source_session,
      message_index: 1,
      file_system: @mock_fs,
      scaffold_missing_clone: true
    )

    assert result.success?
    fork = result.forked_session
    assert_equal true, fork.metadata["clone_scaffolded"]
    assert @mock_fs.directory?(fork.metadata["clone_path"]), "the fork gets a directory to be spawned in"
    assert_equal fork.metadata["clone_path"], fork.metadata["working_directory"]
    assert_not result.source_clone_discarded, "a scaffolded clone is not a discarded one"
  end

  test "a scaffolded clone creates the subdirectory the working directory points into" do
    @source_session.update!(subdirectory: "docs")
    @mock_fs.rm_rf(@clone_path)

    result = ForkSessionService.call(
      source_session: @source_session,
      message_index: 1,
      file_system: @mock_fs,
      scaffold_missing_clone: true
    )

    assert result.success?
    working_directory = result.forked_session.metadata["working_directory"]
    assert_equal File.join(result.forked_session.metadata["clone_path"], "docs"), working_directory
    assert @mock_fs.directory?(working_directory)
  end

  # The same case one race later: the tree was there at validation and
  # DeferredCloneCleanupJob unlinked it during the copy. A caller that does not
  # need the tree still does not need it, so this costs the copy, not the fork.
  test "a source clone deleted mid-copy is scaffolded rather than failed when allowed" do
    @source_session.update_column(:status, Session.statuses[:archived])
    clone = @clone_path
    @mock_fs.define_singleton_method(:cp_r) do |_src, _dest, exclude: []|
      rm_rf(clone)
      raise Errno::ENOENT.new(File.join(clone, ".git/objects/e8"))
    end

    result = ForkSessionService.call(
      source_session: @source_session,
      message_index: 1,
      file_system: @mock_fs,
      scaffold_missing_clone: true
    )

    assert result.success?
    assert_equal true, result.forked_session.metadata["clone_scaffolded"]
  end

  # The guard against over-scaffolding, and the mirror of "a source clone that
  # vanishes while the session is live is not retried and still pages". An
  # exhausted retry budget on a LIVE tree — its own agent churning `vendor/bundle`
  # under the copy — raises the same shape of ENOENT as a tree being deleted. That
  # is a genuine copy failure, and scaffolding over it would swallow the alert.
  test "an exhausted retry budget on a live source clone fails rather than scaffolding" do
    clone = @clone_path
    @mock_fs.define_singleton_method(:cp_r) do |_src, _dest, exclude: []|
      raise Errno::ENOENT.new(File.join(clone, "vendor/bundle/ruby/3.4.0/gems/rails-8.1.3/README.md"))
    end

    result = ForkSessionService.call(
      source_session: @source_session,
      message_index: 1,
      file_system: @mock_fs,
      scaffold_missing_clone: true
    )

    assert_not result.success?
    assert_equal "Failed to create forked clone directory", result.error
    assert_not result.source_clone_discarded
  end

  # Scaffolding is opt-in, and it does not swallow a fault that has nothing to do
  # with the source tree. An ENOENT from anywhere else still fails the fork.
  test "scaffolding does not rescue an ENOENT that is not the source clone" do
    @mock_fs.define_singleton_method(:cp_r) do |_src, _dest, exclude: []|
      raise Errno::ENOENT.new("/home/test/.zimmer/clones")
    end

    result = ForkSessionService.call(
      source_session: @source_session,
      message_index: 1,
      file_system: @mock_fs,
      scaffold_missing_clone: true
    )

    assert_not result.success?
    assert_equal "Failed to create forked clone directory", result.error
  end

  # A live tree is still copied. Scaffolding is the answer to a clone that is
  # gone, not a cheaper fork.
  test "an available source clone is copied even when scaffolding is allowed" do
    @mock_fs.write(File.join(@clone_path, "README.md"), "hello")

    result = ForkSessionService.call(
      source_session: @source_session,
      message_index: 1,
      file_system: @mock_fs,
      scaffold_missing_clone: true
    )

    assert result.success?
    fork = result.forked_session
    assert_nil fork.metadata["clone_scaffolded"]
    assert @mock_fs.exists?(File.join(fork.metadata["clone_path"], "README.md"))
  end
end
