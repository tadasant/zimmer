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
# exists to stop, and it is why this strategy answers that question even though
# it still declines the recovery questions below.
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
# == What is still not classified, and why ==
#
# context_length_error?, api_error_for_retry? and auth_recovery_needed? still
# return false. Their signatures are now known — they are all the same
# `stopReason: "error"` entry #terminal_api_error reads — but each one names a
# RECOVERY path, and every one of those paths is Claude-shaped today:
#
#   * context_length_error? routes to ContextLengthRetryService, which recovers by
#     sending Claude Code's `/compact` slash command. Pi compacts on its own
#     schedule and has no such command, so answering true would spend the retry
#     budget re-sending a prompt Pi treats as ordinary text.
#   * api_error_for_retry? and unclassified_error_text? route through
#     ApiErrorRetryService, whose detection reads Claude's `isApiErrorMessage`
#     transcript envelope rather than Pi's.
#   * auth_recovery_needed? routes to AuthRecoveryService, which recovers by
#     re-writing the active account's credentials. PiAuthProvider pools no
#     accounts — Pi resolves a provider key from the session environment per
#     request — so there is nothing for it to re-write.
#
# Answering those honestly means making the three recovery services
# transcript-format-agnostic, which is its own piece of work (zimmer#856). Until
# then a Pi provider failure is FAILED and named rather than retried, which is
# the same posture Codex has and strictly better than the silent park it replaces.
class PiRetryStrategy
  # What Pi writes on an assistant message whose model call failed. Verified
  # against the pinned binary for 401, 429, 500 and 400 context_length_exceeded —
  # all four produce this same value with the HTTP status leading `errorMessage`.
  ERROR_STOP_REASON = "error"

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

  # Pi context-length error detection is not yet characterized; defer to generic
  # exit handling, which classifies it as a (surfaced) failure.
  def context_length_error?(stderr_log_path:)
    false
  end

  # Pi cannot fail a resume the way Codex can: `--session-id` creates the session
  # when it is missing rather than exiting non-zero. See the class docstring.
  def failed_resume_recovery_needed?(stderr_log_path:)
    false
  end

  # Pi transcript API-error envelope parsing is not characterized yet.
  def api_error_for_retry?(working_dir:)
    false
  end

  # Pi's mid-session auth-invalidation signature is not characterized yet.
  def auth_recovery_needed?(working_dir:)
    false
  end

  # No transcript error envelope to mine for unmatched prose, for the same reason
  # as the classifiers above: this feeds ApiErrorRetryService's "is this
  # accounted for?" question, which is asked of Claude's envelope, not Pi's.
  def unclassified_error_text(working_dir:)
    nil
  end

  # The provider error this turn DIED on, or nil.
  #
  # ProcessLifecycleManager consults this LAST on the normal-completion (exit 0)
  # path, after every classifier above has declined. For Pi that is the path a
  # failed model call actually takes — see the class docstring — so this is the
  # one question this strategy can answer with real evidence, and answering it is
  # what turns "Process exited successfully" into a failed session that names the
  # provider's own wording.
  #
  # "Terminal" means the LAST conversational entry in the transcript is the error.
  # An error followed by more conversation is a turn that recovered on its own,
  # and failing the session for it would be wrong.
  #
  # @param working_dir [String, nil]
  # @return [ApiErrorRetryService::TerminalApiError, nil]
  def terminal_api_error(working_dir:)
    return nil unless working_dir

    entry = terminal_error_entry(working_dir)
    return nil unless entry

    ApiErrorRetryService::TerminalApiError.new(
      text: entry.fetch("errorMessage"),
      # Nothing in this strategy classifies a Pi provider error yet, so no
      # wording is "recognized". That is what routes it to the failure report
      # WITHOUT a page — see ProcessLifecycleManager#report_terminal_api_error,
      # which declines to alert while #classifies_exits? is false.
      recognized: false,
      line: entry.fetch("line")
    )
  rescue => e
    @logger.error("Error checking the Pi transcript for a terminal API error", error: e.message)
    nil
  end

  # Pi classifies nothing, so an ordinary Pi failure is ALWAYS an exit no
  # classifier matched — this strategy's documented design, not an anomaly.
  # ProcessLifecycleManager asks this before raising the unclassified-exit alert;
  # answering false keeps the expected shape of a Pi failure from becoming a
  # standing page, which is how an alert channel gets ignored. The loud log still
  # happens, so the signal is not lost. Flip this to true once the Pi failure
  # signatures are characterized and the classifiers above can actually answer.
  def classifies_exits?
    false
  end

  private

  # The last conversational entry of the session transcript, when it is an
  # assistant message Pi ended with `stopReason: "error"`.
  #
  # Reads through PiTranscriptSource so the file is located exactly as the
  # transcript poller locates it — by the session id in the header, covering both
  # the name Pi chose and the fixed name Zimmer restores to.
  #
  # `model_change` / `thinking_level_change` records are Pi's own bookkeeping and
  # are appended around messages, so the scan is over `type: "message"` entries
  # rather than over raw lines: a trailing bookkeeping record must not make a
  # terminal error look non-terminal.
  #
  # @return [Hash, nil] { "errorMessage" => String, "line" => String }
  def terminal_error_entry(working_dir)
    source = PiTranscriptSource.new(file_system: @file_system)
    path = source.locate(session: @session, working_directory: working_dir)
    return nil unless path

    raw = source.read_raw(path)
    return nil if raw.blank?

    last = source.parse_events(raw).select { |event| event["type"] == "message" }.last
    return nil unless last

    message = last["message"]
    return nil unless message.is_a?(Hash)
    return nil unless message["stopReason"] == ERROR_STOP_REASON
    return nil if message["errorMessage"].blank?

    # The line is the idempotency key ProcessLifecycleManager stores so one dead
    # turn is failed once. The entry's own id is stable and unique per record,
    # which is a better key than the serialized JSON it came from.
    { "errorMessage" => message["errorMessage"].to_s, "line" => last["id"].to_s }
  end
end
