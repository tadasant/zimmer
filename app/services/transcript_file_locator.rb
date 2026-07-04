# Utility class for locating transcript files in Claude Code projects.
#
# Claude Code stores transcripts in ~/.claude/projects/<sanitized-path>/ with:
# - Main session transcript: <session_id>.jsonl
# - Nested agent transcripts: agent-*.jsonl
#
# This class provides a unified way to find the main transcript file,
# avoiding the pitfall of selecting by mtime (which can pick nested agent files).
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

    # Fallback: find any non-agent transcript file by mtime
    # This handles cases where session_id might not be set yet
    all_transcript_files = file_system.glob(File.join(transcript_dir, "*.jsonl"))
    return nil if all_transcript_files.empty?

    # Filter out agent-*.jsonl files (subagent transcripts)
    main_transcript_files = all_transcript_files.reject { |f| File.basename(f).start_with?("agent-") }

    # If no non-agent files, return nil (all files are subagent transcripts)
    return nil if main_transcript_files.empty?

    # Return the most recently modified main transcript file
    main_transcript_files.max_by { |f| file_system.mtime(f) }
  end

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
