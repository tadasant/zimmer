# Locating a session's transcript on disk, for the controllers that refresh it.
#
# Both SessionsController (web) and Api::V1::SessionsController (REST) re-read a
# session's transcript from the filesystem on demand. They need the same two
# answers — which directory holds it, and which file inside that directory is the
# main one — so those answers live here once rather than as a copy per
# controller.
#
# The directory comes from the session's runtime TranscriptSource
# (TranscriptRuntime.source_for), which is the single place that knows where a
# runtime writes its transcript. Nothing here recomputes a runtime's on-disk
# layout.
module SessionTranscriptLookup
  extend ActiveSupport::Concern

  private

  # The directory holding this session's transcript files.
  #
  # @param session [Session]
  # @return [String, nil] nil when the session has no recorded directory yet, or
  #   when the runtime source cannot determine one
  def get_transcript_directory_for_session(session)
    # Session#working_directory prefers the recorded working_directory (which
    # includes the agent root subdirectory) and falls back to clone_path for
    # sessions recorded before that key existed.
    working_directory = session.working_directory
    return nil unless working_directory.is_a?(String) && working_directory.present?

    TranscriptRuntime.source_for(session).transcript_directory(working_directory: working_directory)
  rescue => e
    Rails.logger.error "Failed to get transcript directory: #{e.message}"
    nil
  end

  # Find the main transcript file for a session inside that directory.
  #
  # Also the runtime's own answer, for the same reason the directory is: Claude
  # picks <session_id>.jsonl out of a flat directory (TranscriptFileLocator),
  # Codex globs a date-partitioned tree for the rollout carrying the session's
  # UUID. Pairing a runtime's directory with another runtime's file-picker finds
  # nothing at best and someone else's conversation at worst.
  def find_main_transcript_file_for_session(session, transcript_dir)
    TranscriptRuntime.source_for(session)
      .find_main_transcript(transcript_directory: transcript_dir, session: session)
  end
end
