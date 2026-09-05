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

  # The root that holds one directory per working directory Claude Code has been
  # spawned from — `~/.claude/projects`.
  #
  # Resolved at call time (never memoized) so a stubbed HOME is honored without a
  # process restart, matching ClonesDirectory.base.
  #
  # @return [String]
  def self.projects_root
    File.join(File.expand_path("~"), ".claude", "projects")
  end

  # @see TranscriptSource#per_working_directory_transcript_root
  def per_working_directory_transcript_root
    self.class.projects_root
  end

  # @see TranscriptSource#transcript_directory
  #
  # The ONE place the cwd -> transcript-directory rule is written. The reapers
  # (CloneReaper via TranscriptDirectoryReaper, and
  # OrphanTranscriptDirectoryCleanupJob) derive the directory NAME from this same
  # method rather than re-implementing the slug — the rule is subtler than it
  # reads (PathSanitizer maps `_` to `-` as well as `/` and `.`, which is why
  # `.zimmer` renders as `--zimmer`), and a second copy that drifted would delete
  # a live session's transcript.
  def transcript_directory(working_directory:)
    return nil unless working_directory.present?

    sanitized_path = PathSanitizer.sanitize(working_directory)
    File.join(self.class.projects_root, sanitized_path)
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

  # @see TranscriptSource#read_raw
  def read_raw(path)
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

  # @see TranscriptSource#rotates_transcript_files?
  #
  # Claude Code resumes into <transcript_directory>/<session_id>.jsonl and keeps
  # appending to that one file for the life of the session, so the file only ever
  # gets shorter when the clone holding it was recreated. That is history loss to
  # be refused and repaired, never new conversation to append.
  def rotates_transcript_files?
    false
  end
end
