# frozen_string_literal: true

require "json"

# Reads token usage out of runtime transcript files and writes it to the two
# usage tables.
#
# WHY A SCANNER AND NOT A HOOK IN THE POLLER
#
# TranscriptPollerService is a live-broadcast path: it runs inside AgentSessionJob
# while a session is running, and its job is to get new messages onto the user's
# screen. Hanging cost accounting off it would put a write on that hot path, and
# would still miss two populations entirely — sessions that finished before this
# feature existed (the backfill), and the app's own `claude -p` calls, which have
# no Session and therefore no poller. A standalone scanner covers all three from
# one code path, and can be re-run over any window without side effects.
#
# IDEMPOTENCE
#
# Every row is keyed on the API's `requestId`. Ingestion upserts and ignores
# conflicts, so re-scanning a file is free and the recurring job and the backfill
# can overlap without fighting. This is also the correctness fix: one API call is
# logged as SEVERAL assistant lines (separate thinking/text content blocks, and a
# full replay of prior history whenever a session resumes), and every one of them
# repeats the same `usage` object. Summing per line — or per line `uuid` —
# over-counts tokens by 79% on this deployment's corpus.
class TokenUsageIngestionService
  # Transcripts live under ~/.claude/projects/<sanitized-working-directory>/.
  # The sanitized directory name is the only evidence we have of what produced a
  # given transcript, so it is also how we route rows to a table.
  CLONE_DIR = /\A-home-rails--zimmer-clones-(?<repo_branch>.+?)-(?<epoch>\d{10})-(?<hash>[0-9a-f]{8})(?<subdir>.*)\z/
  AGENT_ROOT_PREFIX = "artifacts-agent-roots-"

  # `claude -p` runs in a mktmpdir named by NativeClaudePrintRunner.
  HEADLESS_DIR = /headless-inference/
  # CliStatusRefreshJob shells out from the app root, so its transcripts land in
  # the sanitized form of "/rails".
  CLI_PROBE_DIR = "-rails"

  BATCH_SIZE = 500

  Result = Struct.new(:files_scanned, :session_rows, :adhoc_rows, :skipped_lines, keyword_init: true) do
    def total_rows = session_rows + adhoc_rows
    def to_s
      "files=#{files_scanned} session_rows=#{session_rows} adhoc_rows=#{adhoc_rows} skipped=#{skipped_lines}"
    end
  end

  # @param root [String] the projects directory to scan
  # @param modified_since [Time, nil] only scan files touched since this time.
  #   nil scans everything, which is what the backfill wants.
  # @param logger [Logger]
  def initialize(root: default_root, modified_since: nil, logger: Rails.logger)
    @root = root
    @modified_since = modified_since
    @logger = logger
  end

  def call
    result = Result.new(files_scanned: 0, session_rows: 0, adhoc_rows: 0, skipped_lines: 0)
    return result unless File.directory?(@root)

    session_batch = []
    adhoc_batch = []

    each_transcript_file do |path|
      result.files_scanned += 1
      attribution = attribute(path)

      scan_file(path) do |record|
        if attribution[:kind] == :session
          session_batch << session_row(record, attribution, path)
        else
          adhoc_batch << adhoc_row(record, attribution, path)
        end
      end

      if session_batch.size >= BATCH_SIZE
        result.session_rows += flush(SessionTokenUsage, session_batch)
        session_batch = []
      end
      if adhoc_batch.size >= BATCH_SIZE
        result.adhoc_rows += flush(AdhocTokenUsage, adhoc_batch)
        adhoc_batch = []
      end
    end

    result.session_rows += flush(SessionTokenUsage, session_batch)
    result.adhoc_rows += flush(AdhocTokenUsage, adhoc_batch)
    result
  end

  private

  def default_root = File.join(Dir.home, ".claude", "projects")

  def each_transcript_file
    Dir.glob(File.join(@root, "*", "*.jsonl")).each do |path|
      next if @modified_since && File.mtime(path) < @modified_since
      yield path
    rescue SystemCallError => e
      @logger.warn("[TokenUsageIngestion] #{path}: #{e.message}")
    end
  end

  # Yields one hash per DISTINCT API call in the file. Deduping within the file
  # is not enough on its own — the same call recurs across resumed files too —
  # but it keeps the batch small, and the unique index is the real guarantee.
  def scan_file(path)
    seen = Set.new

    File.foreach(path) do |line|
      # Cheap pre-filter: most lines in a transcript are user turns, tool
      # results, and metadata. Parsing all of them would make a full backfill
      # several times slower for nothing.
      next unless line.include?('"type":"assistant"')

      begin
        entry = JSON.parse(line)
      rescue JSON::ParserError
        next
      end
      next unless entry["type"] == "assistant"

      message = entry["message"]
      next unless message.is_a?(Hash)

      model = message["model"]
      # `<synthetic>` marks a locally-generated error or interrupt notice. It
      # never hit the API and carries a zeroed usage block.
      next if model.blank? || model == "<synthetic>"

      usage = message["usage"]
      next unless usage.is_a?(Hash)

      request_id = entry["requestId"].presence
      # Without a requestId there is no safe dedup key, and the line is more
      # likely than not a replay of one we already have. Counting it would
      # inflate; the alternative (a uuid key) is what caused the 79% over-count.
      next if request_id.nil?
      next unless seen.add?(request_id)

      volumes = extract_volumes(usage)
      next if volumes.values_at(:input_tokens, :output_tokens,
                                :cache_read_tokens, :cache_creation_tokens).all?(&:zero?)

      called_at = parse_time(entry["timestamp"]) || File.mtime(path)

      yield volumes.merge(
        request_id: request_id,
        model: model,
        subagent: !!entry["isSidechain"],
        service_tier: usage["service_tier"],
        called_at: called_at,
        runtime_session_id: entry["sessionId"]
      )
    end
  rescue SystemCallError => e
    @logger.warn("[TokenUsageIngestion] #{path}: #{e.message}")
  end

  def extract_volumes(usage)
    creation = usage["cache_creation"]
    creation = {} unless creation.is_a?(Hash)
    server_tools = usage["server_tool_use"]
    server_tools = {} unless server_tools.is_a?(Hash)

    {
      input_tokens: usage["input_tokens"].to_i,
      output_tokens: usage["output_tokens"].to_i,
      cache_read_tokens: usage["cache_read_input_tokens"].to_i,
      cache_creation_tokens: usage["cache_creation_input_tokens"].to_i,
      cache_creation_5m_tokens: creation["ephemeral_5m_input_tokens"].to_i,
      cache_creation_1h_tokens: creation["ephemeral_1h_input_tokens"].to_i,
      web_search_requests: server_tools["web_search_requests"].to_i,
      web_fetch_requests: server_tools["web_fetch_requests"].to_i
    }
  end

  def parse_time(raw)
    return nil if raw.blank?
    Time.zone.parse(raw.to_s)
  rescue ArgumentError
    nil
  end

  # Decide which table a transcript's rows belong in, and what to label them.
  def attribute(path)
    dir = File.basename(File.dirname(path))

    return { kind: :adhoc, source: "cli_status_probe" } if dir == CLI_PROBE_DIR
    return { kind: :adhoc, source: headless_source(path) } if dir.match?(HEADLESS_DIR)

    match = CLONE_DIR.match(dir)
    return { kind: :adhoc, source: "unknown" } unless match

    {
      kind: :session,
      agent_root: agent_root_from(match),
      session_id: resolve_session(path: path, match: match)
    }
  end

  # Which Zimmer session produced this transcript file.
  #
  # Two strategies, because neither covers the corpus alone:
  #
  #   1. The filename. Claude Code writes the main transcript to
  #      `<session_id>.jsonl` and Zimmer supplies that id, so the stem is an
  #      exact key into `sessions.session_id`. Fast and unambiguous — but it does
  #      not cover `agent-*.jsonl` subagent files, and a resumed session can end
  #      up under a different uuid than the one Zimmer stored.
  #   2. The clone directory. A clone is created per session and its basename
  #      (`<repo>-<branch>-<epoch>-<hash>`) is unique, so a session whose
  #      `clone_path` ends with that basename is *the* session for every file in
  #      the directory — subagent transcripts included.
  #
  # Strategy 2 is cached per directory, which matters on a backfill: without it a
  # directory of forty subagent files would issue forty identical queries.
  def resolve_session(path:, match:)
    stem = File.basename(path, ".jsonl")
    unless stem.start_with?("agent-")
      by_runtime_id = session_id_for(stem)
      return by_runtime_id if by_runtime_id
    end

    session_id_for_clone("#{match[:repo_branch]}-#{match[:epoch]}-#{match[:hash]}")
  end

  def session_id_for_clone(clone_basename)
    @clone_sessions ||= {}
    @clone_sessions.fetch(clone_basename) do
      @clone_sessions[clone_basename] =
        Session.where("metadata->>'clone_path' LIKE ?", "%/#{clone_basename}").pick(:id)
    end
  end

  # HeadlessInferenceService has two call sites and the transcript does not say
  # which one it was. Both run Haiku-class one-shots; distinguishing them needs
  # instrumentation at the call site, which is a separate change. Until then they
  # share a source rather than being guessed at.
  def headless_source(_path) = "session_title"

  # `.../-artifacts-agent-roots-<root>` is an agent root; a clone with no
  # subdirectory is the repository itself.
  def agent_root_from(match)
    subdir = match[:subdir].to_s.sub(/\A-/, "")
    repo = match[:repo_branch].to_s.sub(/-main\z/, "")

    return repo if subdir.empty?
    return subdir.delete_prefix(AGENT_ROOT_PREFIX) if subdir.start_with?(AGENT_ROOT_PREFIX)

    "#{repo}/#{subdir}"
  end

  def session_row(record, attribution, path)
    record.merge(
      session_id: attribution[:session_id],
      agent_root: attribution[:agent_root],
      transcript_path: path,
      created_at: Time.current,
      updated_at: Time.current
    )
  end

  def adhoc_row(record, attribution, path)
    record.except(:runtime_session_id, :subagent).merge(
      source: attribution[:source],
      transcript_path: path,
      created_at: Time.current,
      updated_at: Time.current
    )
  end

  # Sessions store the runtime's own session uuid in `session_id`. Cached because
  # a backfill would otherwise issue the same lookup thousands of times.
  def session_id_for(runtime_session_id)
    return nil if runtime_session_id.blank?

    @session_ids ||= {}
    @session_ids.fetch(runtime_session_id) do
      @session_ids[runtime_session_id] = Session.where(session_id: runtime_session_id).pick(:id)
    end
  end

  # `insert_all` with a conflict target makes re-ingestion a no-op rather than an
  # error, which is what lets the recurring job and a backfill run at once.
  def flush(klass, rows)
    return 0 if rows.empty?

    # `returning` gives the rows actually written, so the count reports NEW
    # spend rather than lines re-read. On a steady-state run most of a file is
    # already stored and the honest answer is usually zero.
    klass.insert_all(rows, unique_by: :request_id, returning: [ :id ]).rows.size
  rescue ActiveRecord::ActiveRecordError => e
    @logger.error("[TokenUsageIngestion] #{klass.name} insert failed: #{e.message}")
    0
  end
end
