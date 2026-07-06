# frozen_string_literal: true

# CodexRetryStrategy classifies Codex CLI process exits so that
# ProcessLifecycleManager can decide which recovery path to take. It is the
# Codex counterpart to ClaudeRetryStrategy, returned by
# CodexRuntimeAdapter#retry_strategy.
#
# == Exit-code convention differs from Claude ==
#
# Claude Code exits with code 1 when it merely finishes a turn and pauses for
# input — a normal "conversation paused" state. Codex does NOT share that
# convention: `codex exec` returns 0 on a successful turn and a non-zero code
# (1) on a genuine failure. So #normal_completion_exit? returns false here —
# letting a Codex exit 1 fall through to ProcessLifecycleManager's failure
# handling instead of being silently reported as a paused, successful turn.
#
# == Failed-resume detection ==
#
# `codex exec resume <thread-id>` exits non-zero when the rollout file for the
# requested thread id no longer exists (e.g. CODEX_HOME was ephemeral and wiped
# on a container restart). #failed_resume_recovery_needed? recognizes that
# signature so ProcessLifecycleManager can recover by starting a fresh turn
# (dropping the dead resume id) instead of reporting a hard failure with a blank
# transcript.
#
# == Not yet characterized ==
#
# context_length_error? and api_error_for_retry? still return false because the
# Codex-specific signals are not yet characterized in Zimmer: Codex's
# context-length stderr strings differ from Claude's, and the Codex transcript
# error envelope shape is owned by the Codex transcript source (#3779). Unlike a
# failed resume, those conditions surface as ordinary non-zero exits that
# ProcessLifecycleManager already classifies as failures — so deferring here is
# safe (the failure is reported, not hidden). As the Codex transcript pipeline
# and real-world failure patterns are understood, this strategy gains the same
# kind of pattern matching ClaudeRetryStrategy has today.
#
# The constructor mirrors ClaudeRetryStrategy so ProcessLifecycleManager can
# build either strategy through the identical adapter#retry_strategy factory.
class CodexRetryStrategy
  # `codex exec resume <thread-id>` prints a JSON-RPC error to stderr and exits
  # non-zero when the rollout for the requested thread id is gone:
  #   "Error: ... no rollout found for thread id <uuid> ... code -32600"
  # We key on the human-readable "no rollout found" phrase, NOT the accompanying
  # -32600 ("Invalid Request") RPC code: -32600 is generic and an MCP server can
  # emit it during a normal (non-resume) turn. Matching it would route ordinary
  # failures into fresh-start recovery — and because that recovery has no attempt
  # cap, a standing -32600 condition would loop indefinitely, re-running the whole
  # prompt each time. "no rollout found" is specific to a missing rollout and a
  # fresh `codex exec` (which resumes nothing) cannot reproduce it, so recovery
  # clears the signal exactly as the Claude path's does.
  FAILED_RESUME_PATTERN = /no rollout found/i

  def initialize(cli_adapter:, session:, file_system:, process_manager:, rate_limit_tracker:, logger: Rails.logger)
    @cli_adapter = cli_adapter
    @session = session
    @file_system = file_system
    @process_manager = process_manager
    @rate_limit_tracker = rate_limit_tracker
    @logger = logger
  end

  # Codex exits 0 on a completed turn and non-zero on a genuine failure — it has
  # no Claude-style "exit 1 means paused for input" convention. Returning false
  # ensures a Codex exit 1 is routed through ProcessLifecycleManager's failure
  # handling (surfacing stderr / failed-resume recovery) rather than being
  # reported as a successful, paused turn with an empty transcript.
  def normal_completion_exit?(status)
    false
  end

  # Codex context-length error detection is not yet characterized; defer to
  # generic exit handling, which classifies it as a (surfaced) failure. See the
  # class docstring.
  def context_length_error?(stderr_log_path:)
    false
  end

  # Detect a failed `codex exec resume` whose rollout no longer exists.
  #
  # Without this check the Codex exit 1 falls through to the generic failure
  # path and the session ends as `failed` with the raw stderr surfaced — usable
  # but not recoverable. Recognizing the signature lets ProcessLifecycleManager
  # start a fresh turn (dropping the dead resume id) instead.
  def failed_resume_recovery_needed?(stderr_log_path:)
    return false unless stderr_log_path
    return false unless @file_system.exists?(stderr_log_path)

    content = @file_system.read(stderr_log_path)
    return false if content.blank?

    content.match?(FAILED_RESUME_PATTERN)
  rescue => e
    @logger.error("Error checking stderr for failed resume", error: e.message)
    false
  end

  # Codex transcript API-error envelope parsing is owned by the Codex transcript
  # source (#3779); until it lands there is nothing to classify.
  def api_error_for_retry?(working_dir:)
    false
  end

  # Codex's mid-session auth-invalidation signature (the analog of Claude Code's
  # "Not logged in / Please run /login") is not yet characterized in Zimmer — its
  # transcript error envelope is owned by the Codex transcript source (#3779).
  # Until then there is nothing to classify, so an invalidated Codex turn falls
  # through to the generic failure path (surfaced, not hidden), exactly as
  # #api_error_for_retry? does.
  def auth_recovery_needed?(working_dir:)
    false
  end
end
