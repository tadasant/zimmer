# frozen_string_literal: true

# RuntimeCliAdapter — the contract every agent-runtime CLI adapter implements.
#
# An adapter is the single seam through which Zimmer spawns a coding-agent CLI
# process (today: `claude`; forthcoming: `codex`, see #3777). It builds the
# command, injects the environment, spawns the process, and reports back the
# pid plus the stderr log path the monitoring loop should tail.
# ProcessLifecycleManager depends on this contract via dependency injection and
# never references a concrete runtime directly.
#
# == Required methods (must be implemented by including classes) ==
#
# execute(prompt:, session_id:, working_dir:, mcp_config_path: nil, images: nil,
#         append_system_prompt: nil, model: nil, ...) -> { pid:, stderr_log_path: }
#   Spawn a fresh runtime session. Returns a Hash with the spawned :pid and the
#   :stderr_log_path the monitoring loop should tail.
#
# resume(session_id:, working_dir:, prompt: nil, images: nil, mcp_config_path: nil,
#        append_system_prompt: nil, model: nil, ...) -> { pid:, stderr_log_path: }
#   Resume an existing runtime session with an optional follow-up prompt.
#   Same return shape as #execute.
#
# binary_name -> String
#   The CLI binary the adapter spawns (e.g. "claude"). Informational/diagnostic.
#
# command_summary(session_id:, prompt:, mcp_config_path: nil, resume: false) -> String
#   A concise, human-readable summary of the command the adapter spawns, for
#   operator-facing session logs. Each runtime owns its own representation so
#   callers never re-fabricate a per-runtime binary+flags string. The verbose
#   system prompt is omitted and the prompt is truncated — a debugging summary,
#   not an exact reproduction.
#
# retry_strategy(session:, file_system:, process_manager:, rate_limit_tracker:, logger:)
#     -> retry strategy object
#   Factory for the runtime-specific exit classifier. ProcessLifecycleManager
#   asks the returned object whether a given process exit warrants context-length,
#   failed-resume, or API-error recovery. Each runtime owns its own patterns
#   because the signals (stderr strings, transcript error envelopes) differ.
#   The returned object must respond to:
#     - normal_completion_exit?(status) -> Boolean
#     - context_length_error?(stderr_log_path:) -> Boolean
#     - failed_resume_recovery_needed?(stderr_log_path:) -> Boolean
#     - api_error_for_retry?(working_dir:) -> Boolean
#   normal_completion_exit? answers whether a non-zero exit code is actually a
#   normal "paused turn" rather than a failure — Claude Code exits 1 when it
#   finishes a turn and awaits input, whereas Codex exits 1 on a genuine error.
#   ProcessLifecycleManager asks the strategy instead of hardcoding `== 1`.
#   Generic, OS-level exit classification (e.g. SIGTERM detection) stays in
#   ProcessLifecycleManager because it applies to every runtime.
#
# == Mutable accessors (DI surface used by ProcessLifecycleManager) ==
#
#   process_manager=, file_system=, zimmer_session_id=
#   ProcessLifecycleManager sets these so the adapter shares its process manager
#   and file system (important for test doubles) and knows the Zimmer session id for
#   MCP elicitation callbacks.
#
# == Optional hooks (sensible defaults provided here) ==
#
# disallowed_tools -> Array<String>
#   Tool identifiers the runtime must refuse to invoke. Empty for runtimes that
#   have no equivalent enforcement flag.
#
# runtime_env_vars -> Hash<String, String>
#   Runtime-specific environment variables to inject into the spawned process.
#   Defaults to {}. ClaudeCliAdapter injects its env vars inline in spawn_process
#   (CLAUDE_CODE_DISABLE_CRON, MCP_TIMEOUT, etc. — explicitly out of scope of the
#   #3766 refactor) and leaves this default in place; the hook is the declarative
#   seam for runtimes that prefer to contribute env vars this way.
#
# The shared contract is exercised by
# test/contracts/runtime_cli_adapter_contract_test.rb against every adapter.
module RuntimeCliAdapter
  # Tool identifiers the runtime must refuse to invoke. Override for runtimes
  # with a tool-blocking flag (see ClaudeCliAdapter#disallowed_tools).
  def disallowed_tools
    []
  end

  # Runtime-specific environment variables to inject into the spawned process.
  # See the module docstring for why ClaudeCliAdapter leaves this as the default.
  def runtime_env_vars
    {}
  end
end
