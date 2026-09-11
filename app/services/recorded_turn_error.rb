# frozen_string_literal: true

# RecordedTurnError — the error a session's runtime recorded for its latest
# turn, minus the ones a recovery path has already acted on.
#
# For a runtime whose transcript keeps a structured record of how each turn
# ended (TranscriptSource#records_turn_errors? — Codex today), this is what the
# retry strategy classifies an exit by and what the recovery services confirm
# before they act. Both sides read it here so they cannot disagree about which
# error is live: a classifier that saw an error its service then refused to act
# on would surface as a "recovery contradiction".
#
# == Why a handled marker ==
#
# A failed turn stays the transcript's terminal error until another turn ends.
# A recovery that resumes the runtime and whose replacement dies before writing
# anything would otherwise find the SAME error again and act on it again — the
# loop every recovery budget exists to stop, spent on one dead turn. So a
# recovery path that acts records the error's #id, and an error carrying that
# id is not offered again. The Claude recovery services do the same job with a
# transcript line cursor per service; one id serves every path here, because a
# turn error belongs to exactly one of them.
module RecordedTurnError
  # Session metadata key holding the #id of the last turn error a recovery path
  # acted on.
  HANDLED_KEY = "recorded_turn_error_handled_id"

  module_function

  # @param session [Session]
  # @param working_directory [String, nil]
  # @param file_system [FileSystemAdapter, nil]
  # @return [Object, nil] see TranscriptSource#terminal_turn_error
  def unhandled(session:, working_directory:, file_system: nil)
    error = terminal(session: session, working_directory: working_directory, file_system: file_system)
    return nil if error.nil? || error.id == session.metadata&.dig(HANDLED_KEY)

    error
  end

  # The terminal turn error whether or not it was already acted on — for the
  # failure backstop, which asks whether a turn died rather than who owns it.
  #
  # @return [Object, nil]
  def terminal(session:, working_directory:, file_system: nil)
    source = TranscriptRuntime.source_for(session, file_system: file_system)
    return nil unless source.records_turn_errors?

    source.terminal_turn_error(session: session, working_directory: working_directory)
  end

  # Whether the session's runtime records turn errors at all.
  #
  # @param session [Session]
  # @return [Boolean]
  def supported?(session)
    TranscriptRuntime.source_for(session).records_turn_errors?
  end

  # The metadata that marks `error` as acted on, for callers that fold it into a
  # wider write (a RetryBudget#record! `extra:`). Empty when there is no error.
  #
  # @return [Hash]
  def handled_attributes(error)
    error ? { HANDLED_KEY => error.id } : {}
  end
end
