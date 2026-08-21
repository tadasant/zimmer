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

  # Where transcripts live. A class method because the backfill records the root
  # it swept on its run row, and a coverage claim has to name the corpus it
  # covers.
  def self.default_root = ENV["TRANSCRIPT_ROOT"].presence || File.join(Dir.home, ".claude", "projects")

  Result = Struct.new(:files_scanned, :session_rows, :adhoc_rows, :feature_rows, :skipped_lines, keyword_init: true) do
    def total_rows = session_rows + adhoc_rows
    def to_s
      "files=#{files_scanned} session_rows=#{session_rows} adhoc_rows=#{adhoc_rows} " \
      "feature_rows=#{feature_rows} skipped=#{skipped_lines}"
    end
  end

  # @param root [String] the projects directory to scan
  # @param modified_since [Time, nil] only scan files touched since this time.
  #   nil scans everything, which is what the backfill wants.
  # @param logger [Logger]
  # @param attribute_features [Boolean] also estimate which context-management
  #   feature each request's tokens paid for. Costs a full JSON parse of every
  #   transcript line rather than just the assistant ones, which is why it is a
  #   flag: a run that only wants the totals back can skip it.
  def initialize(root: self.class.default_root, modified_since: nil, attribute_features: true, logger: Rails.logger)
    @root = root
    @modified_since = modified_since
    @attribute_features = attribute_features
    @logger = logger
  end

  def call
    result = Result.new(files_scanned: 0, session_rows: 0, adhoc_rows: 0, feature_rows: 0, skipped_lines: 0)
    return result unless File.directory?(@root)

    session_batch = []
    adhoc_batch = []
    feature_batch = []

    each_transcript_file do |path|
      result.files_scanned += 1
      attribution = attribute(path)
      # Feature attribution is only meaningful for agent sessions. Zimmer's own
      # `claude -p` calls carry none of the context-management machinery this
      # measures, so scanning them for it would only cost time.
      features = ContextFeatureAttributor.new if @attribute_features && attribution[:kind] == :session

      rows_by_request = {}
      scan_file(path, features: features) do |record|
        if attribution[:kind] == :session
          row = session_row(record, attribution, path)
          rows_by_request[record[:request_id]] = row
          session_batch << row
        else
          adhoc_batch << adhoc_row(record, attribution, path)
        end
      end

      feature_batch.concat(feature_rows(features, rows_by_request)) if features

      # Parents FIRST, always: `token_usage_features.request_id` carries a foreign
      # key to `session_token_usages.request_id`, so a feature row whose parent is
      # not yet written would be rejected.
      if session_batch.size >= BATCH_SIZE || feature_batch.size >= BATCH_SIZE
        result.session_rows += flush(SessionTokenUsage, session_batch)
        result.feature_rows += flush(TokenUsageFeature, feature_batch, unique_by: %i[request_id feature])
        session_batch = []
        feature_batch = []
      end
      if adhoc_batch.size >= BATCH_SIZE
        result.adhoc_rows += flush(AdhocTokenUsage, adhoc_batch)
        adhoc_batch = []
      end
    end

    result.session_rows += flush(SessionTokenUsage, session_batch)
    result.feature_rows += flush(TokenUsageFeature, feature_batch, unique_by: %i[request_id feature])
    result.adhoc_rows += flush(AdhocTokenUsage, adhoc_batch)
    result
  end

  private

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
  def scan_file(path, features: nil)
    seen = Set.new

    File.foreach(path) do |line|
      # Cheap pre-filter: most lines in a transcript are user turns, tool results,
      # and metadata, and none of them carries a `usage` object. Feature
      # attribution is the exception — it has to see the user turns too, because
      # the goal block, the tool results and the skill bodies it measures live
      # there — so it opts into the full parse.
      next unless features || line.include?('"type":"assistant"')

      begin
        entry = JSON.parse(line)
      rescue JSON::ParserError
        next
      end

      features&.observe(entry)
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

  # HeadlessInferenceService has two call sites — SessionTitleJob and the push
  # notification summary — and the transcript does not say which one ran. They
  # share one honest label rather than being guessed at; splitting them needs
  # instrumentation at the call site, which is a separate change.
  def headless_source(_path) = "headless_inference"

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
      # The LINE's own session id wins over the file's. Forking copies the source
      # session's transcript verbatim into the fork's clone directory under a new
      # filename (ForkSessionService#write_transcript_file), and those copied lines
      # keep the ORIGINAL `requestId` and `sessionId`. Attributing by file would
      # credit the parent's whole pre-fork spend to the fork — and then, because
      # `request_id` is unique and first writer wins, silently drop those same rows
      # when the parent's own file is scanned. Keying on the line says which runtime
      # session actually made the call, which is the thing we mean.
      session_id: session_id_for(record[:runtime_session_id]) || attribution[:session_id],
      agent_root: attribution[:agent_root],
      transcript_path: real_path(path),
      created_at: Time.current,
      updated_at: Time.current
    )
  end

  def adhoc_row(record, attribution, path)
    record.except(:runtime_session_id, :subagent).merge(
      source: attribution[:source],
      transcript_path: real_path(path),
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

  # Attribution rows for the requests this file actually contributed, stamped with
  # the same denormalized axes as their parent so a by-feature rollup needs no
  # join. A row whose parent was not stored — a line with no `requestId`, or one
  # whose volumes were all zero — is dropped rather than orphaned.
  def feature_rows(features, rows_by_request)
    now = Time.current

    features.rows.filter_map do |row|
      parent = rows_by_request[row[:request_id]]
      next unless parent

      row.merge(
        session_id: parent[:session_id],
        agent_root: parent[:agent_root],
        model: parent[:model],
        subagent: parent[:subagent],
        called_at: parent[:called_at],
        created_at: now,
        updated_at: now
      )
    end
  end

  # `insert_all` with a conflict target makes re-ingestion a no-op rather than an
  # error, which is what lets the recurring job and a backfill run at once.
  def flush(klass, rows, unique_by: :request_id)
    return 0 if rows.empty?

    # `returning` gives the rows actually written, so the count reports NEW
    # spend rather than lines re-read. On a steady-state run most of a file is
    # already stored and the honest answer is usually zero.
    klass.insert_all(rows, unique_by: unique_by, returning: [ :id ]).rows.size
  end

  # The backfill reads through a directory of symlinks so it can control how much
  # the scanner sees at a time, and that scratch directory is gone by the time
  # anyone reads the row. Store where the transcript actually lives — first writer
  # wins on `request_id`, so a row written with a dead pointer never gets corrected.
  def real_path(path)
    File.realpath(path)
  rescue SystemCallError
    path
  end
end
