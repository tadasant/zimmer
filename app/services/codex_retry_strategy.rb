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
# == Everything else: the error Codex recorded ==
#
# A failed Codex turn ends on a rollout `task_complete` record carrying a
# `codex_error_info` code (CodexTurnError has the evidence table). The four
# recovery questions are answered from that code, read through
# RecordedTurnError so this strategy and the recovery service it routes to
# agree on which error is live:
#
#   context_window_exceeded        -> context_length_error?  (resume; Codex compacts itself)
#   internal_server_error,
#   server_overloaded, 429, 5xx    -> api_error_for_retry?   (backoff retry)
#   usage_limit_exceeded           -> api_error_for_retry?   (ApiErrorRetryService answers
#                                                             :quota_exceeded -> rotation)
#   unauthorized, 401              -> auth_recovery_needed?  (AuthRecoveryCoordinator)
#
# Anything else is unclassified, and an unclassified Codex exit is now news:
# #classifies_exits? is true, so it reaches UnclassifiedFailureReporter with
# Codex's own message attached (#unclassified_error_text).
#
# None of this reads stderr. Codex's stderr is its tracing log, full of WARN
# lines that quote upstream errors mid-retry ("retrying sampling request (2/5)
# … 401 Unauthorized"), so a stderr pattern would fire on errors Codex went on
# to recover from.
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

  # Which recorded kinds ApiErrorRetryService takes: the transient ones it
  # retries, and the quota refusal it hands back as :quota_exceeded.
  API_ERROR_KINDS = %i[retryable quota].freeze

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

  # The turn died because the conversation outgrew the model's context window.
  # The recovery is a resume: Codex compacts the thread itself before its next
  # turn (see CodexRuntimeAdapter.compacts_on_resume?).
  def context_length_error?(stderr_log_path:)
    unhandled_kind(@session&.working_directory) == :context_length
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

  # A transient upstream failure Codex's own retries did not outlast, or the
  # account's usage limit — both are ApiErrorRetryService's to answer.
  def api_error_for_retry?(working_dir:)
    API_ERROR_KINDS.include?(unhandled_kind(working_dir))
  end

  # Codex could not authenticate the account on disk: its refresh token was
  # refused (expired, revoked, or already spent by another refresh), or the
  # backend answered 401 after a refresh. AuthRecoveryCoordinator decides
  # whether that is an adoption, a rotation, or a park.
  def auth_recovery_needed?(working_dir:)
    unhandled_kind(working_dir) == :auth
  end

  # Codex's own words for an error no classifier above recognized, for the
  # unclassified failure alert.
  #
  # @return [String, nil]
  def unclassified_error_text(working_dir:)
    error = unhandled_error(working_dir)
    return nil unless error && !error.recognized?

    error.message.presence
  end

  # The error this turn DIED on, whoever owns it. ProcessLifecycleManager asks
  # this last on the exits it would otherwise read as completed — the unreaped
  # door, where there is no exit code — so a Codex turn that ended on an error
  # is failed and named rather than parked as finished.
  #
  # Deliberately NOT filtered by the handled marker: a recovery that acted on
  # this error and whose replacement then wrote nothing leaves the turn just as
  # dead. ProcessLifecycleManager keeps its own once-per-turn key.
  #
  # @return [ApiErrorRetryService::TerminalApiError, nil]
  def terminal_api_error(working_dir:)
    return nil unless working_dir

    error = RecordedTurnError.terminal(session: @session, working_directory: working_dir, file_system: @file_system)
    return nil unless error

    ApiErrorRetryService::TerminalApiError.new(
      text: error.message.presence || "(no error text)",
      recognized: error.recognized?,
      line: error.id
    )
  rescue => e
    @logger.error("Error checking the Codex rollout for a terminal turn error", error: e.message)
    nil
  end

  # Codex's classifiers answer from a structured code, so an exit none of them
  # claims is genuinely unknown and worth the unclassified-failure alert.
  def classifies_exits?
    true
  end

  private

  def unhandled_kind(working_dir)
    unhandled_error(working_dir)&.kind
  end

  def unhandled_error(working_dir)
    return nil unless working_dir && @session

    RecordedTurnError.unhandled(session: @session, working_directory: working_dir, file_system: @file_system)
  rescue => e
    @logger.error("Error reading the Codex rollout for a turn error", error: e.message)
    nil
  end
end
