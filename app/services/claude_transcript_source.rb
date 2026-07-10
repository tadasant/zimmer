# TranscriptSource for the Claude Code runtime.
#
# Claude Code stores transcripts under:
#   ~/.claude/projects/<sanitized-working-directory>/
# with:
#   - the main session transcript at <session_id>.jsonl
#   - nested subagent transcripts at agent-*.jsonl
# and MCP server logs under the Claude CLI cache directory
# (see PathSanitizer.cache_base).
#
# Each transcript line is a standalone JSON object (JSONL).
class ClaudeTranscriptSource < TranscriptSource
  require "path_sanitizer"

  # @see TranscriptSource#transcript_directory
  def transcript_directory(working_directory:)
    return nil unless working_directory

    home_dir = File.expand_path("~")
    claude_projects_dir = File.join(home_dir, ".claude", "projects")
    sanitized_path = PathSanitizer.sanitize(working_directory)
    File.join(claude_projects_dir, sanitized_path)
  rescue => e
    Rails.logger.error "[ClaudeTranscriptSource] Failed to compute transcript directory: #{e.message}"
    nil
  end

  # @see TranscriptSource#resume_transcript_path
  #
  # Claude Code resumes from <transcript_directory>/<session_id>.jsonl — the file
  # `locate` (via TranscriptFileLocator) prefers — so the restored transcript MUST
  # land there (under ~/.claude/projects/...), NOT in the CLI cache directory used
  # for MCP logs.
  def resume_transcript_path(session:, working_directory:)
    return nil unless session&.session_id.present?

    dir = transcript_directory(working_directory: working_directory)
    return nil unless dir

    File.join(dir, "#{session.session_id}.jsonl")
  end

  # @see TranscriptSource#locate
  def locate(session:, working_directory:)
    transcript_dir = transcript_directory(working_directory: working_directory)
    return nil unless transcript_dir
    return nil unless file_system.directory?(transcript_dir)

    find_main_transcript(transcript_directory: transcript_dir, session: session)
  end

  # Find the main (non-subagent) transcript file within a directory.
  #
  # Delegates to TranscriptFileLocator, which prefers the <session_id>.jsonl
  # file and falls back to the most-recent non-agent .jsonl file. We avoid a
  # plain mtime selection because subagent files (agent-*.jsonl) can be newer.
  #
  # @param transcript_directory [String] the session's transcript directory
  # @param session [Session] the session whose transcript we want
  # @return [String, nil] the main transcript file path, or nil if not found
  def find_main_transcript(transcript_directory:, session:)
    TranscriptFileLocator.find_main_transcript(session, transcript_directory, file_system: file_system)
  end

  # @see TranscriptSource#read
  def read(path)
    file_system.read(path)
  end

  # @see TranscriptSource#parse_events
  def parse_events(serialized)
    return [] unless serialized.present?

    serialized.lines.map do |line|
      JSON.parse(line.strip)
    rescue JSON::ParserError => e
      # A malformed line is expected and self-resolving during live transcript
      # polling: the last line can be read mid-flush (truncated) while a session
      # is still writing it. It is handled gracefully here (dropped via .compact,
      # the rest of the transcript still parses), so it warrants .warn — not a
      # paging .error.
      Rails.logger.warn "Failed to parse transcript line: #{e.message}"
      nil
    end.compact
  end

  # @see TranscriptSource#discover_subagent_files
  def discover_subagent_files(working_directory:, session_id: nil)
    transcript_dir = transcript_directory(working_directory: working_directory)
    return [] unless transcript_dir

    file_system.glob(File.join(transcript_dir, "agent-*.jsonl"))
  end

  # @see TranscriptSource#mcp_log_paths
  #
  # Returns the per-session MCP log base directory (Claude writes one
  # mcp-logs-<server-name>/ subdirectory beneath it). Empty when there is no
  # working directory to derive it from.
  def mcp_log_paths(working_directory:)
    return [] unless working_directory

    sanitized_path = PathSanitizer.sanitize(working_directory)
    [ File.join(PathSanitizer.cache_base, sanitized_path) ]
  end
end
