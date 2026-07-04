# frozen_string_literal: true

# Mock implementation of CodexRuntimeAdapter for testing.
# Lets tests assert command construction / invocation without spawning a real
# `codex` process. Mirrors MockClaudeCliAdapter so both runtimes exercise the
# same RuntimeCliAdapter seam under test.
#
# Usage in tests:
#   adapter = MockCodexRuntimeAdapter.new
#   adapter.execute_hook = ->(opts) { { pid: 12345, stderr_log_path: "/tmp/codex_stderr.log" } }
#   result = adapter.execute(prompt: "Test", session_id: "123", working_dir: "/tmp")
#   adapter.executed_commands  # => [{ prompt: "Test", session_id: "123", ... }]
class MockCodexRuntimeAdapter
  include RuntimeCliAdapter

  attr_accessor :execute_hook, :resume_hook
  attr_reader :executed_commands, :resumed_sessions
  attr_accessor :process_manager, :file_system, :ao_session_id

  def initialize
    @executed_commands = []
    @resumed_sessions = []
    @next_pid = 30000
    @process_manager = MockProcessManager.new
    @file_system = MockFileSystemAdapter.new
  end

  # Simulate executing Codex CLI.
  # auto_compact_window is accepted for contract symmetry with ClaudeCliAdapter
  # (ProcessLifecycleManager passes it uniformly to whichever adapter is selected)
  # but unused by Codex — recorded so tests can assert it flowed through.
  def execute(prompt:, session_id:, working_dir:, mcp_config_path: nil, images: nil,
              append_system_prompt: nil, model: nil, auto_compact_window: nil)
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
      pid = @next_pid
      @next_pid += 1
      {
        pid: pid,
        stderr_log_path: File.join(working_dir, "codex_stderr.log")
      }
    end
  end

  # Simulate resuming a Codex CLI session.
  # auto_compact_window accepted for contract symmetry (see #execute); unused.
  def resume(session_id:, working_dir:, prompt: nil, images: nil, mcp_config_path: nil,
             append_system_prompt: nil, model: nil, auto_compact_window: nil)
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
      pid = @next_pid
      @next_pid += 1
      {
        pid: pid,
        stderr_log_path: File.join(working_dir, "codex_stderr.log")
      }
    end
  end

  # RuntimeCliAdapter contract — mirror CodexRuntimeAdapter so the seam behaves
  # identically under test.
  def binary_name
    "codex"
  end

  # Delegate to the real adapter so the logged command summary is identical to
  # production (command_summary is pure formatting with no process side effects).
  def command_summary(session_id:, prompt:, mcp_config_path: nil, resume: false)
    CodexRuntimeAdapter.new.command_summary(
      session_id: session_id, prompt: prompt, mcp_config_path: mcp_config_path, resume: resume
    )
  end

  # Returns the real CodexRetryStrategy operating on the mock's collaborators,
  # so ProcessLifecycleManager exit-classification behaves the same in tests.
  def retry_strategy(session:, file_system:, process_manager:, rate_limit_tracker:, logger: Rails.logger)
    CodexRetryStrategy.new(
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
    @next_pid = 30000
  end
end
