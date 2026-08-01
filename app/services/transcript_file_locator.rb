# Utility class for locating transcript files in Claude Code projects.
#
# Claude Code stores transcripts in ~/.claude/projects/<sanitized-path>/ with:
# - Main session transcript: <session_id>.jsonl
# - Nested agent transcripts: agent-*.jsonl
#
# Selection is by session id whenever the runtime has minted one. Only in the
# window before that id is captured does this fall back to the most recently
# modified transcript, and the fallback is deliberately narrow: it skips
# agent-*.jsonl (a subagent transcript is frequently the newest file in the
# directory) and skips anything last written before the session existed, so a
# working directory that still holds an earlier session's transcript cannot hand
# this session someone else's conversation. Dropping the fallback entirely is
# not an option — during that window it is the only way to find the transcript
# at all, and a session with no transcript reads as dead when it is fine.
class TranscriptFileLocator
  # Find the main transcript file for a session
  #
  # @param session [Session] The session to find the transcript for
  # @param transcript_dir [String] The directory containing transcript files
  # @param file_system [FileSystemAdapter] Optional file system adapter for testing
  # @return [String, nil] The path to the main transcript file, or nil if not found
  def self.find_main_transcript(session, transcript_dir, file_system: nil)
    file_system ||= DefaultFileSystem.new

    # First try to find by session_id if available
    if session.session_id.present?
      session_transcript_file = File.join(transcript_dir, "#{session.session_id}.jsonl")
      return session_transcript_file if file_system.exists?(session_transcript_file)
    end

    fallback_transcript(session, transcript_dir, file_system)
  end

  # The pre-session_id fallback described in the class comment. nil means "no
  # transcript this session could have written yet", which callers already treat
  # as a waiting state rather than an error.
  def self.fallback_transcript(session, transcript_dir, file_system)
    candidates = file_system.glob(File.join(transcript_dir, "*.jsonl"))
      .reject { |path| File.basename(path).start_with?("agent-") }
    return nil if candidates.empty?

    # The runtime is spawned after the session row exists, so its transcript is
    # always written after session.created_at. Anything older belongs to a
    # previous occupant of this working directory.
    started_at = session.created_at
    candidates = candidates.select { |path| file_system.mtime(path) >= started_at } if started_at

    candidates.max_by { |path| file_system.mtime(path) }
  end
  private_class_method :fallback_transcript

  # Default file system adapter for production use
  class DefaultFileSystem
    def exists?(path)
      File.exist?(path)
    end

    def glob(pattern)
      Dir.glob(pattern)
    end

    def mtime(path)
      File.mtime(path)
    end
  end
end
