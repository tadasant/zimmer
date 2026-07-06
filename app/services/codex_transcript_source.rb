# TranscriptSource for the OpenAI Codex runtime.
#
# Codex CLI stores session transcripts ("rollouts") under a date-partitioned
# tree, independent of the working directory the agent was spawned from:
#
#   ~/.codex/sessions/YYYY/MM/DD/rollout-<timestamp>-<uuid>.jsonl
#
# Newer Codex versions compress finished rollouts to `rollout-*.jsonl.zst`
# (Zstandard). The session UUID is embedded in the filename and in the first
# JSONL line (`session_meta` payload `id`), and is what `codex resume <uuid>`
# expects.
#
# Each transcript line is a standalone JSON object (JSONL) wrapped in a
# `{ "timestamp", "type", "payload" }` envelope. Codex has no subagent concept,
# so there are never nested rollout files.
class CodexTranscriptSource < TranscriptSource
  require "zstd-ruby"
  require "stringio"

  # Bound the per-chunk working set when streaming `.zst` decompression so a
  # long rollout never forces the whole compressed buffer through the decoder
  # in a single allocation.
  ZST_CHUNK_BYTES = 256 * 1024

  # The base directory that holds every Codex rollout, across all dates.
  #
  # Resolved through the shared CodexHome resolver (honoring the CODEX_HOME env
  # override) so AO reads rollouts from exactly the directory the spawned `codex`
  # wrote them to. Codex ignores the spawn cwd when choosing where to write
  # rollouts, so `working_directory` is accepted for interface parity but unused.
  #
  # @see TranscriptSource#transcript_directory
  def transcript_directory(working_directory: nil)
    CodexHome.sessions_path
  rescue => e
    Rails.logger.error "[CodexTranscriptSource] Failed to compute transcript directory: #{e.message}"
    nil
  end

  # @see TranscriptSource#locate
  def locate(session:, working_directory: nil)
    transcript_dir = transcript_directory(working_directory: working_directory)
    return nil unless transcript_dir
    return nil unless file_system.directory?(transcript_dir)

    find_main_transcript(transcript_directory: transcript_dir, session: session)
  end

  # Find the rollout file for a session within the Codex sessions tree.
  #
  # Prefers the rollout whose filename carries the session's UUID. Among the
  # `.jsonl` (live) and `.jsonl.zst` (compressed) variants for one session the
  # most-recently-modified file wins, which keeps an in-progress uncompressed
  # rollout selected over a stale compressed sibling. When the runtime UUID is
  # not known yet, falls back to the rollout that belongs to this session's own
  # clone (see #fallback_transcript).
  #
  # @param transcript_directory [String] the Codex sessions base directory
  # @param session [Session] the session whose rollout we want
  # @return [String, nil] the rollout file path, or nil if none found
  def find_main_transcript(transcript_directory:, session:)
    if session.session_id.present?
      matches = rollout_glob(transcript_directory, session.session_id)
      return most_recent(matches) if matches.any?
    end

    fallback_transcript(transcript_directory, session)
  end

  # @see TranscriptSource#read
  #
  # Transparently decompresses `.zst` rollouts; `.jsonl` files are read as-is.
  # Returns a plain UTF-8 String suitable for storage and JSONL parsing.
  def read(path)
    return decompress_zst(file_system.binread(path)) if path.to_s.end_with?(".zst")

    file_system.read(path)
  end

  # @see TranscriptSource#parse_events
  #
  # One JSON object per line; malformed lines are dropped (a partially-flushed
  # final line during live polling is the common case).
  #
  # Log level is deliberately NOT `.error` here: a parse failure on a rollout
  # line is an expected, self-resolving condition during live polling, not
  # broken-system behavior, and the AO error-logs alert pages on any single
  # production `.error` line. We split the two cases:
  #
  #   * A line with no trailing newline is the final record still being flushed
  #     by a live `codex` process. The poller re-reads the file moments later
  #     once the write completes and parses it cleanly, so this is benign and
  #     common — log at `.info` and drop.
  #   * A line that DOES carry its terminator but still fails to parse is a
  #     genuine data oddity (truncated/corrupt complete record). That is worth
  #     surfacing once, so log at `.warn` — but it still must not page.
  #
  # The terminator heuristic has one deliberate blind spot: a corrupt complete
  # record that is also the very last line of a fully-flushed file carrying no
  # trailing newline is indistinguishable from a partial flush, so it lands in
  # the `.info` branch rather than `.warn`. Codex terminates every complete
  # record with a newline, so this is rare, and erring toward the benign
  # (non-paging) case is the correct trade-off for an alert-noise fix.
  def parse_events(serialized)
    return [] unless serialized.present?

    serialized.lines.map do |line|
      stripped = line.strip
      next nil if stripped.empty?

      begin
        JSON.parse(stripped)
      rescue JSON::ParserError => e
        if line.end_with?("\n")
          Rails.logger.warn "[CodexTranscriptSource] Dropping malformed rollout line: #{e.message}"
        else
          Rails.logger.info "[CodexTranscriptSource] Skipping partially-flushed final rollout line: #{e.message}"
        end
        nil
      end
    end.compact
  end

  # @see TranscriptSource#discover_subagent_files
  #
  # Codex has no subagent/Task concept, so there are never nested rollout files.
  def discover_subagent_files(working_directory:, session_id: nil)
    []
  end

  # @see TranscriptSource#mcp_log_paths
  #
  # Codex does not write per-server MCP log files the way Claude Code does (MCP
  # diagnostics surface on the CLI's stderr instead), so there are no log paths
  # to glob. Returning empty disables file-based MCP log polling for Codex.
  def mcp_log_paths(working_directory:)
    []
  end

  private

  # Select a rollout before this session's own Codex UUID has been captured.
  #
  # At spawn AO stores a randomly-minted placeholder `session_id` (Codex ignores
  # the AO-supplied id and generates its own UUID, captured later from the
  # rollout's `session_meta` line). Until that capture happens the placeholder
  # never matches a rollout filename, so we land here.
  #
  # Codex writes EVERY session's rollout into the same shared tree under
  # `$CODEX_HOME/sessions`. Picking "the most recent rollout anywhere" therefore
  # crosses session boundaries: when two Codex sessions run concurrently, this
  # session can latch onto the *other* session's actively-written rollout. That
  # poisons two things at once — the displayed transcript shows the wrong
  # session's content, and `capture_runtime_session_id!` then stores the foreign
  # UUID, so every later `codex exec resume` continues the wrong conversation.
  #
  # We instead select the most-recent rollout whose recorded `cwd` matches this
  # session's working directory. The clone path is unique per session, so
  # concurrent sessions can never collide. If this session's own rollout has not
  # appeared yet we return nil ("waiting") rather than borrowing another
  # session's — the poller treats nil as "not ready" and retries.
  #
  # @param transcript_directory [String] the Codex sessions base directory
  # @param session [Session] the session whose rollout we want
  # @return [String, nil] the rollout file path, or nil if none matches yet
  def fallback_transcript(transcript_directory, session)
    candidates = rollout_glob(transcript_directory, "*")
    return nil if candidates.empty?

    working_directory = session.metadata&.dig("working_directory")
    # Defensive: without a working directory we cannot disambiguate by clone, so
    # preserve the legacy most-recent behavior rather than returning nothing.
    return most_recent(candidates) if working_directory.blank?

    # Newest-first so the first cwd match short-circuits after reading as few
    # session_meta lines as possible (this session's live rollout is typically
    # the most recently modified once it exists).
    candidates.sort_by { |path| file_system.mtime(path) }.reverse_each do |path|
      return path if rollout_cwd(path) == working_directory
    end
    nil
  end

  # The working directory Codex stamped on a rollout's `session_meta` line (the
  # first JSONL record). Codex records the spawn cwd there, which uniquely
  # identifies the session's clone. Returns nil when the line is missing,
  # unparseable, or carries no cwd.
  #
  # Only the first line is materialized — never the whole rollout. The fallback
  # scan can probe many candidates per poll (every rollout in the shared tree
  # until this session's own appears), so decompressing an entire `.zst` just to
  # read line 1 would be wasteful exactly in the concurrent case this guards.
  def rollout_cwd(path)
    first_line = first_rollout_line(path)
    return nil if first_line.blank?

    event = JSON.parse(first_line)
    payload = event["payload"] || event
    payload["cwd"]
  rescue => e
    Rails.logger.warn "[CodexTranscriptSource] Failed to read cwd from #{path}: #{e.message}"
    nil
  end

  # Read just the first non-blank JSONL line of a rollout (the `session_meta`
  # record). For `.zst` rollouts the stream is decompressed only until the first
  # newline is seen, then abandoned, so a large finished rollout costs one chunk
  # rather than a full decode.
  def first_rollout_line(path)
    if path.to_s.end_with?(".zst")
      first_line_from_zst(file_system.binread(path))
    else
      file_system.read(path).to_s.lines.find { |line| line.strip.present? }
    end
  end

  # Stream-decompress a Zstandard buffer only until the first newline, returning
  # that first line. Falls back to whatever decoded if the buffer carries no
  # newline at all.
  def first_line_from_zst(compressed)
    return nil if compressed.nil? || compressed.empty?

    stream = Zstd::StreamingDecompress.new
    io = StringIO.new(compressed)
    out = +""
    while (chunk = io.read(ZST_CHUNK_BYTES))
      out << stream.decompress(chunk)
      if (newline_index = out.index("\n"))
        return out[0..newline_index].force_encoding(Encoding::UTF_8)
      end
    end
    out.empty? ? nil : out.force_encoding(Encoding::UTF_8)
  end

  # Glob every rollout (compressed or not) whose filename ends with the given
  # session id, anywhere in the date-partitioned tree.
  def rollout_glob(transcript_directory, session_id)
    file_system.glob(File.join(transcript_directory, "**", "rollout-*-#{session_id}.jsonl")) +
      file_system.glob(File.join(transcript_directory, "**", "rollout-*-#{session_id}.jsonl.zst"))
  end

  def most_recent(paths)
    return nil if paths.empty?

    paths.max_by { |p| file_system.mtime(p) }
  end

  # Stream-decompress a Zstandard buffer into a decoded String. The decoder is
  # fed in fixed-size chunks so the compressed buffer is not forced through in a
  # single pass for long-running sessions.
  def decompress_zst(compressed)
    return "" if compressed.nil? || compressed.empty?

    stream = Zstd::StreamingDecompress.new
    io = StringIO.new(compressed)
    out = +""
    while (chunk = io.read(ZST_CHUNK_BYTES))
      out << stream.decompress(chunk)
    end
    out.force_encoding(Encoding::UTF_8)
  rescue => e
    Rails.logger.error "[CodexTranscriptSource] Failed to decompress .zst rollout: #{e.message}"
    ""
  end
end
