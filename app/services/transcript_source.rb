# Runtime-specific transcript I/O boundary.
#
# A TranscriptSource knows *where* an agent runtime writes its transcript bytes
# and *how* to read them. It is the file/format layer of the transcript
# pipeline; the semantic layer (raw events -> canonical timeline_item
# envelopes) belongs to TranscriptNormalizer.
#
# Splitting these two concerns lets a second runtime (e.g. OpenAI Codex, which
# writes ~/.codex/sessions/YYYY/MM/DD/rollout-*-<uuid>.jsonl[.zst]) slot in by
# providing its own TranscriptSource + TranscriptNormalizer without touching
# TranscriptPollerService, BroadcastService, or the view partials.
#
# Concrete implementations:
# - ClaudeTranscriptSource (~/.claude/projects/<sanitized-cwd>/<session_id>.jsonl)
#
# All paths are produced/consumed as Strings. IO is performed through an
# injected file_system adapter (see FileSystemAdapter) so the source is
# testable without touching disk.
class TranscriptSource
  # @param file_system [FileSystemAdapter] adapter used for all disk access
  def initialize(file_system: nil)
    @file_system = file_system || RealFileSystemAdapter.new
  end

  # The directory that holds this session's transcript files.
  #
  # @param working_directory [String] the cwd the runtime was spawned from
  # @return [String, nil] the directory path, or nil if it cannot be determined
  def transcript_directory(working_directory:)
    raise NotImplementedError, "#{self.class}#transcript_directory"
  end

  # The on-disk path where Zimmer should re-materialize the canonical stored
  # transcript so the runtime's `--resume` reads the complete conversation
  # history. This is the file the runtime actually reads on resume — distinct
  # from any cache/log directory.
  #
  # Returns nil for runtimes whose transcripts cannot be restored by writing the
  # stored bytes to a single deterministic path (e.g. Codex, whose rollouts are
  # date-partitioned, UUID-named, and may be Zstandard-compressed). A nil result
  # means "this runtime does not support single-file transcript restore"; callers
  # skip the restore for such runtimes rather than writing to a path the runtime
  # will never read.
  #
  # @param session [Session] the session whose transcript would be restored
  # @param working_directory [String] the cwd the runtime was spawned from
  # @return [String, nil] the resume transcript path, or nil if unsupported
  def resume_transcript_path(session:, working_directory:)
    nil
  end

  # Locate the main transcript file for the session.
  #
  # @param session [Session] the session whose transcript we want
  # @param working_directory [String] the cwd the runtime was spawned from
  # @return [String, nil] path to the main transcript file, or nil when the
  #   directory/files are not present yet ("waiting" state)
  def locate(session:, working_directory:)
    raise NotImplementedError, "#{self.class}#locate"
  end

  # Read the raw, decoded transcript bytes for a path.
  #
  # Implementations handle any runtime-specific decompression (e.g. .zst) so
  # callers always receive a plain String suitable for storage and parsing.
  #
  # @param path [String] a transcript file path
  # @return [String] the decoded file contents
  def read(path)
    raise NotImplementedError, "#{self.class}#read"
  end

  # Parse an already-read serialized transcript into raw event hashes.
  #
  # "Raw events" are the runtime's native per-record objects (for Claude, one
  # parsed JSONL object per line). The normalizer turns these into canonical
  # envelopes; this method only deals with the wire format.
  #
  # @param serialized [String] serialized transcript content
  # @return [Array<Hash>] one hash per record; malformed records are dropped
  def parse_events(serialized)
    raise NotImplementedError, "#{self.class}#parse_events"
  end

  # Read and parse a transcript file into raw event hashes.
  #
  # @param path [String] a transcript file path
  # @return [Array<Hash>] one hash per record (see #parse_events)
  def read_events(path)
    parse_events(read(path))
  end

  # Discover subagent transcript files for a session.
  #
  # Runtimes without a subagent concept (e.g. Codex) return an empty array.
  #
  # @param working_directory [String] the cwd the runtime was spawned from
  # @param session_id [String, nil] the runtime session id, when known
  # @return [Array<String>] subagent transcript file paths (possibly empty)
  def discover_subagent_files(working_directory:, session_id: nil)
    raise NotImplementedError, "#{self.class}#discover_subagent_files"
  end

  # Directories/paths where this runtime writes MCP server logs.
  #
  # Pure path computation (no IO); callers glob/read within these paths.
  #
  # @param working_directory [String] the cwd the runtime was spawned from
  # @return [Array<String>] MCP log base paths (possibly empty)
  def mcp_log_paths(working_directory:)
    raise NotImplementedError, "#{self.class}#mcp_log_paths"
  end

  protected

  attr_reader :file_system
end
