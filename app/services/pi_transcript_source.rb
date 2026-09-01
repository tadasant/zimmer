# frozen_string_literal: true

# TranscriptSource for the Pi coding agent runtime.
#
# Pi writes one JSONL file per session. Left to itself it puts that file in a
# host-global tree partitioned by working directory
# (`~/.pi/agent/sessions/--<path>--/<timestamp>_<uuid>.jsonl`), but it also
# accepts an explicit `--session-dir`. PiRuntimeAdapter passes one, pointing at:
#
#   <working_directory>/.pi/sessions/
#
# That single choice is worth stating plainly, because it removes a bug class the
# Codex source has to defend against. Codex writes every session's rollout into
# one shared tree, so CodexTranscriptSource must disambiguate candidates by the
# cwd recorded inside each file — otherwise two concurrent sessions read each
# other's transcripts. A Zimmer clone path is unique per session, so a per-clone
# session directory makes that collision impossible by construction: the only
# transcripts in this directory are this session's.
#
# It also makes restore trivial. Pi resolves `--session-id` by scanning the
# session directory for a file carrying that id, regardless of the file's NAME.
# So Zimmer can write the stored transcript back to one deterministic path
# (#resume_transcript_path) and Pi picks it up and continues appending to its
# leaf — the single-file restore Codex cannot support.
#
# Each line is a standalone JSON object: a `{"type":"session",...}` header
# followed by tree entries carrying `id`/`parentId`. Pi has no subagent concept,
# so there are never nested transcript files.
class PiTranscriptSource < TranscriptSource
  # Session directory relative to the clone. Shares the `.pi/` parent with the
  # `.pi/skills/` tree `air prepare pi` writes.
  SESSION_DIR_RELATIVE_PATH = File.join(".pi", "sessions")

  # The filename Zimmer restores a stored transcript to. Pi looks a session up by
  # the id INSIDE the file, not by filename, so a fixed name is safe and makes
  # the restore path deterministic.
  RESTORED_TRANSCRIPT_FILENAME = "zimmer_session.jsonl"

  # Pi's own naming convention for a session file it created itself:
  # `<ISO-ish timestamp>_<uuid>.jsonl`.
  def self.session_directory(working_directory:)
    return nil if working_directory.blank?

    File.join(working_directory, SESSION_DIR_RELATIVE_PATH)
  end

  # @see TranscriptSource#transcript_directory
  def transcript_directory(working_directory:)
    self.class.session_directory(working_directory: working_directory)
  end

  # @see TranscriptSource#resume_transcript_path
  #
  # Pi CAN be restored from a single deterministic path, unlike Codex: it locates
  # a session by the id recorded in the file's header rather than by filename, so
  # writing the stored bytes here and passing `--session-id` continues the same
  # conversation.
  def resume_transcript_path(session:, working_directory:)
    return nil unless session&.session_id.present?

    dir = transcript_directory(working_directory: working_directory)
    return nil unless dir

    File.join(dir, RESTORED_TRANSCRIPT_FILENAME)
  end

  # @see TranscriptSource#locate
  def locate(session:, working_directory:)
    transcript_dir = transcript_directory(working_directory: working_directory)
    return nil unless transcript_dir
    return nil unless file_system.directory?(transcript_dir)

    find_main_transcript(transcript_directory: transcript_dir, session: session)
  end

  # Find the session JSONL for a session within its per-clone session directory.
  #
  # Zimmer mints the session id and passes it to Pi as `--session-id`, so the id
  # is known from the very first spawn — there is no "before the runtime minted
  # its id" window of the kind CodexTranscriptSource has to cope with. Two shapes
  # can carry it:
  #
  #   * `<timestamp>_<session_id>.jsonl` — the file Pi created itself.
  #   * `zimmer_session.jsonl`           — the file Zimmer restored (see
  #     #resume_transcript_path). Its NAME carries no id; its header does.
  #
  # Most-recently-modified wins among matches, so a live file is preferred over a
  # stale one. Returning nil means "not written yet", which the poller treats as
  # a waiting state.
  #
  # A file belonging to a DIFFERENT session cannot appear here — the directory
  # lives inside this session's clone — so unlike the Codex source there is no
  # cwd-matching fallback, and none is needed.
  #
  # @param transcript_directory [String] this session's per-clone session directory
  # @param session [Session] the session whose transcript we want
  # @return [String, nil] the transcript path, or nil if none found
  def find_main_transcript(transcript_directory:, session:)
    return nil if session&.session_id.blank?

    named = file_system.glob(File.join(transcript_directory, "*_#{session.session_id}.jsonl"))
    restored = restored_transcript_matching(transcript_directory, session.session_id)

    most_recent(named + restored)
  end

  # @see TranscriptSource#read_raw
  #
  # Pi session files are plain UTF-8 JSONL — no compression to unwrap.
  def read_raw(path)
    file_system.read(path)
  end

  # @see TranscriptSource#parse_events
  #
  # One JSON object per line; malformed lines are dropped.
  #
  # The log-level split mirrors CodexTranscriptSource#parse_events, and for the
  # same operational reason: a parse failure during live polling is expected and
  # self-resolving, while the Zimmer error-logs alert pages on any single
  # production `.error` line.
  #
  #   * A line with no trailing newline is the final record still being flushed
  #     by a live `pi` process. The poller re-reads moments later and parses it
  #     cleanly — benign and common, so `.info`.
  #   * A line that DOES carry its terminator and still fails to parse is a
  #     genuine data oddity worth surfacing once, so `.warn`. Neither pages.
  def parse_events(serialized)
    return [] unless serialized.present?

    serialized.lines.map do |line|
      stripped = line.strip
      next nil if stripped.empty?

      begin
        JSON.parse(stripped)
      rescue JSON::ParserError => e
        if line.end_with?("\n")
          Rails.logger.warn "[PiTranscriptSource] Dropping malformed session line: #{e.message}"
        else
          Rails.logger.info "[PiTranscriptSource] Skipping partially-flushed final session line: #{e.message}"
        end
        nil
      end
    end.compact
  end

  # @see TranscriptSource#discover_subagent_files
  #
  # Pi has no subagent/Task concept, so there are never nested session files.
  def discover_subagent_files(working_directory:, session_id: nil)
    []
  end

  # @see TranscriptSource#mcp_log_paths
  #
  # Pi's MCP support comes from the pi-mcp-adapter extension, which surfaces
  # server diagnostics in its own `/mcp` panel and on the CLI's stderr rather
  # than as per-server log files. Returning empty disables file-based MCP log
  # polling for Pi, exactly as it is disabled for Codex.
  def mcp_log_paths(working_directory:)
    []
  end

  # @see TranscriptSource#rotates_transcript_files?
  #
  # False, for the same reason it is false for Claude Code: Pi resumes into ONE
  # canonical file. `--session-id` targets an existing session tree and appends
  # to its leaf, so the file only ever grows. A shorter read therefore means the
  # file was LOST (a recreated clone), not that a newer file took over — so the
  # shorter read must be refused and the on-disk copy repaired, which is what
  # returning false makes AgentSessionJob do.
  def rotates_transcript_files?
    false
  end

  private

  # The restored-transcript file, but only when its header carries this session's
  # id.
  #
  # The filename is fixed, so it cannot identify the session on its own. A clone
  # recreated for a DIFFERENT session would leave a file at the same path, and
  # returning it unchecked would show one session another's conversation — the
  # Codex bug, reintroduced by the back door. Reading the header closes that.
  #
  # Only the first line is materialized, never the whole transcript.
  def restored_transcript_matching(transcript_directory, session_id)
    path = File.join(transcript_directory, RESTORED_TRANSCRIPT_FILENAME)
    return [] unless file_system.exists?(path)
    return [] unless header_session_id(path) == session_id

    [ path ]
  end

  # The session id Pi stamped on the file's header (its first JSONL line).
  # Returns nil when the line is missing, unparseable, or carries no id.
  def header_session_id(path)
    first_line = file_system.read(path).to_s.lines.find { |line| line.strip.present? }
    return nil if first_line.blank?

    JSON.parse(first_line)["id"]
  rescue => e
    Rails.logger.warn "[PiTranscriptSource] Failed to read session id from #{path}: #{e.message}"
    nil
  end

  def most_recent(paths)
    return nil if paths.empty?

    paths.max_by { |p| file_system.mtime(p) }
  end
end
