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
# == Not yet characterized ==
#
# context_length_error?, api_error_for_retry? and auth_recovery_needed? return
# false, for the same reason CodexRetryStrategy's do: the Pi-specific signatures
# are not characterized in Zimmer yet, and every one of these conditions surfaces
# as an ordinary non-zero exit that ProcessLifecycleManager already classifies as
# a failure. So deferring is safe in the specific sense that the failure is
# REPORTED, not hidden — but it is a real gap, not a neutral default:
# auth_recovery_needed? returning false is what opts Pi out of the coordinated
# adopt/rotate/park path entirely. For Pi that costs less than it costs Codex,
# because PiAuthProvider pools no accounts and so has nothing to rotate TO (see
# its class docstring), but the classifier is still the blocker the day Pi does
# pool credentials.
class PiRetryStrategy
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
  # as the classifiers above.
  def unclassified_error_text(working_dir:)
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
end
