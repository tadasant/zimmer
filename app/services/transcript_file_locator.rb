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
#
# Selection by name is not quite enough on its own, because a transcript can be
# **re-keyed**: a file named by one uuid opens with a verbatim copy of this
# session's conversation and then carries on under a different uuid. Preferring
# the recorded name when that copy is the file being written means polling a
# conversation that stopped — silently, for as long as the session runs (#1047).
# So the recorded file competes with any sibling proved to be a continuation of
# this same conversation, and the most recently written of them wins. See
# #branch_transcripts for what "proved" means and why mtime alone is not it.
#
# Zimmer produces that shape itself, and the one sighting behind #1047 was an
# instance of it: ForkSessionService writes the source's stored transcript to the
# FORK's <session_id>.jsonl, so a fork's file opens under the source's id. That is
# a different conversation owned by a different Session row, which is why
# #branch_transcripts excludes it rather than following it. What is left is the
# same shape with no Session row behind it — a runtime that re-keys its own
# transcript in place — against which selection by name has no defence at all.
class TranscriptFileLocator
  # Filesystem mtimes are not necessarily as precise as the database timestamp
  # they are compared against — some filesystems store whole seconds — so a
  # transcript written in the same second the session row was created can read as
  # fractionally older than it. The floor exists to exclude a previous occupant's
  # transcript, which is older by minutes at least, so it can afford to give up a
  # second rather than risk hiding a live session's own file.
  MTIME_GRANULARITY_GRACE = 1.second

  # How many leading lines are scanned for a `sessionId` when asking whether a
  # file continues this session's conversation.
  #
  # A re-keyed branch opens with a copy of this session's own transcript, so the
  # first `sessionId` in it is ours. The window exists only because a transcript
  # can open with lines that carry none (a `summary` record), and it is small
  # because this is a head read on a file that may be tens of megabytes — never a
  # full parse.
  BRANCH_HEAD_SCAN_LINES = 20

  # Find the main transcript file for a session
  #
  # @param session [Session] The session to find the transcript for
  # @param transcript_dir [String] The directory containing transcript files
  # @param file_system [FileSystemAdapter] Optional file system adapter for testing
  # @return [String, nil] The path to the main transcript file, or nil if not found
  def self.find_main_transcript(session, transcript_dir, file_system: nil)
    file_system ||= DefaultFileSystem.new

    if session.session_id.present?
      live = live_transcript(session, transcript_dir, file_system)
      return live if live
    end

    fallback_transcript(session, transcript_dir, file_system)
  end

  # The uuid naming `path`, when `path` is a re-keyed branch of this session's
  # conversation rather than the recorded <session_id>.jsonl.
  #
  # nil for the recorded file, and — deliberately — nil for any other file that
  # does not carry this session's id in its head. The pre-session_id fallback can
  # return a file this locator never established an identity for, and a caller
  # that spliced *that* onto the stored transcript would be grafting on a
  # conversation Zimmer has no evidence belongs here.
  #
  # @param session [Session]
  # @param path [String, nil] a located transcript path
  # @param file_system [FileSystemAdapter] Optional file system adapter for testing
  # @return [String, nil] the branch uuid, or nil when `path` is not a branch
  def self.rekeyed_branch_id(session, path, file_system: nil)
    return nil if path.blank? || session.session_id.blank?

    branch_id = File.basename(path, ".jsonl")
    return nil if branch_id == session.session_id

    file_system ||= DefaultFileSystem.new
    return nil unless continues_session?(session, path, file_system)

    branch_id
  end

  # The recorded <session_id>.jsonl, unless the runtime re-keyed this
  # conversation and is writing the continuation elsewhere in the same directory.
  #
  # nil means neither exists, which hands the caller back to the fallback.
  def self.live_transcript(session, transcript_dir, file_system)
    recorded = File.join(transcript_dir, "#{session.session_id}.jsonl")

    candidates = branch_transcripts(session, transcript_dir, recorded, file_system)
    # Appended last so it wins an mtime tie: the recorded name stays the default
    # answer, and a branch has to be strictly more recently written to displace it.
    candidates << recorded if file_system.exists?(recorded)

    return nil if candidates.empty?
    return candidates.first if candidates.one?

    candidates.each_with_index.max_by { |path, index| [ file_system.mtime(path), index ] }.first
  end
  private_class_method :live_transcript

  # Siblings named by some other uuid whose head is this session's own
  # conversation — the shape a re-key takes on disk.
  #
  # Identity is established from **content**, never from mtime: a candidate only
  # qualifies if its head declares `sessionId == session.session_id`. That is the
  # evidence #1047 used to tie the branch to its session, and requiring it is what
  # keeps this from decaying into the broad "newest .jsonl wins" rule the fallback
  # above is deliberately narrow to avoid.
  #
  # A uuid some other Session row already holds is excluded outright, because a
  # **fork** has exactly this shape: its transcript is copied verbatim from its
  # source, so its early lines carry the SOURCE session's id. A fork that ran in
  # this working directory is a different conversation, not this one's
  # continuation, and following it would show a session its own child's work.
  def self.branch_transcripts(session, transcript_dir, recorded, file_system)
    candidates = file_system.glob(File.join(transcript_dir, "*.jsonl"))
      .reject { |path| path == recorded || File.basename(path).start_with?("agent-") }
    return [] if candidates.empty?

    candidates = candidates.select { |path| continues_session?(session, path, file_system) }
    return [] if candidates.empty?

    owned = Session.where(session_id: candidates.map { |path| File.basename(path, ".jsonl") }).pluck(:session_id)
    candidates.reject { |path| owned.include?(File.basename(path, ".jsonl")) }
  end
  private_class_method :branch_transcripts

  # Does this file open with this session's conversation?
  def self.continues_session?(session, path, file_system)
    head_session_id(path, file_system) == session.session_id
  end
  private_class_method :continues_session?

  # The first `sessionId` in the file's head, or nil when the head names none.
  #
  # Reads line by line and stops at the first answer, so a 30 MB transcript costs
  # one line. Any read or parse problem answers nil: this decides whether to
  # *widen* selection beyond the recorded name, so failing to read a candidate
  # must leave today's answer standing rather than propagate an exception through
  # the poll.
  def self.head_session_id(path, file_system)
    scanned = 0
    result = nil

    file_system.each_line(path) do |line|
      scanned += 1
      result = parsed_session_id(line)
      break if result.present? || scanned >= BRANCH_HEAD_SCAN_LINES
    end

    result.presence
  rescue StandardError => e
    Rails.logger.debug { "[TranscriptFileLocator] Could not read transcript head #{path}: #{e.message}" }
    nil
  end
  private_class_method :head_session_id

  def self.parsed_session_id(line)
    # each_line reads in binary mode, so the line arrives as ASCII-8BIT; JSON is
    # UTF-8 by definition and the parser is entitled to assume it.
    parsed = JSON.parse(line.dup.force_encoding(Encoding::UTF_8))
    parsed.is_a?(Hash) ? parsed["sessionId"] : nil
  rescue JSON::ParserError, EncodingError
    nil
  end
  private_class_method :parsed_session_id

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
    floor = session.created_at&.-(MTIME_GRANULARITY_GRACE)
    candidates = candidates.select { |path| file_system.mtime(path) >= floor } if floor

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

    def each_line(path, &block)
      File.foreach(path, mode: "rb", &block)
    end
  end
end
