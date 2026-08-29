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

  # Find the main transcript file for a session, avoiding nested agent transcripts.
  # Delegates to TranscriptFileLocator for the shared logic.
  def find_main_transcript_file_for_session(session, transcript_dir)
    TranscriptFileLocator.find_main_transcript(session, transcript_dir)
  end
end
