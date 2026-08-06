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

  # Find the main (non-subagent) transcript file inside a directory.
  #
  # Declared here rather than only on the concrete sources because
  # TranscriptPollerService calls it on every poll: a source that implements
  # only the rest of this interface would otherwise NoMethodError on its first
  # poll instead of failing loudly at the seam (#56).
  #
  # @param transcript_directory [String] the session's transcript directory
  # @param session [Session] the session whose transcript we want
  # @return [String, nil] the main transcript file path, or nil if not found
  def find_main_transcript(transcript_directory:, session:)
    raise NotImplementedError, "#{self.class}#find_main_transcript"
  end

  # Read the decoded, secret-redacted transcript bytes for a path.
  #
  # Redaction sits here because this is where transcript bytes are pulled off
  # disk. **Anything that persists transcript content must come through here**,
  # not through a bare `File.read` — the manual-refresh paths in
  # SessionsController, Api::V1::SessionsController and Mcp::Tools::ActionSession
  # all route through it for exactly that reason. A raw read at any of them
  # writes an unredacted transcript over the redacted one the poller stored, and
  # (because the refresh paths compare stored content to file content) leaves the
  # two writers overwriting each other on every pass.
  #
  # See TranscriptRedactor for what is and is not covered.
  #
  # Redaction preserves line count exactly, so the poller's regression and
  # rotation arithmetic is unaffected.
  #
  # @param path [String] a transcript file path
  # @return [String] the decoded, redacted file contents
  def read(path)
    TranscriptRedactor.redact(read_raw(path))
  end

  # Read the raw, decoded transcript bytes for a path, before redaction.
  #
  # Implementations handle any runtime-specific decompression (e.g. .zst) so
  # callers always receive a plain String suitable for storage and parsing.
  # Call #read, not this — this exists for subclasses to implement.
  #
  # @param path [String] a transcript file path
  # @return [String] the decoded file contents
  def read_raw(path)
    raise NotImplementedError, "#{self.class}#read_raw"
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

  # Does this runtime abandon its transcript file and start a new one when a
  # session continues after a failed resume?
  #
  # The answer decides how TranscriptPollerService reads a transcript that is
  # SHORTER than the stored one. There are two incompatible causes for that:
  #
  #   * A runtime that resumes into one canonical file (Claude Code) only
  #     shortens it when the file itself was lost — a recreated clone. The stored
  #     transcript is the same conversation, so the shorter file must be refused
  #     and the on-disk copy repaired before resuming (see
  #     AgentSessionJob#restore_regressed_transcript_if_needed).
  #   * A runtime with an append-only, per-run transcript store (Codex rollouts)
  #     never truncates a file at all. A shorter read therefore means the poller
  #     is now looking at a DIFFERENT, newer file, and its events are new
  #     conversation the user has not seen — not history to be discarded.
  #
  # @return [Boolean] true when a shorter read means "new file", not "lost file"
  def rotates_transcript_files?
    raise NotImplementedError, "#{self.class}#rotates_transcript_files?"
  end

  protected

  attr_reader :file_system
end
