# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"

class CodexRuntimeAdapterTest < ActiveSupport::TestCase
  setup do
    @adapter = CodexRuntimeAdapter.new
    @test_dir = Dir.mktmpdir
    @mock_process_manager = MockProcessManager.new
    @mock_file_system = MockFileSystemAdapter.new
    @adapter.process_manager = @mock_process_manager
    @adapter.file_system = @mock_file_system
    # The provisioner writes through raw File/FileUtils, not the injected file system,
    # so a developer with ZIMMER_OPERATOR_SSH_KEY exported would otherwise have the
    # suite write a key into their real ~/.ssh. Tests that need a path re-stub this.
    OperatorSshKeyProvisioner.stubs(:ensure!).returns(nil)
  end

  teardown do
    FileUtils.rm_rf(@test_dir) if @test_dir && File.exist?(@test_dir)
  end

  # ===== CONTRACT BASICS =====

  test "binary_name is codex" do
    assert_equal "codex", @adapter.binary_name
  end

  test "disallowed_tools is empty (Codex has no tool-blocking flag)" do
    assert_equal [], @adapter.disallowed_tools
  end

  test "runtime_env_vars is empty (no CLAUDE_CODE_* analogs)" do
    assert_equal({}, @adapter.runtime_env_vars)
  end

  test "retry_strategy returns a CodexRetryStrategy" do
    strategy = @adapter.retry_strategy(
      session: nil, file_system: nil, process_manager: nil, rate_limit_tracker: nil
    )
    assert_instance_of CodexRetryStrategy, strategy
  end

  # ===== EXECUTE COMMAND BUILDING =====

  test "build_command creates the codex exec command" do
    command = @adapter.send(:build_command,
      prompt: "do the thing",
      working_dir: "/clone/dir",
      images: nil,
      model: nil)

    expected = [
      "codex", "exec", "--json", "--dangerously-bypass-approvals-and-sandbox", "--cd", "/clone/dir",
      "--output-last-message", "/clone/dir/codex_last_message.txt",
      "do the thing"
    ]
    assert_equal expected, command
  end

  test "build_command bypasses the Codex sandbox and never uses --full-auto" do
    # Zimmer runs each session in an already-isolated, externally-sandboxed container
    # where Codex's bwrap-backed workspace-write sandbox (selected by --full-auto)
    # cannot create a user namespace, so every shell command fails. We must use
    # the explicit bypass flag instead (the Codex analog to Claude's
    # --dangerously-skip-permissions). Regressing this re-breaks all tool use (#3884).
    command = @adapter.send(:build_command,
      prompt: "hi", working_dir: "/clone/dir", images: nil, model: nil)
    assert_includes command, "--dangerously-bypass-approvals-and-sandbox"
    assert_not_includes command, "--full-auto"

    resume = @adapter.send(:build_resume_command,
      session_id: "uuid", prompt: "hi", working_dir: "/clone/dir", images: nil, model: nil)
    assert_includes resume, "--dangerously-bypass-approvals-and-sandbox"
    assert_not_includes resume, "--full-auto"
  end

  test "build_command includes the model flag when a model is given" do
    command = @adapter.send(:build_command,
      prompt: "hi",
      working_dir: "/clone/dir",
      images: nil,
      model: "gpt-5.4")

    assert_includes_subsequence command, [ "-m", "gpt-5.4" ]
  end

  test "build_command omits the model flag when no model is given" do
    command = @adapter.send(:build_command,
      prompt: "hi",
      working_dir: "/clone/dir",
      images: nil,
      model: nil)

    assert_not_includes command, "-m"
  end

  test "build_command does not pass a session id (Codex generates its own)" do
    command = @adapter.send(:build_command,
      prompt: "hi",
      working_dir: "/clone/dir",
      images: nil,
      model: nil)

    assert_not_includes command, "--session-id"
  end

  test "build_command appends an -i flag per image" do
    command = @adapter.send(:build_command,
      prompt: "describe these",
      working_dir: "/clone/dir",
      images: [ { path: "/tmp/a.png" }, { path: "/tmp/b.png" } ],
      model: nil)

    assert_includes_subsequence command, [ "-i", "/tmp/a.png" ]
    assert_includes_subsequence command, [ "-i", "/tmp/b.png" ]
    # Prompt is the trailing positional argument.
    assert_equal "describe these", command.last
  end

  # ===== RESUME COMMAND BUILDING =====

  test "build_resume_command targets the codex session uuid" do
    command = @adapter.send(:build_resume_command,
      session_id: "abc-123-uuid",
      prompt: "continue",
      working_dir: "/clone/dir",
      images: nil,
      model: nil)

    expected = [
      "codex", "exec", "resume", "abc-123-uuid", "--json", "--dangerously-bypass-approvals-and-sandbox",
      "--output-last-message", "/clone/dir/codex_last_message.txt",
      "continue"
    ]
    assert_equal expected, command
  end

  test "build_resume_command omits the prompt when none is given" do
    command = @adapter.send(:build_resume_command,
      session_id: "abc-123-uuid",
      prompt: nil,
      working_dir: "/clone/dir",
      images: nil,
      model: "gpt-5.4")

    expected = [
      "codex", "exec", "resume", "abc-123-uuid", "--json", "--dangerously-bypass-approvals-and-sandbox",
      "-m", "gpt-5.4",
      "--output-last-message", "/clone/dir/codex_last_message.txt"
    ]
    assert_equal expected, command
  end

  test "build_resume_command never passes --cd (the resume subcommand rejects it)" do
    # `codex exec` accepts `--cd <dir>`, but `codex exec resume` does NOT — it
    # aborts with "unexpected argument '--cd' found", which previously failed
    # every Codex follow-up/resume turn. The working dir comes from the spawned
    # process's chdir instead. build_command (fresh) still uses --cd. (#3884)
    resume = @adapter.send(:build_resume_command,
      session_id: "uuid", prompt: "go", working_dir: "/clone/dir", images: nil, model: nil)
    assert_not_includes resume, "--cd"

    fresh = @adapter.send(:build_command,
      prompt: "go", working_dir: "/clone/dir", images: nil, model: nil)
    assert_includes fresh, "--cd"
  end

  test "build_resume_command appends images" do
    command = @adapter.send(:build_resume_command,
      session_id: "uuid",
      prompt: "look",
      working_dir: "/clone/dir",
      images: [ { path: "/tmp/c.png" } ],
      model: nil)

    assert_includes_subsequence command, [ "-i", "/tmp/c.png" ]
  end

  # ===== SYSTEM PROMPT DELIVERY (AGENTS.md) =====

  test "execute writes append_system_prompt below the Zimmer marker in AGENTS.md before spawn" do
    @adapter.execute(
      prompt: "go",
      session_id: "zimmer-session-uuid",
      working_dir: @test_dir,
      append_system_prompt: "You are operating inside Zimmer."
    )

    agents_md = File.join(@test_dir, "AGENTS.md")
    assert @mock_file_system.exists?(agents_md), "expected AGENTS.md to be written"
    content = @mock_file_system.read(agents_md)
    assert content.start_with?(AgentsMdWriter::ZIMMER_SECTION_MARKER),
      "Zimmer content should lead with the shared marker so re-spawns can detect it"
    assert_includes content, "You are operating inside Zimmer."
  end

  test "execute does not write AGENTS.md when no system prompt is given" do
    @adapter.execute(
      prompt: "go",
      session_id: "zimmer-session-uuid",
      working_dir: @test_dir,
      append_system_prompt: nil
    )

    assert_not @mock_file_system.exists?(File.join(@test_dir, "AGENTS.md"))
  end

  test "resume writes append_system_prompt below the Zimmer marker in AGENTS.md before spawn" do
    @adapter.resume(
      session_id: "codex-uuid",
      working_dir: @test_dir,
      prompt: "more",
      append_system_prompt: "Zimmer system prompt."
    )

    content = @mock_file_system.read(File.join(@test_dir, "AGENTS.md"))
    assert content.start_with?(AgentsMdWriter::ZIMMER_SECTION_MARKER)
    assert_includes content, "Zimmer system prompt."
  end

  test "write_system_prompt preserves a committed AGENTS.md above the Zimmer marker" do
    agents_md = File.join(@test_dir, "AGENTS.md")
    @mock_file_system.write(agents_md, "# Repo AGENTS\n\nProject-specific Codex guidance.\n")

    @adapter.execute(
      prompt: "go",
      session_id: "uuid",
      working_dir: @test_dir,
      append_system_prompt: "Zimmer orchestrator context."
    )

    content = @mock_file_system.read(agents_md)
    assert_includes content, "# Repo AGENTS"
    assert_includes content, "Project-specific Codex guidance."
    assert_includes content, "Zimmer orchestrator context."
    assert content.index("# Repo AGENTS") < content.index(AgentsMdWriter::ZIMMER_SECTION_MARKER),
      "the repo's committed AGENTS.md should remain above the Zimmer-managed section"
  end

  test "write_system_prompt refreshes the Zimmer section without duplicating it across spawns" do
    # Simulates prepare-time AgentsMdWriter + spawn-time adapter writing the same
    # marker: the Zimmer section must be replaced, not appended a second time.
    @adapter.execute(
      prompt: "go",
      session_id: "uuid",
      working_dir: @test_dir,
      append_system_prompt: "First spawn context."
    )
    @adapter.execute(
      prompt: "go again",
      session_id: "uuid",
      working_dir: @test_dir,
      append_system_prompt: "Second spawn context."
    )

    content = @mock_file_system.read(File.join(@test_dir, "AGENTS.md"))
    assert_equal 1, content.scan(AgentsMdWriter::ZIMMER_SECTION_MARKER).length,
      "the Zimmer marker must appear exactly once after repeated spawns"
    assert_includes content, "Second spawn context."
    refute_includes content, "First spawn context.",
      "the stale Zimmer section should be replaced on the next spawn"
  end

  test "write_system_prompt preserves committed content while refreshing the Zimmer section across spawns" do
    # The two behaviors compose: a repo's committed AGENTS.md must survive every
    # spawn intact, while the Zimmer-managed section below it is replaced each time.
    agents_md = File.join(@test_dir, "AGENTS.md")
    @mock_file_system.write(agents_md, "# Repo AGENTS\n\nProject-specific Codex guidance.\n")

    @adapter.execute(
      prompt: "go",
      session_id: "uuid",
      working_dir: @test_dir,
      append_system_prompt: "First spawn context."
    )
    @adapter.execute(
      prompt: "go again",
      session_id: "uuid",
      working_dir: @test_dir,
      append_system_prompt: "Second spawn context."
    )

    content = @mock_file_system.read(agents_md)
    # Committed content survives intact, exactly once, above the marker.
    assert_equal 1, content.scan("# Repo AGENTS").length,
      "the repo's committed AGENTS.md must be preserved exactly once, not re-appended"
    assert_includes content, "Project-specific Codex guidance."
    assert content.index("# Repo AGENTS") < content.index(AgentsMdWriter::ZIMMER_SECTION_MARKER),
      "committed content stays above the Zimmer-managed section"
    # Zimmer section is refreshed, not duplicated.
    assert_equal 1, content.scan(AgentsMdWriter::ZIMMER_SECTION_MARKER).length,
      "the Zimmer marker must appear exactly once after repeated spawns"
    assert_includes content, "Second spawn context."
    refute_includes content, "First spawn context.",
      "the stale Zimmer section should be replaced on the next spawn"
  end

  test "spawn-time write_system_prompt replaces the Zimmer section laid down by the real prepare-time AgentsMdWriter" do
    # The prepare-time path (AgentsMdWriter#write!) and the spawn-time path
    # (CodexRuntimeAdapter#write_system_prompt) both manage the Zimmer section using the
    # same ZIMMER_SECTION_MARKER and the same "#{marker}\n\n#{content}\n" format. This
    # exercises the real handoff end to end: a committed AGENTS.md, then the real
    # writer appends its Zimmer block, then the adapter refreshes it on spawn. The
    # adapter must REPLACE the writer's block (marker appears once), not append a
    # second one — guarding against either side's format drifting from the other.
    agents_md = File.join(@test_dir, "AGENTS.md")
    @mock_file_system.write(agents_md, "# Repo AGENTS\n\nProject-specific Codex guidance.\n")

    # Prepare-time: the real writer appends the orchestrator context below the marker.
    AgentsMdWriter.new(
      session: Session.new(
        id: 4242,
        prompt: "test",
        branch: "main",
        repository_name: "tadasant/zimmer-catalog",
        subdirectory: "agents/agent-orchestrator",
        mcp_servers: [ "zimmer-sessions" ],
        agent_runtime: "codex"
      ),
      working_directory: @test_dir,
      file_system: @mock_file_system
    ).write!

    prepared = @mock_file_system.read(agents_md)
    assert_includes prepared, "# Zimmer Context",
      "sanity: the real writer should have laid down the orchestrator context"

    # Spawn-time: the adapter refreshes the Zimmer section with the live prompt.
    @adapter.execute(
      prompt: "go",
      session_id: "uuid",
      working_dir: @test_dir,
      append_system_prompt: "Spawn-time orchestrator context."
    )

    content = @mock_file_system.read(agents_md)
    # Committed repo content survives intact, above a single marker.
    assert_equal 1, content.scan("# Repo AGENTS").length
    assert content.index("# Repo AGENTS") < content.index(AgentsMdWriter::ZIMMER_SECTION_MARKER),
      "committed content stays above the Zimmer-managed section"
    # The adapter replaced — not appended to — the writer's Zimmer block.
    assert_equal 1, content.scan(AgentsMdWriter::ZIMMER_SECTION_MARKER).length,
      "the adapter must replace the writer's Zimmer section, leaving exactly one marker"
    assert_includes content, "Spawn-time orchestrator context."
    refute_includes content, "# Zimmer Context",
      "the writer's stale orchestrator body must be replaced by the adapter's refresh"
  end

  # ===== SPAWN BEHAVIOR =====

  test "execute spawns codex and returns the codex stderr log path" do
    result = @adapter.execute(
      prompt: "go",
      session_id: "zimmer-session-uuid",
      working_dir: @test_dir,
      model: "gpt-5.4"
    )

    assert_kind_of Integer, result[:pid]
    assert_equal File.join(@test_dir, "codex_stderr.log"), result[:stderr_log_path]

    spawned = @mock_process_manager.spawned_processes.last
    assert_equal "codex", spawned[:command].first
    assert_equal "exec", spawned[:command][1]
  end

  test "spawn uses a process group and detaches stdin/stdout" do
    @adapter.execute(prompt: "go", session_id: "uuid", working_dir: @test_dir)

    spawned = @mock_process_manager.spawned_processes.last
    assert_equal true, spawned[:options][:pgroup]
    assert_equal @test_dir, spawned[:options][:chdir]
    assert_equal File::NULL, spawned[:options][:in]
    assert_equal File::NULL, spawned[:options][:out]
  end

  test "spawn clears inherited database and bundler env vars" do
    @adapter.execute(prompt: "go", session_id: "uuid", working_dir: @test_dir)

    spawned = @mock_process_manager.spawned_processes.last
    env = spawned[:env]
    assert env.key?("DATABASE_URL"), "DATABASE_URL should be present (set to nil to unset)"
    assert_nil env["DATABASE_URL"]
    assert_nil env["BUNDLE_GEMFILE"]
    assert_nil env["RAILS_ENV"]
  end

  test "spawn loads .env from the working directory" do
    @mock_file_system.write(File.join(@test_dir, ".env"), "FOO=bar\nBAZ=qux\n")

    @adapter.execute(prompt: "go", session_id: "uuid", working_dir: @test_dir)

    env = @mock_process_manager.spawned_processes.last[:env]
    assert_equal "bar", env["FOO"]
    assert_equal "qux", env["BAZ"]
  end

  test "spawn enables rmcp logging so per-server connection lines reach stderr" do
    @adapter.execute(prompt: "go", session_id: "uuid", working_dir: @test_dir)

    env = @mock_process_manager.spawned_processes.last[:env]
    assert_equal "warn,rmcp=info", env["RUST_LOG"]
  end

  test "spawn respects an explicit RUST_LOG from the session .env" do
    @mock_file_system.write(File.join(@test_dir, ".env"), "RUST_LOG=debug\n")

    @adapter.execute(prompt: "go", session_id: "uuid", working_dir: @test_dir)

    env = @mock_process_manager.spawned_processes.last[:env]
    assert_equal "debug", env["RUST_LOG"]
  end

  test "spawn exports SSH_PRIVATE_KEY_PATH so the ssh-* MCP servers find the operator key" do
    OperatorSshKeyProvisioner.stubs(:ensure!).returns("/home/rails/.ssh/zimmer_operator_ed25519")

    @adapter.execute(prompt: "go", session_id: "uuid", working_dir: @test_dir)

    env = @mock_process_manager.spawned_processes.last[:env]
    assert_equal "/home/rails/.ssh/zimmer_operator_ed25519", env["SSH_PRIVATE_KEY_PATH"]
  end

  test "spawn leaves SSH_PRIVATE_KEY_PATH unset when no operator key is configured" do
    OperatorSshKeyProvisioner.stubs(:ensure!).returns(nil)

    @adapter.execute(prompt: "go", session_id: "uuid", working_dir: @test_dir)

    env = @mock_process_manager.spawned_processes.last[:env]
    assert_nil env["SSH_PRIVATE_KEY_PATH"]
  end

  test "spawn exports CODEX_HOME so rollouts persist to the durable location" do
    original = ENV["CODEX_HOME"]
    ENV["CODEX_HOME"] = "/srv/codex-state"

    @adapter.execute(prompt: "go", session_id: "uuid", working_dir: @test_dir)

    env = @mock_process_manager.spawned_processes.last[:env]
    assert_equal "/srv/codex-state", env["CODEX_HOME"]
  ensure
    original.nil? ? ENV.delete("CODEX_HOME") : ENV["CODEX_HOME"] = original
  end

  test "spawn exports the default CODEX_HOME when the env override is unset" do
    original = ENV["CODEX_HOME"]
    ENV.delete("CODEX_HOME")

    @adapter.execute(prompt: "go", session_id: "uuid", working_dir: @test_dir)

    env = @mock_process_manager.spawned_processes.last[:env]
    assert_equal File.join(Dir.home, ".codex"), env["CODEX_HOME"]
  ensure
    ENV["CODEX_HOME"] = original unless original.nil?
  end

  test "spawn respects an explicit CODEX_HOME from the session .env" do
    @mock_file_system.write(File.join(@test_dir, ".env"), "CODEX_HOME=/from/dotenv\n")

    @adapter.execute(prompt: "go", session_id: "uuid", working_dir: @test_dir)

    env = @mock_process_manager.spawned_processes.last[:env]
    assert_equal "/from/dotenv", env["CODEX_HOME"]
  end

  test "mcp_config_path is accepted but not passed on the command line" do
    @adapter.execute(
      prompt: "go",
      session_id: "uuid",
      working_dir: @test_dir,
      mcp_config_path: "/some/.mcp.json"
    )

    command = @mock_process_manager.spawned_processes.last[:command]
    assert_not_includes command, "--mcp-config"
    assert_not_includes command, "/some/.mcp.json"
  end

  # ===== auto_compact_window CONTRACT SYMMETRY =====
  # ProcessLifecycleManager and the retry services pass auto_compact_window to
  # whichever runtime adapter is selected. Codex has no auto-compaction concept,
  # so it must accept the kwarg without error and never leak it into the command.
  # Omitting it regressed Codex spawn (spawn_failed: unknown keyword) — #3884.

  test "execute accepts auto_compact_window without leaking it into the command" do
    result = @adapter.execute(
      prompt: "go",
      session_id: "uuid",
      working_dir: @test_dir,
      auto_compact_window: 250_000
    )

    assert_kind_of Integer, result[:pid]
    command = @mock_process_manager.spawned_processes.last[:command]
    assert_not_includes command, "250000"
    assert_not_includes command, "--auto-compact-window"
  end

  test "resume accepts auto_compact_window without leaking it into the command" do
    result = @adapter.resume(
      session_id: "codex-uuid",
      working_dir: @test_dir,
      prompt: "more",
      auto_compact_window: 250_000
    )

    assert_kind_of Integer, result[:pid]
    command = @mock_process_manager.spawned_processes.last[:command]
    assert_not_includes command, "250000"
    assert_not_includes command, "--auto-compact-window"
  end

  private

  # Assert that `subsequence` appears as consecutive elements within `array`.
  def assert_includes_subsequence(array, subsequence)
    found = array.each_cons(subsequence.length).any? { |slice| slice == subsequence }
    assert found, "expected #{array.inspect} to include consecutive #{subsequence.inspect}"
  end
end
