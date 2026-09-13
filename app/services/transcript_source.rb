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

  # The directory under which this runtime creates ONE transcript directory per
  # distinct working directory, named by a pure function of that working
  # directory — i.e. the root a sweeper may enumerate, where every child is
  # attributable to the cwd that produced it.
  #
  # nil is the default and means "not laid out that way", which is a refusal to
  # be swept rather than a missing implementation:
  #
  #   * CodexTranscriptSource writes every session into ONE date-partitioned
  #     tree that ignores the cwd entirely, so its children are not attributable
  #     and deleting one would take other sessions' rollouts with it.
  #   * PiTranscriptSource writes inside the clone, so its transcripts are
  #     already deleted by the clone's own removal and there is nothing left over
  #     to reap.
  #
  # Only ClaudeTranscriptSource answers non-nil (~/.claude/projects), and that is
  # why OrphanTranscriptDirectoryCleanupJob can sweep it: the directory name is
  # `File.basename(transcript_directory(working_directory:))`, so a child can be
  # tied back to a working directory that still exists — or found to have none.
  #
  # @return [String, nil] the enumerable root, or nil when there is not one
  def per_working_directory_transcript_root
    nil
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

  # The runtime's own session id for the process running right now, read from a
  # side channel rather than from the transcript.
  #
  # Runtimes that mint their own id (Codex) publish it before the transcript is
  # findable: `codex exec --json` prints `thread.started` with the thread UUID on
  # the first line of stdout, and that UUID is what names the rollout file. Being
  # told it means #locate can ask for the right file instead of inferring which
  # of the shared tree's rollouts belongs to this session, and means resume has a
  # target even if the rollout is never located at all.
  #
  # nil — the default, and the answer for every runtime whose stored session_id
  # is already authoritative (Claude, Pi) — means "no side channel, use the
  # transcript", which is what TranscriptPollerService did before there was one.
  #
  # @param session [Session] the session whose runtime id we want
  # @param working_directory [String, nil] the cwd the runtime was spawned from
  # @return [String, nil] the runtime session id, or nil when unknowable here
  def runtime_session_id(session:, working_directory: nil)
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

  # The runtime session uuid a located transcript is named by, when this
  # conversation was **re-keyed** mid-flight: the located file opens with a copy
  # of the transcript Zimmer recorded at spawn and carries on under a different
  # uuid, leaving <session_id>.jsonl behind (#1047).
  #
  # `locate` already follows that branch, so this answers a different question —
  # whether the file it returned carries the whole of what Zimmer stored, or only
  # the part that existed when the copy was taken. The poller needs the
  # difference: the events the abandoned file recorded after the copy survive
  # nowhere else.
  #
  # nil — the default, and the answer whenever nothing re-keyed — means "the
  # located file is the conversation Zimmer already knows about". It is also the
  # right answer for runtimes whose transcript filename is not a session uuid at
  # all (Codex names rollouts `rollout-<timestamp>-<uuid>.jsonl` and rotates them
  # by design; that is #rotates_transcript_files?, a different mechanism).
  #
  # @param session [Session] the session whose transcript was located
  # @param transcript_path [String, nil] the located transcript path
  # @return [String, nil] the branch uuid, or nil when there is no re-key
  def rekeyed_branch_id(session:, transcript_path:)
    nil
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
  # not through a bare `File.read` — the manual refresh (Sessions::RefreshTranscript,
  # behind the web UI's, the REST API's and MCP's refreshes) routes through it for
  # exactly that reason. A raw read there writes an unredacted transcript over the
  # redacted one the poller stored, and (because a bulk refresh compares stored
  # content to file content) leaves the two writers overwriting each other on
  # every pass.
  #
  # See TranscriptRedactor for what is and is not covered.
  #
  # Redaction preserves line count exactly, so the poller's regression and
  # rotation arithmetic is unaffected.
  #
  # It runs through TranscriptRedactionCache rather than calling
  # TranscriptRedactor directly. The poller re-reads this path every few seconds
  # for the life of the session, and redacting the whole file each time cost
  # ~7.6 s of CPU per poll on a 32 MB transcript to re-derive last poll's answer
  # for everything but the appended tail (#477). The cache reuses the redacted
  # prefix and scans only the new bytes; the result is byte-identical to a full
  # re-scan, and a file that was truncated, rotated or rewritten falls back to
  # one.
  #
  # @param path [String] a transcript file path
  # @return [String] the decoded, redacted file contents
  def read(path)
    TranscriptRedactionCache.redact(path, read_raw(path))
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

  # Does this runtime's transcript record, in structured form, the error each
  # turn ended on?
  #
  # When it does, the recovery services ask #terminal_turn_error which recovery
  # path a dead turn belongs to, instead of pattern-matching the transcript
  # themselves. Codex and Pi both answer yes. The default is no, which is
  # Claude Code's answer: its API-error envelope is read by the recovery services
  # directly, because they predate this seam.
  #
  # @return [Boolean]
  def records_turn_errors?
    false
  end

  # The error the runtime recorded for the turn it most recently finished, read
  # from the session's transcript — or nil when that turn did not end on one, or
  # the transcript cannot be found.
  #
  # The returned object answers #id (stable per failed turn), #kind, #recognized?,
  # #message, #http_status and #rate_limited?, and may answer #quota_reading.
  #
  # #kind names the recovery path that owns the error, and the vocabulary is the
  # runtime's own rather than a fixed enum: a service matches the kinds it can act
  # on and ignores the rest, so a runtime with no recovery for a condition names
  # it something no service looks for instead of lying. CodexTurnError answers
  # :context_length, :quota, :auth, :retryable and :unclassified; PiTurnError
  # answers :retryable, :unclassified and three `_terminal` kinds that are
  # deliberate dead ends. #recognized? is the one answer every implementation
  # must agree on: false means "no page-worthy classifier knew this", and it is
  # what decides whether a dead turn reaches UnclassifiedFailureReporter.
  #
  # @param session [Session]
  # @param working_directory [String, nil] the cwd the runtime was spawned from
  # @return [Object, nil]
  def terminal_turn_error(session:, working_directory:)
    nil
  end

  protected

  attr_reader :file_system
end
