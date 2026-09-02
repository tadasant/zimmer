# frozen_string_literal: true

# Mock implementation of PiRuntimeAdapter for testing.
# Lets tests assert command construction / invocation without spawning a real
# `pi` process. Mirrors MockCodexRuntimeAdapter so every runtime exercises the
# same RuntimeCliAdapter seam under test.
#
# Usage in tests:
#   adapter = MockPiRuntimeAdapter.new
#   adapter.execute_hook = ->(opts) { { pid: 12345, stderr_log_path: "/tmp/pi_stderr.log" } }
#   result = adapter.execute(prompt: "Test", session_id: "123", working_dir: "/tmp")
#   adapter.executed_commands  # => [{ prompt: "Test", session_id: "123", ... }]
class MockPiRuntimeAdapter
  include RuntimeCliAdapter

  # RuntimeCliAdapter contract — delegate to the real adapter so the double's
  # stderr filename, spawn guard and error type can never drift from production.
  def self.stderr_log_filename
    PiRuntimeAdapter.stderr_log_filename
  end

  def self.spawn_error_class
    PiRuntimeAdapter.spawn_error_class
  end

  def self.cli_label
    PiRuntimeAdapter.cli_label
  end

  attr_accessor :execute_hook, :resume_hook
  attr_reader :executed_commands, :resumed_sessions
  attr_accessor :process_manager, :file_system, :zimmer_session_id

  def initialize
    @executed_commands = []
    @resumed_sessions = []
    @next_pid = 40000
    @process_manager = MockProcessManager.new
    @file_system = MockFileSystemAdapter.new
  end

  # Simulate executing the Pi CLI.
  # auto_compact_window is accepted for contract symmetry with ClaudeCliAdapter
  # (ProcessLifecycleManager passes it uniformly to whichever adapter is
  # selected) but unused by Pi — recorded so tests can assert it flowed through.
  def execute(prompt:, session_id:, working_dir:, mcp_config_path: nil, images: nil,
              append_system_prompt: nil, model: nil, auto_compact_window: nil)
    validate_working_dir!(working_dir)

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

    execute_hook ? execute_hook.call(command_info) : next_spawn_result(working_dir)
  end

  # Simulate resuming a Pi session.
  # auto_compact_window accepted for contract symmetry (see #execute); unused.
  def resume(session_id:, working_dir:, prompt: nil, images: nil, mcp_config_path: nil,
             append_system_prompt: nil, model: nil, auto_compact_window: nil)
    validate_working_dir!(working_dir)

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

    resume_hook ? resume_hook.call(resume_info) : next_spawn_result(working_dir)
  end

  # RuntimeCliAdapter contract — mirror PiRuntimeAdapter so the seam behaves
  # identically under test.
  def binary_name
    "pi"
  end

  # Delegate to the real adapter so the logged command summary is identical to
  # production (command_summary is pure formatting with no process side effects).
  def command_summary(session_id:, prompt:, mcp_config_path: nil, resume: false)
    PiRuntimeAdapter.new.command_summary(
      session_id: session_id, prompt: prompt, mcp_config_path: mcp_config_path, resume: resume
    )
  end

  # Returns the real PiRetryStrategy operating on the mock's collaborators, so
  # ProcessLifecycleManager exit-classification behaves the same in tests.
  def retry_strategy(session:, file_system:, process_manager:, rate_limit_tracker:, logger: Rails.logger)
    PiRetryStrategy.new(
      cli_adapter: self,
      session: session,
      file_system: file_system,
      process_manager: process_manager,
      rate_limit_tracker: rate_limit_tracker,
      logger: logger
    )
  end

  private

  def next_spawn_result(working_dir)
    pid = @next_pid
    @next_pid += 1
    { pid: pid, stderr_log_path: self.class.stderr_log_path(working_dir) }
  end
end
