# frozen_string_literal: true

# Answers one question: has the runtime written anything for this session yet?
#
# The question matters because `metadata["runtime_started"]` does not answer it.
# That flag is set the moment Zimmer records a spawned pid — before the runtime
# has produced a line — so a process killed in its first seconds (an MCP server
# that failed to connect, a deploy, an OOM) leaves the flag true over a
# conversation that was never persisted. Anything that then issues a `--resume`
# against it is dead on arrival, and anything that reads the resulting instant
# exit as a completed turn parks the session with a blank transcript.
#
# Both stores are consulted and both must be empty before we conclude nothing was
# written:
#
#   * Zimmer's own `session.transcript`, filled by TranscriptPollerService.
#   * The runtime's transcript file on disk, located through the runtime-agnostic
#     TranscriptSource seam.
#
# Requiring both is deliberate. Zimmer's copy alone would call a session empty
# whenever polling is merely lagging or broken, and the runtime's file alone
# would miss a session whose clone has been recreated under it. Only when neither
# store has a byte is "the runtime never got going" a safe conclusion.
module RuntimeConversationPresence
  module_function

  # @param session [Session]
  # @param working_directory [String, nil] the cwd the runtime was spawned from
  # @param file_system [FileSystemAdapter, nil] adapter for the on-disk lookup
  # @return [Boolean] true when either store holds transcript content
  def persisted?(session:, working_directory: nil, file_system: nil)
    return true if session&.transcript_line_count.to_i.positive?

    runtime_transcript_present?(session, working_directory, file_system)
  end

  # Errors are answered as "present" — the conservative direction. A lookup that
  # cannot run must not be read as proof the runtime wrote nothing, because every
  # caller treats that proof as licence to abandon the existing conversation.
  def runtime_transcript_present?(session, working_directory, file_system)
    return false if session.nil? || working_directory.blank?

    source = TranscriptRuntime.source_for(session, file_system: file_system)
    path = source.locate(session: session, working_directory: working_directory)
    return false if path.blank?

    source.read_raw(path).present?
  rescue => e
    Rails.logger.warn(
      "[RuntimeConversationPresence] Could not inspect the runtime transcript for " \
      "session #{session&.id}: #{e.message} — assuming a conversation exists"
    )
    true
  end
end
