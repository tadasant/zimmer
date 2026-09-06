# frozen_string_literal: true

require "json"
require "zstd-ruby"

# Reads token usage out of Codex rollouts and writes it to `session_token_usages`.
#
# The third `usage_ingestor_class` — TokenUsageIngestionService is Claude Code's
# and PiTokenUsageIngestionService is Pi's — and the one whose format supplies
# the least. Three properties of a rollout decide the whole design, and each of
# them is a fact about Codex rather than a choice made here.
#
# WHERE THE ROLLOUTS ARE
#
# `~/.codex/sessions/YYYY/MM/DD/rollout-<timestamp>-<uuid>.jsonl`, resolved
# through CodexHome so this reads exactly the tree the spawned `codex` wrote to.
# That is four levels and date-partitioned, where the Claude scanner globs two
# and flat — and a finished rollout is Zstandard-compressed in place to
# `.jsonl.zst`, so most of the corpus is not even a text file. Both extensions
# are read; `zstd-ruby` is already a dependency (CodexTranscriptSource decompresses
# the same files to display them), so nothing new is pulled in to do it.
#
# WHY THE TURN DELTA AND NOT THE RUNNING TOTAL
#
# A rollout reports tokens on an `event_msg` line whose payload type is
# `token_count`, and it reports them twice:
#
#   "info": { "total_token_usage": { ...cumulative for the whole rollout... },
#             "last_token_usage":  { ...just this turn... } }
#
# One row per API call is what the table means, so `last_token_usage` is what is
# recorded. Summing the deltas is also the MORE complete of the two readings, not
# merely the more convenient one: on rollout
# `019ffff8-…` the cumulative counter freezes across a context compaction while
# `last_token_usage` still reports the 21,983 tokens the summarization itself
# spent, so the running total ends 21,983 short of the sum of its own deltas.
# Recording the cumulative figure would also make every re-ingest a re-count of
# the whole session unless the key encoded the total, which is the trap this
# format sets.
#
# WHY THE REQUEST ID IS SYNTHESISED — AND KEYED ON THE TIMESTAMP
#
# Claude Code stamps each call with the API's own `requestId` and Pi mints an
# entry id for every entry. A `token_count` event carries NEITHER: no request id,
# no turn id, no event id, nothing but the envelope's timestamp. So the key is
# built:
#
#   codex:<rollout uuid>:<event timestamp>
#
# The rollout uuid is globally unique (it names the file and `codex exec resume`
# takes it), and within one rollout the millisecond timestamp separates turns
# that are seconds apart in practice. The obvious alternative — the event's
# ordinal position in the file — was rejected because it is not stable under a
# dropped line: one unparseable record in the middle of a rollout would shift
# every later ordinal by one and re-ingest the entire remainder of the session as
# new spend. A timestamp is a property of the event, so a neighbouring line
# cannot move it.
#
# `DUPLICATE_SUFFIX` covers the only case the timestamp alone does not: two
# `token_count` events sharing a millisecond. They are then numbered in file
# order (`…#1`, `…#2`), which is deterministic for an append-only file and is why
# a re-run over the same rollout writes nothing.
#
# THE MODEL IS NOT ON THE EVENT
#
# It is on `turn_context` (payload `model`), emitted at the head of each turn,
# and on the `thread_settings_applied` event Codex writes when settings are
# (re)applied. Both are tracked as the model IN FORCE, carried forward, so a
# rollout whose model changes mid-session attributes each turn to the model that
# actually served it. A `token_count` event that arrives before either has been
# seen is SKIPPED and counted — `session_token_usages.model` is NOT NULL and
# guessing a model would put a wrong rate on real volume, which is the one thing
# TokenPricing refuses to do.
#
# COST, HONESTLY
#
# Volumes land; money currently does not. `TokenPricing` carries Anthropic rates
# only, so a `gpt-5.6-terra` row prices at $0 and appears in the Costs page's
# unpriced-models list. That is the existing, deliberate behaviour for a model
# with no rate — visibly unpriced beats silently mis-priced — and it is a strict
# improvement on the runtime being absent from the ledger altogether. See
# docs/src/content/docs/limitations.md.
class CodexTokenUsageIngestionService
  RUNTIME = "codex"

  # Namespaces the synthesised key so a Codex row can never be mistaken for — or
  # collide with — an Anthropic `requestId` or a Pi entry key.
  REQUEST_ID_PREFIX = "codex"

  # Appended when two `token_count` events share a millisecond, numbered in file
  # order from the second one.
  DUPLICATE_SUFFIX = "#"

  BATCH_SIZE = 500

  # Bound the working set when streaming `.zst` decompression, matching
  # CodexTranscriptSource::ZST_CHUNK_BYTES.
  ZST_CHUNK_BYTES = 256 * 1024

  # `rollout-<timestamp>-<uuid>.jsonl` / `.jsonl.zst`. The uuid is the thread id
  # `codex exec resume` takes and the one Zimmer stores in `sessions.session_id`.
  ROLLOUT_FILENAME = /\Arollout-.*?-(?<uuid>[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})\.jsonl(\.zst)?\z/

  # Where rollouts live. A class method for the same reason Claude's is: a sweep
  # that claims coverage has to be able to name the corpus it covered.
  def self.default_root = CodexHome.sessions_path

  Result = Struct.new(:files_scanned, :session_rows, :skipped_events, keyword_init: true) do
    def to_s
      "runtime=codex files=#{files_scanned} session_rows=#{session_rows} skipped=#{skipped_events}"
    end
  end

  # @param root [String] the Codex sessions tree to scan
  # @param modified_since [Time, nil] only read rollouts touched since this time.
  #   nil reads the whole corpus, which is what the one-time historical sweep
  #   (db/post_deploy) wants and what the recurring cron must not do.
  # @param paths [Array<String>, nil] restrict the sweep to these rollout files.
  #   The historical task walks the corpus in path order so it can hand the worker
  #   thread back between batches; the cron passes nil and takes the window.
  # @param logger [Logger]
  def initialize(root: self.class.default_root, modified_since: nil, paths: nil, logger: Rails.logger)
    @root = root
    @modified_since = modified_since
    @paths = paths
    @logger = logger
  end

  def call
    result = Result.new(files_scanned: 0, session_rows: 0, skipped_events: 0)
    batch = []

    each_rollout do |path|
      result.files_scanned += 1
      batch.concat(rows_for(path, result))

      if batch.size >= BATCH_SIZE
        result.session_rows += flush(batch)
        batch = []
      end
    end

    result.session_rows += flush(batch)
    result
  end

  # Every rollout under a root, newest date partition last. Public so the
  # post-deploy sweep can page the corpus without re-implementing the glob — the
  # list it walks and the list a cron run walks have to be the same list.
  #
  # @return [Array<String>] absolute paths, sorted
  def self.rollout_paths(root: default_root)
    return [] unless File.directory?(root)

    (Dir.glob(File.join(root, "**", "rollout-*.jsonl")) +
     Dir.glob(File.join(root, "**", "rollout-*.jsonl.zst"))).sort
  end

  private

  def each_rollout
    paths = @paths || self.class.rollout_paths(root: @root)

    paths.each do |path|
      # `stat` in its own rescue rather than around the yield, for the reason
      # #each_line spells out: a rescue that spans the block catches the block's
      # exceptions too, and the block below reaches the database.
      next unless within_window?(path)
      yield path
    end
  end

  # One row per `token_count` event in a rollout.
  def rows_for(path, result)
    uuid = uuid_from_filename(path)
    # The model in force, carried forward across turns.
    active_model = nil
    cwd = nil
    attribution = nil
    now = Time.current
    seen = Hash.new(0)
    rows = []

    each_line(path) do |line|
      # Cheap pre-filter, the same trade the Claude scanner makes: a rollout is
      # mostly reasoning and tool output, and parsing all of it to find a handful
      # of `token_count` events would make the historical sweep several times
      # slower for nothing. Every string below is a payload/type discriminator
      # Codex writes verbatim.
      next unless line.include?("token_count") ||
                  line.include?("turn_context") ||
                  line.include?("thread_settings_applied") ||
                  line.include?("session_meta")

      begin
        event = JSON.parse(line)
      rescue JSON::ParserError
        # Not counted as a skipped EVENT: a rollout being written right now ends
        # in a half-flushed line, which is expected rather than lossy — the next
        # sweep reads it whole. CodexTranscriptSource makes the same call.
        next
      end
      next unless event.is_a?(Hash)

      payload = event["payload"]
      payload = {} unless payload.is_a?(Hash)

      case event["type"]
      when "session_meta"
        uuid = payload["id"].presence || payload["session_id"].presence || uuid
        cwd ||= payload["cwd"].presence
        next
      when "turn_context"
        active_model = payload["model"].presence || active_model
        cwd ||= payload["cwd"].presence
        next
      when "event_msg"
        case payload["type"]
        when "thread_settings_applied"
          settings = payload["thread_settings"]
          active_model = settings["model"].presence || active_model if settings.is_a?(Hash)
          next
        when "token_count"
          # fall through
        else
          next
        end
      else
        next
      end

      info = payload["info"]
      usage = info["last_token_usage"] if info.is_a?(Hash)

      # REFUSED, not silently dropped, and this is the shape that makes the
      # distinction matter. Codex CLI 0.45.0 wrote the counts flat on the payload
      # (`{"type":"token_count","input_tokens":1200,…}`) with no `info` wrapper
      # and no total/last split — see test/fixtures/files/codex_rollout.jsonl,
      # which is that vintage. Those figures are the session's RUNNING TOTAL, so
      # reading them as a per-turn delta would multiply an old rollout's spend by
      # roughly the number of turns in it. Counting the skip is what stops a sweep
      # of an all-0.45.0 corpus from reporting `rows_written: 0, skipped: 0` —
      # indistinguishable, on /health, from a corpus that genuinely spent nothing.
      unless usage.is_a?(Hash)
        skip(result, "#{path}: a token_count event carries no info.last_token_usage — a pre-0.46 " \
                     "rollout reports a cumulative total with no per-turn delta, which cannot be " \
                     "keyed or summed safely")
        next
      end

      volumes = extract_volumes(usage)
      next if volumes.values_at(:input_tokens, :output_tokens,
                                :cache_read_tokens, :cache_creation_tokens).all?(&:zero?)

      called_at = parse_time(event["timestamp"])
      # The timestamp IS the dedup key, so an event without one has no key that
      # survives a re-run. Refuse rather than fall back to the file mtime, which
      # changes when the rollout is compressed and would re-ingest the event.
      if called_at.nil?
        skip(result, "#{path}: a token_count event carries no timestamp, so it has no stable dedup key")
        next
      end
      if uuid.nil?
        skip(result, "#{path}: neither the filename nor the session_meta line carries a rollout uuid")
        next
      end
      if active_model.nil?
        skip(result, "#{path}: no model in force yet — no turn_context or thread_settings_applied " \
                     "preceded this token_count event")
        next
      end

      attribution ||= attribute(uuid, cwd)

      rows << volumes.merge(
        request_id: request_id_for(uuid, event["timestamp"], seen),
        session_id: attribution[:session_id],
        agent_root: attribution[:agent_root],
        agent_runtime: RUNTIME,
        runtime_session_id: uuid,
        model: active_model,
        # Codex has no subagent concept and reports no server-tool request
        # counters on the event, so these three are constants rather than
        # readings. A web search shows up as its own `web_search_end` event with
        # no billing figure attached.
        subagent: false,
        web_search_requests: 0,
        web_fetch_requests: 0,
        called_at: called_at,
        transcript_path: real_path(path),
        created_at: now,
        updated_at: now
      )
    end

    rows
  end

  # `codex:<rollout uuid>:<timestamp>`, plus a file-order suffix for the two
  # events that share a millisecond. `seen` counts occurrences so the suffix is a
  # function of the rollout's own contents rather than of when it was read.
  def request_id_for(uuid, timestamp, seen)
    base = "#{REQUEST_ID_PREFIX}:#{uuid}:#{timestamp}"
    n = seen[base]
    seen[base] = n + 1
    n.zero? ? base : "#{base}#{DUPLICATE_SUFFIX}#{n}"
  end

  # Codex's `TokenUsage` onto the table's columns.
  #
  #   input_tokens             → the TOTAL prompt, cached and written parts included
  #   cached_input_tokens      → cache_read_tokens
  #   cache_write_input_tokens → cache_creation_tokens
  #   output_tokens            → output_tokens (`reasoning_output_tokens` is a
  #                              SUBSET of it, not extra volume — Codex's own
  #                              `total_tokens` is exactly input + output)
  #
  # `input_tokens` is stored NET of the other two, because that is what the column
  # means everywhere else: Anthropic reports `input_tokens` excluding cache reads
  # and creations, and TokenPricing charges the three at three different rates.
  # Codex follows OpenAI, where the prompt total INCLUDES its cached part — so
  # subtracting is what stops a cached token being billed twice, once at the input
  # rate and again at the cache-read rate, and what keeps the row's four volumes
  # adding back up to the `total_tokens` the rollout reported.
  #
  # `cache_write_input_tokens` is subtracted on the same reasoning even though it
  # is zero on every rollout in this deployment's corpus. It sits beside
  # `cached_input_tokens` in the same struct, so the conservative reading is that
  # it is a subset of the prompt in the same way; treating it as extra volume
  # would inflate `total_tokens` on the day it first arrives non-zero, silently.
  # Both are clamped: the subtraction is arithmetic on data, and a volume is never
  # negative.
  def extract_volumes(usage)
    prompt = count(usage["input_tokens"])
    cached = count(usage["cached_input_tokens"]).clamp(0, prompt)
    cache_write = count(usage["cache_write_input_tokens"]).clamp(0, prompt - cached)

    {
      input_tokens: prompt - cached - cache_write,
      output_tokens: count(usage["output_tokens"]),
      cache_read_tokens: cached,
      cache_creation_tokens: cache_write,
      # Codex reports no TTL alongside the cache-write figure, so the split is left
      # at zero and TokenPricing charges the whole amount at its unsplit rate —
      # the same treatment a pre-`cache_creation` Claude line gets.
      cache_creation_5m_tokens: 0,
      cache_creation_1h_tokens: 0
    }
  end

  # A token count out of a rollout, which is DATA and not a schema. Total rather
  # than `.to_i` for the reason Pi's ingestor gives: `.to_i` raises NoMethodError
  # on the Hash a malformed `info` could hold, and that exception would escape
  # the per-line parse rescue and take every remaining rollout in the run with
  # it. One odd event should cost one event.
  def count(value)
    return 0 unless value.is_a?(Numeric) || value.is_a?(String)

    [ value.to_i, 0 ].max
  rescue StandardError
    0
  end

  # Which Zimmer session this rollout's spend belongs to, and under which root.
  #
  # Two strategies, and neither covers the corpus alone — the same shape the
  # Claude path has, for the same reason:
  #
  #   1. The rollout uuid. Codex mints its own thread id and Zimmer captures it
  #      into `sessions.session_id` (CodexTranscriptSource#runtime_session_id),
  #      so it is an exact key. It misses a session whose capture never landed —
  #      a spawn that died early, a resume that fresh-started into a new rollout.
  #   2. The `cwd` Codex stamps on `session_meta` and `turn_context`. That is the
  #      session's clone path (plus the agent root's subdirectory), and a clone is
  #      created per session, so its basename identifies the session for every
  #      rollout written from it. This is the same `clone_path LIKE` lookup
  #      TokenUsageIngestionService uses, reached from a real path instead of a
  #      sanitized directory name.
  #
  # A rollout that matches neither is still ingested with a null session — spend
  # that happened is still spend, and the Costs page shows it as unattributed
  # rather than losing it.
  def attribute(uuid, cwd)
    by_uuid = session_by_uuid(uuid)
    return by_uuid if by_uuid

    by_clone = session_by_clone(cwd)
    return by_clone if by_clone

    { session_id: nil, agent_root: agent_root_from_cwd(cwd) }
  end

  # Cached: a sweep re-reads the same handful of clones across many rollouts, and
  # a corpus walk would otherwise issue one query per file.
  def session_by_uuid(uuid)
    return nil if uuid.blank?

    @by_uuid ||= {}
    @by_uuid.fetch(uuid) do
      @by_uuid[uuid] = session_row(Session.where(session_id: uuid))
    end
  end

  def session_by_clone(cwd)
    basename = clone_basename(cwd)
    return nil if basename.nil?

    @by_clone ||= {}
    @by_clone.fetch(basename) do
      # Escaped, unlike TokenUsageIngestionService's otherwise identical lookup:
      # that one is handed a directory name Zimmer sanitized itself, while this one
      # comes out of a file on disk. `_` is a single-character wildcard and `%`
      # matches everything, so an unescaped `cwd` could match a session that is not
      # this one — and `pick` would then attribute the spend to whichever row the
      # planner returned first.
      pattern = "%/#{ActiveRecord::Base.sanitize_sql_like(basename)}"
      @by_clone[basename] = session_row(Session.where("metadata->>'clone_path' LIKE ?", pattern))
    end
  end

  def session_row(scope)
    row = scope.pick(:id, Arel.sql("metadata->>'agent_root_key'"))
    return nil unless row

    { session_id: row.first, agent_root: row.last }
  end

  # `/home/rails/.zimmer/clones/<repo>-<branch>-<epoch>-<hash>[/subdir…]` → the
  # clone directory's basename. nil for a cwd outside the clones tree, which is
  # what a rollout written by a `codex` run Zimmer did not spawn looks like.
  def clone_basename(cwd)
    return nil if cwd.blank?

    parts = cwd.to_s.split("/")
    index = parts.index("clones")
    return nil if index.nil?

    parts[index + 1].presence
  end

  # The agent root for a rollout whose session could not be resolved, read off
  # the same cwd. `metadata->>'agent_root_key'` is preferred wherever a session
  # was found; this is the fallback that keeps an unattributed row out of the
  # by-root rollup's "unknown" bucket when the path already says which root ran.
  def agent_root_from_cwd(cwd)
    return nil if cwd.blank?

    match = %r{/artifacts/agent-roots/(?<root>[^/]+)}.match(cwd.to_s)
    match && match[:root]
  end

  # Is this rollout inside the lookback window? A file that vanished between the
  # glob and the `stat` — a rollout compressed in place mid-sweep is the ordinary
  # way — is skipped rather than raising.
  def within_window?(path)
    return true if @modified_since.nil?

    File.mtime(path) >= @modified_since
  rescue SystemCallError => e
    @logger.warn("[CodexTokenUsageIngestion] #{path}: #{e.message}")
    false
  end

  def uuid_from_filename(path)
    match = ROLLOUT_FILENAME.match(File.basename(path.to_s))
    match && match[:uuid]
  end

  def parse_time(raw)
    return nil if raw.blank?
    Time.zone.parse(raw.to_s)
  rescue ArgumentError
    nil
  end

  # Stream a rollout line by line, decompressing `.zst` as it goes.
  #
  # Streamed rather than read whole because the corpus is the argument for it:
  # the largest rollout on this deployment is 1.7 MB of JSONL whose single
  # longest line is most of a system prompt, and a historical sweep visits every
  # one of them. Holding one decoded chunk plus one line beats holding a whole
  # decompressed transcript per file.
  # THE RESCUES BELONG TO THE READ, NOT TO THE BLOCK. The caller's block issues
  # database queries (session attribution), and a rescue around the whole
  # `yield` would catch their exceptions too — including the two that
  # TokenUsageIngestionJob and TokenUsageBackfillJob go out of their way to
  # re-raise. `GoodJob::InterruptError` and `ActiveRecord::StatementTimeout` are
  # both StandardError, so swallowing them here would silently disable
  # `discard_interrupt_quietly` and `retry_on ... attempts: 5` for this runtime
  # alone: a deploy landing mid-sweep would drop the rest of a rollout, log one
  # `warn`, and let the post-deploy cursor advance past it. So the file-level
  # rescues sit inside the readers, around the I/O only.
  def each_line(path, &block)
    if path.to_s.end_with?(".zst")
      each_zst_line(path, &block)
    else
      each_plain_line(path, &block)
    end
  end

  def each_plain_line(path)
    io = File.open(path, "r")
  rescue SystemCallError => e
    @logger.warn("[CodexTokenUsageIngestion] #{path}: #{e.message}")
  else
    begin
      while (line = read_line(io, path))
        yield line
      end
    ensure
      io.close
    end
  end

  # One line, or nil at EOF / on a read error. Split out so the rescue covers the
  # read and not the block the caller runs on the result.
  def read_line(io, path)
    io.gets
  rescue SystemCallError, IOError => e
    @logger.warn("[CodexTokenUsageIngestion] #{path}: #{e.message}")
    nil
  end

  def each_zst_line(path)
    stream = Zstd::StreamingDecompress.new
    buffer = +""
    io = begin
      File.open(path, "rb")
    rescue SystemCallError => e
      @logger.warn("[CodexTokenUsageIngestion] #{path}: #{e.message}")
      return
    end

    begin
      loop do
        # A corrupt or truncated `.zst` costs its own file and no other. `warn`
        # rather than `error`: a half-written compressed rollout is a data
        # oddity, not a broken system, and the error-log alert pages on `.error`.
        chunk = begin
          io.read(ZST_CHUNK_BYTES)
        rescue SystemCallError, IOError => e
          @logger.warn("[CodexTokenUsageIngestion] #{path}: #{e.message}")
          nil
        end
        break if chunk.nil?

        decoded = begin
          # `force_encoding`, not `encode`: a multibyte character can straddle a
          # chunk boundary, so the tail of a decoded chunk may be an incomplete
          # sequence. Tagging the bytes and concatenating leaves the split
          # character to be completed by the next chunk — `String#<<` between two
          # UTF-8 strings is a byte concatenation with no transcode, and
          # `String#index` returns nil rather than raising on a broken tail.
          stream.decompress(chunk).force_encoding(Encoding::UTF_8)
        rescue StandardError => e
          @logger.warn("[CodexTokenUsageIngestion] #{path}: #{e.class}: #{e.message}")
          break
        end

        buffer << decoded
        while (index = buffer.index("\n"))
          yield buffer.slice!(0..index)
        end
      end
    ensure
      io.close
    end

    yield buffer unless buffer.empty?
  end

  # One skipped event, counted and said out loud. The counter alone tells an
  # operator that something was dropped and nothing about what; `warn` does not
  # page.
  def skip(result, reason)
    result.skipped_events += 1
    @logger.warn("[CodexTokenUsageIngestion] skipped an event: #{reason}")
  end

  def real_path(path)
    File.realpath(path)
  rescue SystemCallError
    path
  end

  # Upsert, ignoring conflicts, so re-reading a rollout costs time and nothing
  # else — which is what lets the recurring sweep and the historical one overlap.
  # `returning` makes the count NEW spend rather than events re-read. Sliced, so
  # BATCH_SIZE is a real bound: the caller only checks the batch size between
  # files, and one long rollout arrives here whole.
  def flush(rows)
    return 0 if rows.empty?

    rows.each_slice(BATCH_SIZE).sum do |slice|
      SessionTokenUsage.insert_all(slice, unique_by: :request_id, returning: [ :id ]).rows.size
    end
  end
end
