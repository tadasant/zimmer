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
# == Required class methods (see ClassMethods) ==
#
# .stderr_log_filename -> String
#   The name of the file the spawned process's stderr is redirected into, inside
#   the working directory. Every runtime writes a differently-named log, so this
#   is the single source of truth callers rebuild a stderr path from — see
#   .stderr_log_path and Session#stderr_log_path.
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
  # Raised when a spawn is attempted without a working directory and the adapter
  # declares no runtime-specific error class of its own.
  class SpawnError < StandardError; end

  def self.included(base)
    base.extend(ClassMethods)
  end

  # Class-level surface of the contract. These are class methods because callers
  # that never spawn — a monitoring loop rebuilding a stderr path, a test double
  # enforcing the same guard — need them without instantiating an adapter.
  module ClassMethods
    # The stderr log file this runtime's process writes inside its working
    # directory ("claude_stderr.log", "codex_stderr.log", …).
    #
    # @return [String]
    def stderr_log_filename
      raise NotImplementedError, "#{name} must define .stderr_log_filename"
    end

    # The stderr log path for a working directory, in this runtime's own naming.
    #
    # Callers rebuild this path when they reconnect to a process they did not
    # spawn (job resume, interrupt, controller-driven termination). It is built
    # from the WORKING directory — the directory the adapter spawned in, which is
    # the clone root only for sessions without an agent root — and named by the
    # runtime, so a Codex session is never handed a Claude filename.
    #
    # @param working_dir [String, nil]
    # @return [String, nil] nil when there is no working directory to join onto
    def stderr_log_path(working_dir)
      return nil if working_dir.blank?

      File.join(working_dir, stderr_log_filename)
    end

    # The error class this runtime raises when a spawn precondition fails.
    # Override to keep a runtime's own error type (ClaudeCliError, CodexCliError).
    def spawn_error_class
      SpawnError
    end

    # Human-readable name of the CLI, for operator-facing error messages.
    def cli_label
      name
    end

    # Refuse to spawn without a working directory. Process.spawn would otherwise
    # reject a nil chdir deep inside the C call with "no implicit conversion of nil
    # into String", which tells an operator nothing about which argument was nil.
    #
    # A nil working_dir is always a caller bug, and it has two possible causes: the
    # session never established a clone (it died during its first spawn, before
    # metadata was written), or a caller failed to load the established one from
    # session metadata. The message names both — naming only the first sends an
    # operator hunting for a missing clone that may be sitting intact on disk.
    #
    # Part of the shared contract rather than one runtime's private guard: every
    # runtime is spawned by the same recovery paths, so every runtime needs the
    # same legible failure. Test doubles enforce it too — a double that spawns
    # happily with a nil working dir hides this class of bug from the suite.
    def validate_working_dir!(working_dir)
      return unless working_dir.nil? || (working_dir.is_a?(String) && working_dir.strip.empty?)

      raise spawn_error_class,
        "Cannot spawn #{cli_label}: working directory is missing (got #{working_dir.inspect}). " \
        "Either the session never established a clone/working directory, or the caller did not " \
        "load session.metadata[\"working_directory\"] before spawning."
    end
  end

  # @see ClassMethods#validate_working_dir!
  def validate_working_dir!(working_dir)
    self.class.validate_working_dir!(working_dir)
  end

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
