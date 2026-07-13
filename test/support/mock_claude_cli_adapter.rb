# frozen_string_literal: true

# Mock implementation of ClaudeCliAdapter for testing
# This allows tests to simulate Claude CLI behavior without spawning real processes.
#
# Usage in tests:
#   adapter = MockClaudeCliAdapter.new
#   adapter.execute_hook = ->(opts) { { pid: 12345, stderr_log_path: "/tmp/stderr.log" } }
#   result = adapter.execute(prompt: "Test", session_id: "123", working_dir: "/tmp")
#   adapter.executed_commands  # => [{ prompt: "Test", session_id: "123", ... }]
class MockClaudeCliAdapter
  include RuntimeCliAdapter

  attr_accessor :execute_hook, :resume_hook
  attr_reader :executed_commands, :resumed_sessions
  attr_accessor :process_manager, :file_system, :zimmer_session_id

  def initialize
    @executed_commands = []
    @resumed_sessions = []
    @next_pid = 20000
    @process_manager = MockProcessManager.new
    @file_system = MockFileSystemAdapter.new
  end

  # Simulate executing Claude CLI
  # Note: images parameter added for multimodal support
  # Note: append_system_prompt parameter added for system prompt injection
  def execute(prompt:, session_id:, working_dir:, mcp_config_path: nil, images: nil,
              append_system_prompt: nil, model: nil, dangerously_skip_permissions: true, debug: false,
              auto_compact_window: ClaudeCliAdapter::DEFAULT_AUTO_COMPACT_WINDOW)
    command_info = {
      prompt: prompt,
      session_id: session_id,
      working_dir: working_dir,
      mcp_config_path: mcp_config_path,
      images: images,
      append_system_prompt: append_system_prompt,
      model: model,
      auto_compact_window: auto_compact_window
    }
    @executed_commands << command_info

    if execute_hook
      execute_hook.call(command_info)
    else
      # Default behavior: return success with mock PID
      pid = @next_pid
      @next_pid += 1
      {
        pid: pid,
        stderr_log_path: File.join(working_dir, "claude_stderr.log")
      }
    end
  end

  # Simulate resuming a Claude CLI session
  # Note: images and mcp_config_path parameters added for multimodal and MCP support
  # Note: append_system_prompt parameter added for system prompt injection
  def resume(session_id:, prompt: nil, working_dir:, images: nil, mcp_config_path: nil,
             append_system_prompt: nil, model: nil, dangerously_skip_permissions: true, debug: false,
             auto_compact_window: ClaudeCliAdapter::DEFAULT_AUTO_COMPACT_WINDOW)
    resume_info = {
      session_id: session_id,
      prompt: prompt,
      working_dir: working_dir,
      images: images,
      mcp_config_path: mcp_config_path,
      append_system_prompt: append_system_prompt,
      model: model,
      auto_compact_window: auto_compact_window
    }
    @resumed_sessions << resume_info

    if resume_hook
      resume_hook.call(resume_info)
    else
      # Default behavior: return success with mock PID
      pid = @next_pid
      @next_pid += 1
      {
        pid: pid,
        stderr_log_path: File.join(working_dir, "claude_stderr.log")
      }
    end
  end

  # RuntimeCliAdapter contract — mirror ClaudeCliAdapter so the seam behaves
  # identically under test.
  def binary_name
    "claude"
  end

  def disallowed_tools
    ClaudeCliAdapter::DISALLOWED_TOOLS
  end

  # Delegate to the real adapter so the logged command summary is identical to
  # production (command_summary is pure formatting with no process side effects).
  def command_summary(session_id:, prompt:, mcp_config_path: nil, resume: false)
    ClaudeCliAdapter.new.command_summary(
      session_id: session_id, prompt: prompt, mcp_config_path: mcp_config_path, resume: resume
    )
  end

  # Returns the real ClaudeRetryStrategy operating on the mock's collaborators,
  # so ProcessLifecycleManager exit-classification behaves the same in tests.
  def retry_strategy(session:, file_system:, process_manager:, rate_limit_tracker:, logger: Rails.logger)
    ClaudeRetryStrategy.new(
      cli_adapter: self,
      session: session,
      file_system: file_system,
      process_manager: process_manager,
      rate_limit_tracker: rate_limit_tracker,
      logger: logger
    )
  end

  # Helper method for testing: reset all state
  def clear
    @executed_commands.clear
    @resumed_sessions.clear
    @next_pid = 20000
  end
end
