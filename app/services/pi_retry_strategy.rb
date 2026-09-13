# frozen_string_literal: true

# PiRetryStrategy classifies Pi CLI process exits so ProcessLifecycleManager can
# decide which recovery path to take. Returned by PiRuntimeAdapter#retry_strategy.
#
# == Exit-code convention ==
#
# Claude Code exits 1 when it merely finishes a turn and pauses for input — a
# normal "conversation paused" state. Pi does NOT share that convention: `pi -p`
# exits 0 on a completed turn and non-zero on a genuine failure (verified against
# a pinned Pi 0.84.4 driven by the e2e harness). So #normal_completion_exit?
# returns false, letting a Pi exit 1 fall through to ProcessLifecycleManager's
# failure handling rather than being silently reported as a paused, successful
# turn with an empty transcript.
#
# == A provider error is NOT a non-zero exit ==
#
# The sentence above is about Pi's own failures, and it does not extend to the
# model call. Driven against the simulated localhost LLM at 401, 429, 500 and a
# 400 `context_length_exceeded`, `pi -p` **exited 0 every time** and recorded the
# failure in the transcript instead:
#
#   {"role":"assistant","content":[],"stopReason":"error",
#    "errorMessage":"401: {\"message\":\"Incorrect API key provided.\", ...}"}
#
# Nothing reaches stderr. So without #terminal_api_error below, a Pi turn whose
# model call failed took ProcessLifecycleManager's success branch and parked the
# session in `needs_input` with "Process exited successfully" — claiming a turn
# finished when the model never answered and the human's prompt is still sitting
# unanswered in the transcript. That is the failure #handle_terminal_api_error
# exists to stop, and it is why the exit-0 door is where Pi's whole recovery
# ladder is consulted: ProcessLifecycleManager#diagnose_completed_turn asks every
# question below before it calls a turn finished.
#
# == Failed-resume detection ==
#
# Pi has none to detect, and that is a property of the runtime rather than an
# omission. `pi --session-id <uuid>` CREATES the session when no file carries
# that id — it prints "No project session found with id '<uuid>'; creating a new
# session with that id" and proceeds. A resume whose transcript vanished
# therefore starts a fresh conversation and exits 0; it never produces the
# non-zero exit that #failed_resume_recovery_needed? exists to recognize. The
# Codex signature ("no rollout found") has no Pi analog because Codex resolves a
# thread by rollout file and refuses when it is missing.
#
# The lost-history case is real, but it is handled a layer up and by a different
# mechanism: PiTranscriptSource#rotates_transcript_files? is false, so a
# transcript that comes back SHORTER is refused and the on-disk copy is repaired
# from Zimmer's stored bytes before the resume — which works for Pi precisely
# because it supports single-file restore (#resume_transcript_path).
#
# == What each failure is classified as ==
#
# Every recovery question below is answered from the error Pi recorded, read
# through the shared RecordedTurnError seam so this strategy and the service it
# routes to cannot disagree about which error is live. PiTurnError holds the
# evidence table; the short version is:
#
#   5xx, 429 rate limit, 408, `terminated`,          -> api_error_for_retry?  (backoff retry)
#     `Connection error.`
#   402, and a 429 worded as a quota wall            -> api_error_for_retry?  (quota: timed park)
#   401, 403                                         -> terminal, named, no page
#   any other 4xx (context length among them)        -> terminal, named, no page
#   no status, and no transport wording it knows     -> unclassified: fail and page
#
# The status decides, not the body. Production Pi talks to OpenRouter, whose
# error bodies read nothing like the OpenAI-dialect stub the characterization
# used, so a classifier keyed on body strings would misroute the provider Zimmer
# actually ships — and, with #classifies_exits? true, would page on every shape
# it had not memorized. PiTurnError carries that reasoning in full.
#
# The two terminal rows are the honest answer rather than a gap, and they are
# why #context_length_error? and #auth_recovery_needed? still return false:
#
#   * Pi has no `/compact`, and — unlike Codex — it does not compact on a plain
#     resume either. Driven against the real binary, a turn that died on a 400
#     `context_length_exceeded` and was resumed with the same `--session-id`
#     wrote no compaction record and re-sent the same conversation with one more
#     user message appended, failing identically. Answering true would spend the
#     retry budget making the conversation longer.
#   * PiAuthProvider pools no accounts by design — Pi resolves a provider key
#     from the session environment per request — so AuthRecoveryService has no
#     credential to rewrite and nothing to rotate to. Answering true would park
#     the session telling a human to re-authenticate a pool that does not exist.
#
# PiTurnError gives those two their own `_terminal` kinds rather than reusing
# :context_length / :auth, so neither service can be reached for them however
# the ladder is rearranged later. Both are `recognized?`, which fails the session
# naming the provider's own words WITHOUT paging: they are known failures with a
# deliberate disposition, not unknown ones.
#
# None of this reads stderr. Pi writes nothing there for a provider failure.
class PiRetryStrategy
  # The PiTurnError kinds ApiErrorRetryService owns.
  API_ERROR_KINDS = %i[retryable quota].freeze

  def initialize(cli_adapter:, session:, file_system:, process_manager:, rate_limit_tracker:, logger: Rails.logger)
    @cli_adapter = cli_adapter
    @session = session
    @file_system = file_system
    @process_manager = process_manager
    @rate_limit_tracker = rate_limit_tracker
    @logger = logger
  end

  # Pi exits 0 on a completed turn and non-zero on a genuine failure — it has no
  # Claude-style "exit 1 means paused for input" convention.
  def normal_completion_exit?(status)
    false
  end

  # Always false: Pi has no compaction recovery to route to.
  #
  # A context-length failure IS detected — PiTurnError classifies the 400 as
  # :context_length_terminal — but detection without a recovery is not a reason
  # to answer yes here. ContextLengthRetryService recovers either by sending
  # Claude Code's `/compact` (Pi has no such command) or by a plain resume for a
  # runtime that compacts itself on one (RuntimeCliAdapter::ClassMethods#compacts_on_resume?
  # — Codex does, Pi does not; see the class docstring for the run that shows it).
  # So the turn is failed and named by the terminal-error backstop instead, which
  # is the truthful end for a condition with no automated way out.
  def context_length_error?(stderr_log_path:)
    false
  end

  # Pi cannot fail a resume the way Codex can: `--session-id` creates the session
  # when it is missing rather than exiting non-zero. See the class docstring.
  def failed_resume_recovery_needed?(stderr_log_path:)
    false
  end

  # A transient provider failure Pi's own retries did not outlast — a 5xx, a 429,
  # or a request that never got a response — or a quota wall. The same kinds
  # CodexRetryStrategy routes here, and for the same reason: ApiErrorRetryService
  # resumes the first with exponential backoff and answers the second with
  # :quota_exceeded without spending the budget. Pi has no pool to rotate through
  # on that answer, so ProcessLifecycleManager parks it on ProviderQuotaWallPark's
  # timed ladder instead.
  def api_error_for_retry?(working_dir:)
    API_ERROR_KINDS.include?(unhandled_kind(working_dir))
  end

  # Always false: Pi has no credential pool to recover into.
  #
  # A 401 or 403 IS detected — PiTurnError classifies it :auth_terminal — but
  # AuthRecoveryService recovers by rewriting the active account's credentials
  # and rotating to the next account, and PiAuthProvider pools none of either.
  # Answering true would park the session asking a human to re-authenticate a
  # pool that does not exist, so the turn is failed naming the provider's own
  # words instead. Flip this the day Pi does pool credentials.
  def auth_recovery_needed?(working_dir:)
    false
  end

  # Pi's own words for an error no classifier above recognized, for the
  # unclassified failure alert.
  #
  # @return [String, nil]
  def unclassified_error_text(working_dir:)
    error = unhandled_error(working_dir)
    return nil unless error && !error.recognized?

    error.message.presence
  end

  # The provider error this turn DIED on, or nil.
  #
  # ProcessLifecycleManager consults this LAST, after every classifier above has
  # declined. For Pi that is the path a failed model call actually takes on the
  # exit-0 door — see the class docstring — so this is what turns "Process exited
  # successfully" into a failed session that names the provider's own wording.
  #
  # "Terminal" means the LAST message entry in the transcript is the error. An
  # error followed by more conversation is a turn that recovered on its own (Pi
  # retries a 5xx several times before giving up), and failing the session for it
  # would be wrong.
  #
  # Deliberately NOT filtered by the handled marker: a retry that acted on this
  # error and whose respawn then wrote nothing leaves the turn just as dead.
  # ProcessLifecycleManager keeps its own once-per-turn key.
  #
  # @param working_dir [String, nil]
  # @return [ApiErrorRetryService::TerminalApiError, nil]
  def terminal_api_error(working_dir:)
    return nil unless working_dir

    error = RecordedTurnError.terminal(session: @session, working_directory: working_dir, file_system: @file_system)
    return nil unless error

    ApiErrorRetryService::TerminalApiError.new(
      text: error.message.presence || "(no error text)",
      # A recognized error is failed and named without a page: it has been
      # through its own classifier, which either retried it to exhaustion or
      # declined it by design (auth, context length). Only a wording nothing
      # recognizes is news — see ProcessLifecycleManager#handle_terminal_api_error.
      recognized: error.recognized?,
      line: error.id
    )
  rescue => e
    @logger.error("Error checking the Pi transcript for a terminal turn error", error: e.message)
    nil
  end

  # Pi's classifiers answer from the error Pi itself recorded, so an exit none of
  # them claims is genuinely unknown and worth the unclassified-failure alert.
  # This was false while the signatures were uncharacterized, which kept the
  # expected shape of every Pi failure from becoming a standing page.
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
    @logger.error("Error reading the Pi transcript for a turn error", error: e.message)
    nil
  end
end
