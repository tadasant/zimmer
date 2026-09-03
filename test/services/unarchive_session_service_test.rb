# frozen_string_literal: true

require "test_helper"
require "minitest/mock"
require "mocha/minitest"
require "open3"
require "tmpdir"

class UnarchiveSessionServiceTest < ActiveSupport::TestCase
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
    @working_directory = @clone_path

    # Create an archived session
    @session = Session.create!(
      prompt: "Test prompt",
      agent_runtime: "claude_code",
      status: :archived,
      archived_at: 1.hour.ago,
      git_root: "https://github.com/test/repo.git",
      branch: "main",
      execution_provider: "local_filesystem",
      session_id: SecureRandom.uuid,
      transcript: @transcript_content,
      mcp_servers: [ "context7" ],
      goal: "Complete the task",
      title: "Test Session",
      metadata: {
        "clone_path" => @clone_path,
        "working_directory" => @working_directory
      }
    )

    # Stub AirPrepareService globally since npx/air-cli is not available in test
    AirPrepareService.any_instance.stubs(:prepare!)
  end

  # zimmer#808: an unarchive is `archived` for its whole duration — the status
  # transition is the last step, after the clone, the artifact replay and
  # `air prepare` — so for that window the row is indistinguishable from an
  # abandoned archive with a stale clone, and the hourly reapers delete the clone
  # this service is in the middle of building.
  test "marks the session reap-protected for the duration of the unarchive" do
    @mock_fs.mkdir_p(@clone_path)

    # Sampled from inside the run, at the transcript write — a real step that
    # happens before the status transition.
    protected_during_run = nil
    session_id = @session.id
    @mock_fs.define_singleton_method(:write) do |path, content, **options|
      protected_during_run = Session.reap_protected?(session_id)
      super(path, content, **options)
    end

    result = UnarchiveSessionService.call(session: @session, file_system: @mock_fs)

    assert result.success?
    assert protected_during_run, "the session must be reap-protected while the unarchive runs"
    assert_nil @session.reload.metadata[Session::UNARCHIVE_IN_FLIGHT_KEY],
               "the marker must be dropped once the unarchive is over"
  end

  test "drops the reap-protection marker even when the unarchive fails" do
    # No clone on disk and a clone that cannot be recreated: the slow path fails.
    GitCloneService.stub :create_clone, ->(*, **) { raise GitCloneService::GitError, "no remote" } do
      result = UnarchiveSessionService.call(session: @session, file_system: @mock_fs)

      assert_not result.success?
    end

    assert_nil @session.reload.metadata[Session::UNARCHIVE_IN_FLIGHT_KEY],
               "a failed unarchive must not pin the session's clone on disk"
  end

  test "quick unarchive when clone still exists" do
    # Clone still exists
    @mock_fs.mkdir_p(@clone_path)

    result = UnarchiveSessionService.call(
      session: @session,
      file_system: @mock_fs
    )

    assert result.success?
    assert_equal false, result.clone_restored
    assert_equal @session, result.session
    assert_nil result.error

    # Verify session state changed
    @session.reload
    assert_equal "needs_input", @session.status
    assert_nil @session.archived_at

    # Verify transcript file was written to Claude projects directory
    home_dir = File.expand_path("~")
    sanitized_path = PathSanitizer.sanitize(@working_directory)
    transcript_path = File.join(home_dir, ".claude", "projects", sanitized_path, "#{@session.session_id}.jsonl")
    assert @mock_fs.exists?(transcript_path), "Transcript file should be written"
    assert_equal @transcript_content, @mock_fs.read(transcript_path)
  end

  test "full unarchive when clone was deleted recreates clone" do
    # Clone does NOT exist (deleted during archive)
    # Mock GitCloneService to return success
    new_clone_path = "/home/test/.zimmer/clones/test-repo-main-99999-efgh"

    mock_create_clone = lambda do |_git_root, **_kwargs|
      { clone_path: new_clone_path, working_directory: new_clone_path }
    end

    GitCloneService.stub :create_clone, mock_create_clone do
      @mock_fs.mkdir_p(new_clone_path)

      result = UnarchiveSessionService.call(
        session: @session,
        file_system: @mock_fs
      )

      assert result.success?
      assert_equal true, result.clone_restored
      assert_nil result.error

      # Verify session state changed
      @session.reload
      assert_equal "needs_input", @session.status
      assert_nil @session.archived_at

      # Verify metadata was updated with new clone path
      assert_equal new_clone_path, @session.metadata["clone_path"]
      assert_equal new_clone_path, @session.metadata["working_directory"]
      assert_equal true, @session.metadata["clone_recreated"]
      assert_not_nil @session.metadata["unarchived_at"]

      # Old process state should be cleared
      assert_nil @session.metadata["process_pid"]
      assert_nil @session.metadata["failure_reason"]
    end
  end

  # NOTE: the pre-#4600 "fails when session is not archived" test (status: running,
  # archived_at: nil → "Session is not in trash" failure) was removed. Every service
  # caller (both controllers + Trigger#resuscitate_session!) gates on archived?
  # before invoking, so the service only ever observes a non-archived, archived_at
  # cleared session via a concurrent-unarchive race — which is now an idempotent
  # success (see the "call returns idempotent success on entry ..." tests below).
  # Controller-level "not in trash" behavior is covered in sessions_controller_test.
  # The remaining service-level failure path (abnormal archived_at-still-populated
  # row) is covered by "call does not short-circuit on entry when archived_at is
  # still populated".

  test "fails when session has no git_root" do
    @session.update!(status: :archived)
    @session.update_column(:git_root, nil)

    result = UnarchiveSessionService.call(
      session: @session,
      file_system: @mock_fs
    )

    assert_not result.success?
    assert_equal "Session has no git_root", result.error
  end

  # The inverse guard for zimmer#557. This session HAS work — a transcript with
  # no id is what a fresh-start recovery leaves behind on a runtime that mints
  # its own conversation id — so it is not never-run, the service still cannot
  # restore it, and that failure must stay loud rather than being rerouted into
  # a fresh start that would discard the conversation.
  test "fails when session has a transcript but no session_id" do
    @session.update!(session_id: nil)
    assert @session.transcript.present?

    result = UnarchiveSessionService.call(
      session: @session,
      file_system: @mock_fs
    )

    assert_not result.success?
    assert_equal "Session has no session_id", result.error
    assert @session.reload.archived?, "a loud failure must leave the session in trash"
  end

  # zimmer#557: a session created but never started — no session_id, no
  # transcript, no clone — could not be restored at all. The Restore button and
  # the MCP "unarchive" action both failed with "Session has no session_id",
  # which made archiving a never-started session irreversible for exactly the
  # class of session where starting over is cheapest and most obviously right.
  test "restores a session that never ran instead of refusing it" do
    never_ran = never_ran_session

    result = UnarchiveSessionService.call(session: never_ran, file_system: @mock_fs)

    assert result.success?, "expected a never-started session to restore, got: #{result.error}"
    assert_not result.clone_restored, "there is no clone to restore for a session that never ran"

    never_ran.reload
    assert_equal "needs_input", never_ran.status
    assert_nil never_ran.archived_at
    assert_equal "Investigate the flaky test", never_ran.prompt, "the original configuration is what it starts from"
  end

  # Cloning here would build a clone the fresh start does not use and the reapers
  # would have to sweep. The setup pipeline clones when the session is next
  # started, so this path must not.
  test "does not clone or write a transcript when restoring a session that never ran" do
    never_ran = never_ran_session
    clone_attempted = false

    refuse_clone = lambda do |_git_root, **_kwargs|
      clone_attempted = true
      { error: "GitCloneService must not be called for a session that never ran" }
    end

    GitCloneService.stub :create_clone, refuse_clone do
      result = UnarchiveSessionService.call(session: never_ran, file_system: @mock_fs)
      assert result.success?, "expected a never-started session to restore, got: #{result.error}"
    end

    assert_not clone_attempted, "a session that never ran has no conversation to clone a workspace for"
    assert_empty @mock_fs.files, "nothing should be written to disk for a session that never ran"
  end

  # The half-written artifacts of an aborted spawn are worse than none: the fresh
  # start would trust a clone_path that was never finished and has almost
  # certainly been reaped since.
  test "clears the setup artifacts of a session that never ran" do
    never_ran = never_ran_session
    never_ran.update!(metadata: never_ran.metadata.merge(
      "clone_path" => "/home/test/.zimmer/clones/half-written",
      "working_directory" => "/home/test/.zimmer/clones/half-written",
      "process_pid" => 4242,
      "runtime_started" => true
    ))

    result = UnarchiveSessionService.call(session: never_ran, file_system: @mock_fs)
    assert result.success?, "expected a never-started session to restore, got: #{result.error}"

    never_ran.reload
    Session::SETUP_ARTIFACT_KEYS.each do |key|
      assert_nil never_ran.metadata[key], "#{key} must not survive the restore of a never-started session"
    end
  end

  # zimmer#808's reap-protection stamp must survive the never-ran path too. The
  # setup artifacts are cleared inside transition_to_needs_input's locked write
  # rather than by a second write of our own, so the clearing is atomic with
  # leaving `archived` — and it must not take the in-flight marker with it, nor
  # leave it behind once the restore is over.
  test "keeps the unarchive-in-flight marker intact through a never-ran restore" do
    never_ran = never_ran_session
    never_ran.update!(metadata: never_ran.metadata.merge("clone_path" => "/home/test/.zimmer/clones/half-written"))

    # Sampled from inside the run, at the status transition — the only step this
    # path takes, and the same write that clears the setup artifacts. If that
    # write dropped the marker along with them, this would read false.
    protected_during_run = nil
    session_id = never_ran.id
    never_ran.define_singleton_method(:unarchive_to_needs_input!) do |*args|
      protected_during_run = Session.reap_protected?(session_id)
      super(*args)
    end

    result = UnarchiveSessionService.call(session: never_ran, file_system: @mock_fs)
    assert result.success?, "expected a never-started session to restore, got: #{result.error}"

    assert protected_during_run, "the session must stay reap-protected while the restore runs"

    never_ran.reload
    assert_nil never_ran.metadata[Session::UNARCHIVE_IN_FLIGHT_KEY],
      "the marker must be dropped once the restore is over"
    assert_nil never_ran.metadata["clone_path"],
      "and the setup artifacts must be gone with it"
  end

  # "Restored with full state restoration" is a lie for a session that had no
  # state. The timeline a human reads has to say what actually happened.
  test "says the session never started in the log it leaves behind" do
    never_ran = never_ran_session

    result = UnarchiveSessionService.call(session: never_ran, file_system: @mock_fs)
    assert result.success?, "expected a never-started session to restore, got: #{result.error}"

    contents = never_ran.reload.logs.map(&:content)
    assert contents.any? { |c| c.include?("never started") },
      "expected the restore log to say the session never started, got: #{contents.inspect}"
    assert_not contents.any? { |c| c.include?("full state restoration") },
      "a session with no state must not be described as fully restored"
  end

  # Reproduces sessions 5936, 5988 and 6136: created by a trigger, held by the
  # spot gate, paused into needs_input by recovery with an empty transcript, then
  # archived.
  def never_ran_session
    Session.create!(
      prompt: "Investigate the flaky test",
      agent_runtime: "claude_code",
      status: :archived,
      archived_at: 1.hour.ago,
      git_root: "https://github.com/test/repo.git",
      branch: "main",
      execution_provider: "local_filesystem",
      session_id: nil,
      transcript: nil,
      metadata: { "paused_by" => "recovery" }
    )
  end

  test "fails when clone recreation fails" do
    # Clone does NOT exist and GitCloneService fails
    mock_create_clone = lambda { |_git_root, **_kwargs| { error: "Repository not found" } }

    GitCloneService.stub :create_clone, mock_create_clone do
      result = UnarchiveSessionService.call(
        session: @session,
        file_system: @mock_fs
      )

      assert_not result.success?
      assert_includes result.error, "Repository not found"
    end
  end

  test "preserves session_id for Claude Code resumption" do
    @mock_fs.mkdir_p(@clone_path)
    original_session_id = @session.session_id

    result = UnarchiveSessionService.call(
      session: @session,
      file_system: @mock_fs
    )

    assert result.success?

    # session_id must be preserved so Claude Code can resume the conversation
    @session.reload
    assert_equal original_session_id, @session.session_id
  end

  test "creates log entry on successful unarchive" do
    @mock_fs.mkdir_p(@clone_path)

    result = UnarchiveSessionService.call(
      session: @session,
      file_system: @mock_fs
    )

    assert result.success?

    # Check for log entry
    unarchive_log = @session.logs.find { |l| l.content.include?("unarchived with full state restoration") }
    assert_not_nil unarchive_log
    assert_equal "info", unarchive_log.level
  end

  test "handles session with subdirectory" do
    subdirectory = "packages/web"
    full_working_directory = File.join(@clone_path, subdirectory)
    @session.update!(
      subdirectory: subdirectory,
      metadata: {
        "clone_path" => @clone_path,
        "working_directory" => full_working_directory
      }
    )

    @mock_fs.mkdir_p(@clone_path)
    @mock_fs.mkdir_p(full_working_directory)

    result = UnarchiveSessionService.call(
      session: @session,
      file_system: @mock_fs
    )

    assert result.success?

    # Verify transcript was written to the correct location (using working_directory path)
    home_dir = File.expand_path("~")
    sanitized_path = PathSanitizer.sanitize(full_working_directory)
    transcript_path = File.join(home_dir, ".claude", "projects", sanitized_path, "#{@session.session_id}.jsonl")
    assert @mock_fs.exists?(transcript_path), "Transcript file should be written at working_directory path"
  end

  test "handles session without transcript" do
    @session.update!(transcript: nil)
    @mock_fs.mkdir_p(@clone_path)

    result = UnarchiveSessionService.call(
      session: @session,
      file_system: @mock_fs
    )

    # Should still succeed - transcript is optional
    assert result.success?
    @session.reload
    assert_equal "needs_input", @session.status
  end

  test "calls regenerate_mcp_config when session has MCP servers" do
    @mock_fs.mkdir_p(@clone_path)

    # AirPrepareService is stubbed globally in setup
    result = UnarchiveSessionService.call(
      session: @session,
      file_system: @mock_fs
    )

    assert result.success?
    assert @session.mcp_servers.present?
  end

  test "handles session without MCP servers" do
    @session.update!(mcp_servers: nil)
    @mock_fs.mkdir_p(@clone_path)

    result = UnarchiveSessionService.call(
      session: @session,
      file_system: @mock_fs
    )

    assert result.success?
    # No MCP config should be written (and no error should occur)
  end

  test "syncs custom_metadata.injected_mcp_servers with what AIR injected during unarchive" do
    # Regression: previously the unarchive flow ran AIR but never persisted
    # AirPrepareService#injected_mcp_servers into custom_metadata, leaving the
    # UI's view of injected servers stale (carrying values from the original
    # run that no longer matched the regenerated .mcp.json).
    @session.update!(
      custom_metadata: { "injected_mcp_servers" => [ "stale-server-from-prior-run" ] }
    )
    @mock_fs.mkdir_p(@clone_path)

    # Simulate AIR having injected a fresh self-session server during prepare!.
    # prepare! is already stubbed in setup; stub the attr_reader to return the
    # injected list so UnarchiveSessionService#regenerate_mcp_config persists it.
    AirPrepareService.any_instance.stubs(:injected_mcp_servers)
      .returns([ "zimmer-self-session" ])

    result = UnarchiveSessionService.call(
      session: @session,
      file_system: @mock_fs
    )

    assert result.success?

    @session.reload
    assert_equal [ "zimmer-self-session" ],
      @session.custom_metadata["injected_mcp_servers"],
      "custom_metadata.injected_mcp_servers must reflect what AIR actually injected during unarchive, " \
      "not what was set during the original session run"
  end

  test "overwrites stale injected_mcp_servers even when AIR injects nothing" do
    # If the regenerated .mcp.json no longer needs auto-injected servers
    # (e.g. session.mcp_servers now contains a Zimmer server with TOOL_GROUPS
    # blank), the unarchive must clear the stale list rather than leave it.
    @session.update!(
      custom_metadata: { "injected_mcp_servers" => [ "stale-self-session-from-prior-run" ] }
    )
    @mock_fs.mkdir_p(@clone_path)

    AirPrepareService.any_instance.stubs(:injected_mcp_servers).returns([])

    result = UnarchiveSessionService.call(
      session: @session,
      file_system: @mock_fs
    )

    assert result.success?

    @session.reload
    assert_equal [], @session.custom_metadata["injected_mcp_servers"],
      "custom_metadata.injected_mcp_servers must be cleared when AIR no longer needs to inject anything"
  end

  test "syncs injected_mcp_servers when ensure_baseline_mcp_config! runs" do
    # When session has no mcp_servers/skills/hooks/plugins, the unarchive flow
    # falls through to ensure_baseline_mcp_config! instead of prepare!. The
    # injected list must still be synced.
    @session.update!(
      mcp_servers: nil,
      catalog_skills: nil,
      catalog_hooks: nil,
      catalog_plugins: nil,
      custom_metadata: { "injected_mcp_servers" => [ "stale-server" ] }
    )
    @mock_fs.mkdir_p(@clone_path)

    AirPrepareService.any_instance.stubs(:ensure_baseline_mcp_config!)
    AirPrepareService.any_instance.stubs(:injected_mcp_servers)
      .returns([ "zimmer-self-session" ])

    result = UnarchiveSessionService.call(
      session: @session,
      file_system: @mock_fs
    )

    assert result.success?

    @session.reload
    assert_equal [ "zimmer-self-session" ],
      @session.custom_metadata["injected_mcp_servers"]
  end

  test "backfills empty mcp_servers from agent root default_in_roots on unarchive" do
    # Regression: a root whose MCP servers come from `default_in_roots`
    # (e.g. zimmer-router → agent-orchestrator-prod + 1password-rw) can freeze an
    # EMPTY mcp_servers column at create time when the catalog resolve was
    # structurally incomplete. On unarchive, AIR runs with --without-defaults
    # (which does NOT re-resolve default_in_roots), so an empty column degrades
    # the regenerated .mcp.json to only the auto-injected self-session server,
    # breaking downstream-session spawning. The unarchive must restore the
    # servers from the root's currently-resolved defaults. See session 8410.
    @session.update!(mcp_servers: [], catalog_skills: nil, catalog_hooks: nil, catalog_plugins: nil)
    @mock_fs.mkdir_p(@clone_path)

    # Root currently resolves these defaults (default_in_roots folded in).
    @session.stubs(:agent_root_default_mcp_servers).returns([ "context7" ])

    # Backfilling flips the gate to the prepare! branch (which passes the servers
    # to AIR as --mcp-server flags), instead of the empty-column baseline branch.
    AirPrepareService.any_instance.expects(:prepare!).once
    AirPrepareService.any_instance.expects(:ensure_baseline_mcp_config!).never
    AirPrepareService.any_instance.stubs(:injected_mcp_servers)
      .returns([ "zimmer-self-session" ])

    result = UnarchiveSessionService.call(
      session: @session,
      file_system: @mock_fs
    )

    assert result.success?

    @session.reload
    assert_equal [ "context7" ], @session.mcp_servers,
      "unarchive must backfill an empty mcp_servers column from the root's resolved defaults " \
      "so the regenerated .mcp.json restores the default_in_roots servers"
  end

  test "does not backfill mcp_servers when agent root resolves no defaults" do
    # A genuinely server-less root (no default_mcp_servers / default_in_roots)
    # must stay empty and fall through to ensure_baseline_mcp_config! — we only
    # heal the documented "landed empty" defect, never invent servers.
    @session.update!(mcp_servers: [], catalog_skills: nil, catalog_hooks: nil, catalog_plugins: nil)
    @mock_fs.mkdir_p(@clone_path)

    @session.stubs(:agent_root_default_mcp_servers).returns([])

    AirPrepareService.any_instance.expects(:ensure_baseline_mcp_config!).once
    AirPrepareService.any_instance.expects(:prepare!).never
    AirPrepareService.any_instance.stubs(:injected_mcp_servers).returns([])

    result = UnarchiveSessionService.call(
      session: @session,
      file_system: @mock_fs
    )

    assert result.success?

    @session.reload
    assert_equal [], @session.mcp_servers,
      "a root with no resolvable defaults must not have mcp_servers invented on unarchive"
  end

  test "does not clobber a non-empty mcp_servers column with agent root defaults" do
    # When the session already has explicit MCP servers, unarchive must leave
    # them untouched — backfill only targets the empty-column defect.
    @session.update!(mcp_servers: [ "context7" ])
    @mock_fs.mkdir_p(@clone_path)

    # Resolved root defaults differ; they must NOT overwrite the explicit list.
    @session.stubs(:agent_root_default_mcp_servers).returns([ "linear" ])
    AirPrepareService.any_instance.stubs(:injected_mcp_servers).returns([])

    result = UnarchiveSessionService.call(
      session: @session,
      file_system: @mock_fs
    )

    assert result.success?

    @session.reload
    assert_equal [ "context7" ], @session.mcp_servers,
      "unarchive must preserve an explicitly-configured mcp_servers list, not overwrite it with root defaults"
  end

  test "backfills only catalog-valid servers when resolved defaults contain an unknown name" do
    # Defends the heal against a still-structurally-incomplete catalog: if a name
    # is resolved into the root's defaults but is absent from the catalog's mcp
    # section, persisting it unfiltered would raise mcp_servers_must_exist_in_catalog
    # and silently abort the backfill. Filtering through ServersConfig.exists?
    # (the same gate the controller uses) keeps the valid servers and drops the
    # bogus one, so the heal still succeeds.
    @session.update!(mcp_servers: [], catalog_skills: nil, catalog_hooks: nil, catalog_plugins: nil)
    @mock_fs.mkdir_p(@clone_path)

    @session.stubs(:agent_root_default_mcp_servers)
      .returns([ "context7", "this-server-does-not-exist-xyz" ])

    AirPrepareService.any_instance.expects(:prepare!).once
    AirPrepareService.any_instance.expects(:ensure_baseline_mcp_config!).never
    AirPrepareService.any_instance.stubs(:injected_mcp_servers).returns([])

    result = UnarchiveSessionService.call(
      session: @session,
      file_system: @mock_fs
    )

    assert result.success?

    @session.reload
    assert_equal [ "context7" ], @session.mcp_servers,
      "backfill must keep only catalog-valid servers so an incomplete catalog can't make update! raise and abort the heal"
  end

  test "clears old process state when recreating clone" do
    # Session has stale process state from before archive
    @session.update!(metadata: @session.metadata.merge(
      "process_pid" => 12345,
      "sigterm_retry_count" => 3,
      "sigterm_retry_timestamps" => [ Time.current.iso8601 ],
      "last_sigterm_at" => Time.current.iso8601,
      "failure_reason" => "Old failure",
      "exit_status" => 1,
      "exception_class" => "RuntimeError"
    ))

    new_clone_path = "/home/test/.zimmer/clones/test-repo-main-99999-efgh"

    mock_create_clone = lambda do |_git_root, **_kwargs|
      { clone_path: new_clone_path, working_directory: new_clone_path }
    end

    GitCloneService.stub :create_clone, mock_create_clone do
      @mock_fs.mkdir_p(new_clone_path)

      result = UnarchiveSessionService.call(
        session: @session,
        file_system: @mock_fs
      )

      assert result.success?

      @session.reload
      # All old process state should be cleared
      assert_nil @session.metadata["process_pid"]
      assert_nil @session.metadata["sigterm_retry_count"]
      assert_nil @session.metadata["sigterm_retry_timestamps"]
      assert_nil @session.metadata["last_sigterm_at"]
      assert_nil @session.metadata["failure_reason"]
      assert_nil @session.metadata["exit_status"]
      assert_nil @session.metadata["exception_class"]
    end
  end

  test "transitions to needs_input state not waiting or failed" do
    @mock_fs.mkdir_p(@clone_path)

    result = UnarchiveSessionService.call(
      session: @session,
      file_system: @mock_fs
    )

    assert result.success?

    @session.reload
    # Should always transition to needs_input for immediate follow-up capability
    assert_equal "needs_input", @session.status
  end

  test "succeeds even when MCP config regeneration fails" do
    @mock_fs.mkdir_p(@clone_path)

    # Stub AirPrepareService to raise an exception
    AirPrepareService.any_instance.stubs(:prepare!).raises("AIR prepare failed")

    result = UnarchiveSessionService.call(
      session: @session,
      file_system: @mock_fs
    )

    # Should still succeed - MCP config is not critical
    assert result.success?

    @session.reload
    assert_equal "needs_input", @session.status
  end

  test "recreates clone when working_directory does not exist but clone_path does" do
    # Clone path exists but working_directory (with subdirectory) does not
    # This can happen if the subdirectory was removed or the clone was corrupted
    # With the fix, this should trigger clone recreation instead of failing
    subdirectory = "packages/web"
    full_working_directory = File.join(@clone_path, subdirectory)
    @session.update!(
      subdirectory: subdirectory,
      metadata: {
        "clone_path" => @clone_path,
        "working_directory" => full_working_directory
      }
    )

    # Only create the clone path, not the subdirectory
    @mock_fs.mkdir_p(@clone_path)
    # Do NOT create full_working_directory - simulates incomplete/corrupted clone

    # Mock GitCloneService to return a fresh clone
    new_clone_path = "/home/test/.zimmer/clones/test-repo-main-99999-efgh"
    new_working_directory = File.join(new_clone_path, subdirectory)

    mock_create_clone = lambda do |_git_root, **kwargs|
      { clone_path: new_clone_path, working_directory: new_working_directory }
    end

    GitCloneService.stub :create_clone, mock_create_clone do
      @mock_fs.mkdir_p(new_working_directory)

      result = UnarchiveSessionService.call(
        session: @session,
        file_system: @mock_fs
      )

      # Should succeed by recreating the clone
      assert result.success?
      assert_equal true, result.clone_restored

      # Verify metadata was updated with new clone path
      @session.reload
      assert_equal new_clone_path, @session.metadata["clone_path"]
      assert_equal new_working_directory, @session.metadata["working_directory"]
      assert_equal "needs_input", @session.status
    end
  end

  test "recreates clone when clone_path exists but working_directory is missing from metadata" do
    # Edge case: clone_path exists on disk but working_directory is nil in metadata
    @session.update!(
      metadata: {
        "clone_path" => @clone_path
        # "working_directory" is missing
      }
    )

    @mock_fs.mkdir_p(@clone_path)

    new_clone_path = "/home/test/.zimmer/clones/test-repo-main-99999-ijkl"

    mock_create_clone = lambda do |_git_root, **kwargs|
      { clone_path: new_clone_path, working_directory: new_clone_path }
    end

    GitCloneService.stub :create_clone, mock_create_clone do
      @mock_fs.mkdir_p(new_clone_path)

      result = UnarchiveSessionService.call(
        session: @session,
        file_system: @mock_fs
      )

      assert result.success?
      assert_equal true, result.clone_restored

      @session.reload
      assert_equal new_clone_path, @session.metadata["clone_path"]
      assert_equal new_clone_path, @session.metadata["working_directory"]
      assert_equal "needs_input", @session.status
    end
  end

  test "clears stale quota metadata on unarchive" do
    @session.update!(
      metadata: (@session.metadata || {}).merge(
        "exit_status" => "Account quota limit reached — retry skipped",
        "last_quota_limit_at" => "2026-04-11T22:44:07Z",
        "last_quota_limit_message" => "You've hit your limit · resets 11pm (UTC)",
        "quota_limit_count" => 1,
        "failure_reason" => "quota_exhausted"
      )
    )

    @mock_fs.mkdir_p(@clone_path)

    result = UnarchiveSessionService.call(
      session: @session,
      file_system: @mock_fs
    )

    assert result.success?

    @session.reload
    assert_nil @session.metadata["exit_status"],
      "exit_status must be cleared on unarchive"
    assert_nil @session.metadata["last_quota_limit_at"],
      "last_quota_limit_at must be cleared on unarchive"
    assert_nil @session.metadata["last_quota_limit_message"],
      "last_quota_limit_message must be cleared on unarchive"
    assert_nil @session.metadata["quota_limit_count"],
      "quota_limit_count must be cleared on unarchive"
    assert_nil @session.metadata["failure_reason"],
      "failure_reason must be cleared on unarchive"
    # Non-stale metadata should be preserved
    assert_equal @clone_path, @session.metadata["clone_path"]
  end

  # Race-condition coverage for GitHub issue pulsemcp/pulsemcp#3720.
  #
  # When a recurring trigger fires while a slow-path clone recreation is
  # already in flight (or any other concurrent unarchive), two callers can
  # reach `transition_to_needs_input` against the same session. Before the fix
  # in this PR, the loser would write `archived_at: nil` BEFORE checking the
  # AASM guard, ending up with archived_at cleared but the row still flagged
  # as needs_input by the winner — and a "Cannot transition session to
  # needs_input state" alert raised by Trigger#resuscitate_session!.
  test "transition_to_needs_input is idempotent when a concurrent unarchive already won" do
    # Simulate the race: by the time we reach transition_to_needs_input, a
    # concurrent caller has already flipped the row to needs_input.
    @session.update_column(:status, Session.statuses[:needs_input])
    @session.update_column(:archived_at, nil)

    service = UnarchiveSessionService.new(session: @session, file_system: @mock_fs)
    result = service.send(:transition_to_needs_input)

    assert result.success?, "Loser of the race should observe winner's state and return success"
    assert_nil result.error

    @session.reload
    assert_equal "needs_input", @session.status
    assert_nil @session.archived_at, "archived_at must remain nil (winner's state)"
  end

  # Regression coverage for GitHub issue pulsemcp/pulsemcp#4600.
  #
  # The pulsemcp/pulsemcp#3720 idempotency guard only recognized `needs_input` as the benign
  # "concurrent unarchive already won" state. But the winner's session can
  # advance PAST needs_input to `running` (its resumed job starts) before this
  # loser acquires the row lock. In that case archived_at is already cleared and
  # the status is `running`, so `may_unarchive_to_needs_input?` (from: archived)
  # is false — the loser used to return a failure that Trigger#resuscitate_session!
  # escalated into a spurious `.error` and tripped the agent-orchestrator-logs
  # alert. The loser must instead treat the already-unarchived session as an
  # idempotent success.
  test "transition_to_needs_input is idempotent when the winner already advanced to running" do
    # The winning caller fully unarchived (archived_at nil) and its job started
    # (status running) before this loser reached the locked transition.
    @session.update_column(:status, Session.statuses[:running])
    @session.update_column(:archived_at, nil)

    service = UnarchiveSessionService.new(session: @session, file_system: @mock_fs)
    result = service.send(:transition_to_needs_input)

    assert result.success?, "Loser observing winner's running state must return success, not raise"
    assert_nil result.error

    @session.reload
    assert_equal "running", @session.status, "Loser must not clobber the winner's running state"
    assert_nil @session.archived_at, "archived_at must remain nil (winner's state)"
  end

  test "transition_to_needs_input is idempotent when the winner already returned to waiting" do
    # A resuscitated router session that finished its work and returned to
    # waiting (exactly the session-3843 end state from issue pulsemcp/pulsemcp#4600).
    @session.update_column(:status, Session.statuses[:waiting])
    @session.update_column(:archived_at, nil)

    service = UnarchiveSessionService.new(session: @session, file_system: @mock_fs)
    result = service.send(:transition_to_needs_input)

    assert result.success?, "Loser observing winner's waiting state must return success, not raise"
    assert_nil result.error

    @session.reload
    assert_equal "waiting", @session.status, "Loser must not clobber the winner's waiting state"
    assert_nil @session.archived_at
  end

  # Regression coverage for GitHub issue pulsemcp/pulsemcp#4600 — the `call` ENTRY path.
  #
  # transition_to_needs_input is only reached after the loser passes
  # validate_inputs. But call reloads the row on entry, and the winner can
  # advance the session out of trash BEFORE that reload. When it does, entry must
  # short-circuit to an idempotent success; otherwise call falls through to
  # validate_inputs, which returns "Session is not in trash", and
  # Trigger#resuscitate_session! escalates that into the spurious .error alert.
  # Pre-fix, the entry check only recognized needs_input, so a running/waiting
  # winner produced a failure here — these two tests fail without the fix.
  test "call returns idempotent success on entry when the winner already advanced to running" do
    @session.update_columns(status: Session.statuses[:running], archived_at: nil)

    result = UnarchiveSessionService.call(session: @session, file_system: @mock_fs)

    assert result.success?, "Loser must observe the winner's running state and return success"
    assert_nil result.error
    assert_equal false, result.clone_restored

    @session.reload
    assert_equal "running", @session.status, "Loser must not clobber the winner's running state"
    assert_nil @session.archived_at
  end

  test "call returns idempotent success on entry when the winner already returned to waiting" do
    # The session-3843 end state from issue pulsemcp/pulsemcp#4600: a resuscitated router session
    # that finished its work and returned to waiting.
    @session.update_columns(status: Session.statuses[:waiting], archived_at: nil)

    result = UnarchiveSessionService.call(session: @session, file_system: @mock_fs)

    assert result.success?, "Loser must observe the winner's waiting state and return success"
    assert_nil result.error
    assert_equal false, result.clone_restored

    @session.reload
    assert_equal "waiting", @session.status, "Loser must not clobber the winner's waiting state"
    assert_nil @session.archived_at
  end

  # The abnormal "status advanced but archived_at still populated" row (pulsemcp/pulsemcp#3720)
  # must NOT be masked by the entry short-circuit: call still returns a clean
  # failure so the guard-ordering protection holds end-to-end at the entry point
  # too. archived_at being non-nil keeps the short-circuit from firing.
  test "call does not short-circuit on entry when archived_at is still populated" do
    @session.update_columns(status: Session.statuses[:waiting], archived_at: 1.hour.ago)

    result = UnarchiveSessionService.call(session: @session, file_system: @mock_fs)

    assert_not result.success?
    assert_includes result.error, "Session is not in trash"

    @session.reload
    assert_not_nil @session.archived_at, "archived_at must be left untouched"
  end

  test "transition_to_needs_input does NOT clear archived_at when guard fails for a non-needs_input state" do
    # A concurrent caller transitioned this row via unarchive_to_waiting!
    # (whose after_callback only clears trash_after, not archived_at — see
    # SessionStateMachine). Result: status=waiting + archived_at populated.
    # Our service must return a clean error WITHOUT clearing archived_at on
    # a row it no longer owns.
    archived_at = 1.hour.ago
    @session.update_columns(
      status: Session.statuses[:waiting],
      archived_at: archived_at
    )

    service = UnarchiveSessionService.new(session: @session, file_system: @mock_fs)
    result = service.send(:transition_to_needs_input)

    assert_not result.success?
    assert_includes result.error, "Cannot transition session to needs_input state"

    @session.reload
    assert_not_nil @session.archived_at, "archived_at must NOT be cleared when guard fails"
    assert_in_delta archived_at, @session.archived_at, 1.second
  end

  test "transition_to_needs_input checks guard before clearing archived_at on success path" do
    # The fixture session is archived. Confirm the happy path still works after
    # the reorder (guard first, then destructive write).
    @mock_fs.mkdir_p(@clone_path)

    service = UnarchiveSessionService.new(session: @session, file_system: @mock_fs)
    result = service.send(:transition_to_needs_input)

    assert result.success?

    @session.reload
    assert_equal "needs_input", @session.status
    assert_nil @session.archived_at
  end

  test "transition_to_needs_input wraps exceptions raised inside the locked block in a failure Result" do
    # If session.unarchive_to_needs_input! raises (e.g., AASM::InvalidTransition
    # from a state-machine race not covered by the early guards), the outer
    # rescue must convert it to a failure Result rather than bubble. Otherwise
    # Trigger#resuscitate_session! would still raise and fire the alert.
    @session.expects(:unarchive_to_needs_input!).raises(AASM::InvalidTransition.new(@session, :unarchive_to_needs_input, :default))

    service = UnarchiveSessionService.new(session: @session, file_system: @mock_fs)
    result = service.send(:transition_to_needs_input)

    assert_not result.success?
    assert_includes result.error, "Failed to transition session state"
  end

  test "call short-circuits to success without slow-path work when session is already needs_input" do
    # The whole-service early bail-out: if a concurrent caller already won
    # before this caller even entered #call, skip the slow path (git clone,
    # MCP regen) entirely. transition_to_needs_input would also short-circuit
    # under the lock, but only after wasting expensive work.
    @session.update_columns(
      status: Session.statuses[:needs_input],
      archived_at: nil
    )

    # If the slow path ran, GitCloneService.create_clone would be called.
    GitCloneService.expects(:create_clone).never

    service = UnarchiveSessionService.new(session: @session, file_system: @mock_fs)
    result = service.call

    assert result.success?
    assert_equal false, result.clone_restored
  end

  # Regression for issue #411: an interrupted `rm -rf` on a live clone was
  # preserved as a working tree patch of nothing but deletions, and unarchive
  # replayed it onto the pristine clone it had just created — deleting the agent
  # root's subdirectory, so `air prepare` died with ENOENT and the session
  # failed before its agent ever ran. Real git, real filesystem, end to end: the
  # clone that comes out of unarchive must still be a clone.
  test "unarchive keeps the pristine clone when preserved artifacts would gut it" do
    with_real_clone_sandbox do |bare_path, subdirectory|
      # Artifacts whose patch deletes the agent root's whole subdirectory. It is
      # deliberately small (below MASS_DELETION_MIN_FILES), so only the
      # post-apply validation can catch it.
      write_preserved_patch(deleting: [ "AGENTS.md", "CLAUDE.md" ].map { |f| File.join(subdirectory, f) })

      new_clone_path = clone_from(bare_path)
      result = unarchive_with_real_clone(new_clone_path)

      assert result.success?, result.error
      assert File.directory?(File.join(new_clone_path, subdirectory)),
        "the agent root's subdirectory must survive the restore — air prepare writes into it"
      assert File.exist?(File.join(new_clone_path, subdirectory, "AGENTS.md"))
      assert_equal "initial\n", File.read(File.join(new_clone_path, "README.md"))
      assert File.directory?(@artifact_service.artifacts_path_for(@session.id)),
        "artifacts that were not applied must stay on disk for manual recovery"
    end
  end

  # The archive-side guard only stops NEW corruption; patches captured before it
  # existed are already on disk. Unarchive must refuse those too, and must not
  # delete them on its way past.
  test "unarchive refuses a pre-existing mass-deletion patch and leaves the clone intact" do
    with_real_clone_sandbox(tracked_files: 60) do |bare_path, subdirectory|
      write_preserved_patch(deleting: 60.times.map { |i| format("tracked_%02d.rb", i) })

      new_clone_path = clone_from(bare_path)
      result = unarchive_with_real_clone(new_clone_path)

      assert result.success?, result.error
      assert File.exist?(File.join(new_clone_path, "tracked_00.rb")), "tracked files must not be deleted"
      assert File.directory?(File.join(new_clone_path, subdirectory))
      assert File.exist?(File.join(@artifact_service.artifacts_path_for(@session.id), "working_tree.patch")),
        "the refused patch stays on disk for manual salvage"
    end
  end

  # A patch that carries real work still restores, so the guards above cannot be
  # mistaken for "unarchive stopped restoring anything".
  test "unarchive still restores an ordinary working tree patch" do
    with_real_clone_sandbox do |bare_path, _subdirectory|
      File.write(File.join(@source_repo, "agent_work.rb"), "# real work\n")
      run_git(@source_repo, "add", "-A")
      write_patch_artifacts(git_output(@source_repo, "diff", "--binary", "--cached", "HEAD"))

      new_clone_path = clone_from(bare_path)
      result = unarchive_with_real_clone(new_clone_path)

      assert result.success?, result.error
      assert File.exist?(File.join(new_clone_path, "agent_work.rb")), "real uncommitted work must still restore"
      assert_not File.directory?(@artifact_service.artifacts_path_for(@session.id)),
        "applied artifacts are cleaned up as before"
    end
  end

  test "regeneration restores the auto-injected subagent Zimmer server for a subagent-roots-only root" do
    # Regression for the production wedge (sessions 9726/9890): a root whose only
    # subagent-spawning capability is the auto-injected Zimmer server
    # (catalog-management declares NO default_mcp_servers/skills/hooks/plugins)
    # lost that server on unarchive because the baseline regeneration path injected
    # only the self-session server. This exercises the REAL post-processor end to end
    # (no AirPrepareService stubbing) against the mock file system, proving the
    # subagent server survives regeneration.
    ENV["ZIMMER_LOCAL_API_KEY"] = "local-test-key"

    # Undo the setup-wide prepare! stub — this test drives the real else-branch
    # (ensure_baseline_mcp_config!), which does not shell out to AIR.
    AirPrepareService.any_instance.unstub(:prepare!)

    @session.update!(
      mcp_servers: [],
      catalog_skills: nil,
      catalog_hooks: nil,
      catalog_plugins: nil,
      metadata: {
        "clone_path" => @clone_path,
        "working_directory" => @working_directory,
        "agent_root_key" => "catalog-management"
      }
    )
    @mock_fs.mkdir_p(@clone_path)

    result = UnarchiveSessionService.call(session: @session, file_system: @mock_fs)
    assert result.success?

    # The regenerated .mcp.json must carry the subagent-spawning server: Zimmer's
    # own native MCP endpoint, scoped to the root's subagent roots.
    config = JSON.parse(@mock_fs.read(File.join(@working_directory, ".mcp.json")))
    zimmer_server = config.dig("mcpServers", "zimmer")
    assert_not_nil zimmer_server,
      "regenerated .mcp.json must contain the auto-injected Zimmer spawning server"
    assert_equal "http", zimmer_server["type"]
    assert_includes zimmer_server["url"], "catalog-mgmt-research"
    assert_includes zimmer_server["url"], "catalog-mgmt-save"
    # A full-surface Zimmer server (no tool_groups scoping) covers the self_session
    # tool group, so self-session capability is retained via this same server.
    refute_includes zimmer_server["url"], "tool_groups",
      "the subagent Zimmer server must expose the full tool surface, covering self_session"

    # And custom_metadata must record it so the UI reflects the restored server.
    @session.reload
    assert_includes @session.custom_metadata["injected_mcp_servers"], "zimmer",
      "custom_metadata.injected_mcp_servers must record the restored subagent Zimmer server"
  ensure
    ENV.delete("ZIMMER_LOCAL_API_KEY")
  end

  private

  # The #411 regressions need real git — a patch that deletes tracked files only
  # damages a real working tree — so they run against real repositories under a
  # private $HOME. The sandbox owns that isolation: artifacts
  # (~/.zimmer/artifacts/<id>) and the transcript file (~/.claude/projects/...)
  # both land inside it, so parallel workers never share a path and nothing is
  # written to the runner's real home.
  #
  # Yields [bare_repo_path, subdirectory]. The session is repointed at the bare
  # repo with a clone_path that does not exist, so unarchive takes the slow path
  # (recreate the clone, then restore artifacts into it).
  #
  # Weigh this before widening what runs inside the sandbox: a constant that
  # bakes Dir.home at class-load time would freeze a tmpdir path for the rest of
  # the worker process if it were first autoloaded here. The one on this path,
  # AirPrepareService::AIR_INSTALL_DIR, is already loaded under the real $HOME by
  # `setup`'s AirPrepareService.any_instance.stubs — keep that stub ahead of
  # this, and note CI eager-loads the whole graph at boot anyway.
  def with_real_clone_sandbox(tracked_files: 0)
    original_home = ENV["HOME"]
    @sandbox_home = Dir.mktmpdir("unarchive-home")
    ENV["HOME"] = @sandbox_home

    @bare_repo = Dir.mktmpdir("unarchive-bare")
    # Each repo lives one level inside its own tmpdir (git wants to create the
    # directory itself), and the tmpdir roots are what teardown removes.
    @tmp_roots = [ @sandbox_home, @bare_repo ]
    @source_repo = File.join(new_tmp_root("unarchive-source"), "repo")
    subdirectory = "artifacts/agent-roots/general-agent"

    run_cmd("git", "init", "--bare", @bare_repo)
    File.write(File.join(@bare_repo, "HEAD"), "ref: refs/heads/main\n")
    run_cmd("git", "clone", @bare_repo, @source_repo)
    run_git(@source_repo, "config", "user.email", "test@example.com")
    run_git(@source_repo, "config", "user.name", "Test User")
    run_git(@source_repo, "checkout", "-b", "main")

    File.write(File.join(@source_repo, "README.md"), "initial\n")
    FileUtils.mkdir_p(File.join(@source_repo, subdirectory))
    File.write(File.join(@source_repo, subdirectory, "AGENTS.md"), "# root\n")
    File.write(File.join(@source_repo, subdirectory, "CLAUDE.md"), "# root\n")
    tracked_files.times { |i| File.write(File.join(@source_repo, format("tracked_%02d.rb", i)), "# tracked #{i}\n") }
    run_git(@source_repo, "add", "-A")
    run_git(@source_repo, "commit", "-m", "initial commit")
    run_git(@source_repo, "push", "-u", "origin", "main")

    @session.update!(
      git_root: @bare_repo,
      subdirectory: subdirectory,
      metadata: {
        "clone_path" => File.join(@sandbox_home, "gone", "clone"),
        "working_directory" => File.join(@sandbox_home, "gone", "clone", subdirectory)
      }
    )
    @artifact_service = CloneArtifactService.new

    yield @bare_repo, subdirectory
  ensure
    original_home.nil? ? ENV.delete("HOME") : ENV["HOME"] = original_home
    Array(@tmp_roots).each { |dir| FileUtils.rm_rf(dir) }
  end

  def new_tmp_root(prefix)
    Dir.mktmpdir(prefix).tap { |dir| (@tmp_roots ||= []) << dir }
  end

  # A fresh clone standing in for the one GitCloneService makes on the slow path.
  def clone_from(bare_path)
    clone_path = File.join(new_tmp_root("unarchive-clone"), "repo")
    run_cmd("git", "clone", bare_path, clone_path)
    clone_path
  end

  def unarchive_with_real_clone(clone_path)
    working_directory = File.join(clone_path, @session.subdirectory)
    stub_clone = lambda do |_git_root, **_kwargs|
      { clone_path: clone_path, working_directory: working_directory }
    end

    GitCloneService.stub :create_clone, stub_clone do
      UnarchiveSessionService.call(session: @session, file_system: RealFileSystemAdapter.new)
    end
  end

  # Preserved artifacts whose working tree patch deletes the given tracked
  # files — the signature an interrupted `rm -rf` leaves behind.
  def write_preserved_patch(deleting:)
    deleting.each { |path| FileUtils.rm_f(File.join(@source_repo, path)) }
    run_git(@source_repo, "add", "-A")
    write_patch_artifacts(git_output(@source_repo, "diff", "--binary", "--cached", "HEAD"))
  end

  def write_patch_artifacts(patch)
    artifacts_dir = @artifact_service.artifacts_path_for(@session.id)
    FileUtils.mkdir_p(artifacts_dir)
    File.binwrite(File.join(artifacts_dir, "working_tree.patch"), patch)
    File.write(File.join(artifacts_dir, "metadata.json"),
      JSON.generate("has_bundle" => false, "has_working_tree_patch" => true))
    artifacts_dir
  end

  def run_git(repo, *args)
    run_cmd("git", "-C", repo, *args)
  end

  def git_output(repo, *args)
    stdout, status = Open3.capture2("git", "-C", repo, *args, binmode: true)
    raise "git #{args.join(" ")} failed" unless status.success?
    stdout
  end

  def run_cmd(*args)
    system(*args, out: File::NULL, err: File::NULL, exception: true)
  end

  # --- Runtimes without a single-file resume transcript (#504) ----------------
  #
  # TranscriptSource#resume_transcript_path returns nil for Codex, whose rollouts
  # are date-partitioned, UUID-named and possibly Zstandard-compressed. Both
  # restore paths (#restore_transcript_only and #recreate_clone_and_restore) must
  # SUCCEED for such a runtime, writing nothing, rather than mkdir_p-ing a Claude
  # project directory, dropping a <session_id>.jsonl the runtime will never read,
  # and gating the unarchive on that write. Mirrors
  # AgentSessionJob#write_transcript_to_clone, which honours the same contract.

  # Every path a Claude unarchive would have written under, so a Codex unarchive
  # can be asserted to have touched none of them.
  def claude_projects_paths(mock_fs)
    claude_projects = File.join(File.expand_path("~"), ".claude", "projects")
    (mock_fs.files.keys + mock_fs.directories.to_a).select { |p| p.start_with?(claude_projects) }
  end

  test "quick unarchive of a Codex session succeeds without writing under ~/.claude/projects" do
    @session.update!(agent_runtime: "codex")
    @mock_fs.mkdir_p(@clone_path)

    result = UnarchiveSessionService.call(session: @session, file_system: @mock_fs)

    assert result.success?, "Codex unarchive must succeed; got error: #{result.error.inspect}"
    assert_nil result.error
    @session.reload
    assert_equal "needs_input", @session.status
    assert_nil @session.archived_at

    assert_nil TranscriptRuntime.source_for(@session, file_system: @mock_fs)
      .resume_transcript_path(session: @session, working_directory: @working_directory),
      "Codex has no single-file resume transcript path — the premise of this test"

    assert_empty claude_projects_paths(@mock_fs),
      "A Codex unarchive must not create or write anything under ~/.claude/projects"
  end

  test "full unarchive of a Codex session recreates the clone without writing under ~/.claude/projects" do
    @session.update!(agent_runtime: "codex")
    new_clone_path = "/home/test/.zimmer/clones/test-repo-main-99999-efgh"

    mock_create_clone = lambda do |_git_root, **_kwargs|
      { clone_path: new_clone_path, working_directory: new_clone_path }
    end

    GitCloneService.stub :create_clone, mock_create_clone do
      @mock_fs.mkdir_p(new_clone_path)

      result = UnarchiveSessionService.call(session: @session, file_system: @mock_fs)

      assert result.success?, "Codex unarchive must succeed; got error: #{result.error.inspect}"
      assert_equal true, result.clone_restored
      @session.reload
      assert_equal "needs_input", @session.status
      assert_equal new_clone_path, @session.metadata["working_directory"]

      assert_nil TranscriptRuntime.source_for(@session, file_system: @mock_fs)
        .resume_transcript_path(session: @session, working_directory: new_clone_path),
        "Codex has no single-file resume transcript path — the premise of this test"

      assert_empty claude_projects_paths(@mock_fs),
        "A Codex unarchive must not create or write anything under ~/.claude/projects"
    end
  end

  test "a genuine transcript write failure still fails the unarchive" do
    raising_fs = Class.new(MockFileSystemAdapter) do
      def write(path, content, **options)
        raise Errno::EACCES, "Permission denied - #{path}" if path.end_with?(".jsonl")
        super
      end
    end.new
    raising_fs.mkdir_p(@clone_path)

    result = UnarchiveSessionService.call(session: @session, file_system: raising_fs)

    assert_not result.success?,
      "A write that RAISES is a real failure and must not be confused with the nil (nothing-to-do) case"
    assert_equal "Failed to write transcript file", result.error
  end
end
