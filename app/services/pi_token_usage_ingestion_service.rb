# frozen_string_literal: true

require "json"

# Reads token usage out of Pi session transcripts and writes it to
# `session_token_usages`.
#
# The sibling of TokenUsageIngestionService, which does the same job for Claude
# Code. Two things about Pi make it a separate implementation rather than a
# widened one, and both are properties of the runtime rather than of this code.
#
# WHY NOT THE FILESYSTEM
#
# TokenUsageIngestionService scans `~/.claude/projects`, a host-global tree that
# outlives every clone. Pi is the one runtime whose conversation is NOT in its
# home: PiRuntimeAdapter passes `--session-dir <clone>/.pi/sessions`, so the
# transcript lives inside the clone and CloneReaper takes it with the clone. A
# scanner pointed at the clones directory would therefore see only sessions whose
# clone happens to still exist, and would lose a session's whole spend the moment
# it was archived — the exact opposite of what a ledger is for.
#
# `sessions.transcript` is the durable copy. TranscriptPollerService writes the
# raw Pi JSONL there on every poll, it survives reaping and archival, and it makes
# the historical sweep a `WHERE agent_runtime = 'pi'` rather than a corpus walk.
# It is the redacted copy — TranscriptSource#read runs it through
# TranscriptRedactionCache — which costs nothing here: redaction is
# line-decomposable and rewrites only string values that look like secrets, so
# every `usage` number and every entry id arrives intact.
#
# WHY THE REQUEST ID IS SYNTHESISED
#
# Claude Code stamps each API call with the API's own `requestId`, globally
# unique, and the whole table is keyed on it. Pi records `responseId` (an
# OpenRouter generation id) on assistant messages, but not on the other three
# entry shapes that carry usage — a compaction, a branch summary and a tool
# result can each report tokens with no provider id attached — and Pi's own
# documented `AssistantMessage` type does not promise it either.
#
# What every usage-bearing entry does carry is the entry `id` Pi mints for it,
# which is unique within a session tree and only 8 hex characters wide. So the
# key is the session tree's UUID and the entry id together:
#
#   pi:<pi session uuid>:<entry id>
#
# Globally unique (the session uuid is one Zimmer minted), stable across
# re-ingestion, and — the case that matters — stable across a FORK.
# ForkSessionService copies the source's transcript into the fork verbatim,
# entry ids and session header included, so the copied prefix generates exactly
# the keys the source already wrote and `insert_all` drops it. Without the
# session half of the key, two sessions' 8-hex ids would collide on the unique
# index at a few tens of thousands of rows and spend would silently vanish.
class PiTokenUsageIngestionService
  RUNTIME = "pi"

  # Namespaces the synthesised key so a Pi row can never be mistaken for — or
  # collide with — an Anthropic `requestId`.
  REQUEST_ID_PREFIX = "pi"

  BATCH_SIZE = 500

  # Entry types Pi can attach a `usage` object to. Everything else is skipped
  # before the JSON is even looked at for tokens.
  #
  # `message` covers both the assistant turns and the tool results that report
  # nested LLM work; `compaction` and `branch_summary` are the summary
  # generations Pi's own footer totals include alongside them.
  USAGE_BEARING_TYPES = %w[message compaction branch_summary].freeze

  Result = Struct.new(:sessions_scanned, :session_rows, :skipped_entries, keyword_init: true) do
    def to_s
      "runtime=pi sessions=#{sessions_scanned} session_rows=#{session_rows} skipped=#{skipped_entries}"
    end
  end

  # @param modified_since [Time, nil] only read sessions touched since this time.
  #   nil reads every Pi session, which is what the one-time historical sweep
  #   (db/post_deploy) wants and what the recurring job must not do.
  # @param session_ids [Array<Integer>, nil] restrict the sweep to these sessions.
  #   The historical task walks the corpus in id order so it can hand the worker
  #   thread back between batches; the cron passes nil and takes the window.
  # @param logger [Logger]
  def initialize(modified_since: nil, session_ids: nil, logger: Rails.logger)
    @modified_since = modified_since
    @session_ids = session_ids
    @logger = logger
  end

  def call
    result = Result.new(sessions_scanned: 0, session_rows: 0, skipped_entries: 0)
    batch = []

    each_session do |session|
      result.sessions_scanned += 1

      # One transcript in memory at a time. `sessions.transcript` is the largest
      # column in the schema — gigabytes across the table — so it is fetched per
      # session rather than selected into a batch of records.
      raw = Session.where(id: session[:id]).pick(:transcript)
      next if raw.blank?

      batch.concat(rows_for(session, raw.to_s, result))

      if batch.size >= BATCH_SIZE
        result.session_rows += flush(batch)
        batch = []
      end
    end

    result.session_rows += flush(batch)
    result
  end

  private

  # The Pi sessions in scope, without their transcripts.
  #
  # `agent_runtime` is indexed and Pi is a small share of the fleet, so the
  # lookback is applied on top of an already narrow relation rather than being
  # asked to carry the query. `metadata->>'agent_root_key'` is read straight out
  # of the JSON column, exactly as Session.running_claude_code_burn_keys does:
  # the value it holds ("zimmer", "general-agent") is the same shape
  # TokenUsageIngestionService derives from a Claude clone directory name, so the
  # by-root rollup adds the two runtimes together without special-casing either.
  def each_session
    scope = Session.where(agent_runtime: RUNTIME).where.not(transcript: nil)
    scope = scope.where(updated_at: @modified_since..) if @modified_since
    scope = scope.where(id: @session_ids) if @session_ids

    scope.pluck(
      :id,
      :session_id,
      :created_at,
      Arel.sql("metadata->>'agent_root_key'")
    ).each do |id, session_id, created_at, agent_root|
      yield({ id: id, session_id: session_id, created_at: created_at, agent_root: agent_root })
    end
  end

  # One row per usage-bearing entry in a Pi session file.
  def rows_for(session, raw, result)
    header_id = nil
    # The model in force, carried forward across entries. Pi records
    # provider/model on an assistant message but NOT on a compaction or branch
    # summary, and `model` is NOT NULL on the table — so a summary generation is
    # attributed to the model that was selected when it ran, which is the model
    # that generated it.
    active_model = nil
    now = Time.current
    seen = Set.new
    rows = []
    attribution = nil

    raw.each_line do |line|
      next if line.strip.empty?

      begin
        entry = JSON.parse(line)
      rescue JSON::ParserError => e
        skip(result, "unparseable line: #{e.message}")
        next
      end
      next unless entry.is_a?(Hash)

      case entry["type"]
      when "session"
        header_id ||= entry["id"].presence
        next
      when "model_change"
        active_model = model_id(entry["provider"], entry["modelId"]) || active_model
        next
      end

      next unless USAGE_BEARING_TYPES.include?(entry["type"])

      message = entry["message"]
      message = {} unless message.is_a?(Hash)
      active_model = model_id(message["provider"], message["model"]) || active_model

      # Deliberately the entry's OWN usage, never a nested one. A modern
      # compaction entry carries `retainedTail` — a materialized copy of the
      # assistant messages kept after compaction, each with the `usage` object it
      # was already recorded with. Walking into it would count those calls twice.
      #
      # The `compactionSummary` message is the same checkpoint in its other
      # shape, and needs no guard: Pi derives it in memory from the compaction
      # entry (`sessionEntryToContextMessages`) rather than appending it, and
      # `createCompactionSummaryMessage` builds it with no `usage` field at all,
      # so it cannot reach the line below even if a future version persists it.
      usage = message["usage"] || entry["usage"]
      next unless usage.is_a?(Hash)

      volumes = extract_volumes(usage)
      next if volumes.values_at(:input_tokens, :output_tokens,
                                :cache_read_tokens, :cache_creation_tokens).all?(&:zero?)

      entry_id = entry["id"].presence
      namespace = header_id.presence || session[:session_id].presence
      # No entry id means no safe dedup key, and a row that cannot be deduped
      # would be re-counted on every sweep. Pi mints one for every entry it
      # appends, so this is a malformed line rather than a shape to support.
      if entry_id.nil?
        skip(result, "entry carries no id, so it has no safe dedup key")
        next
      end
      # An 8-hex entry id is nowhere near unique on its own, so a key with an
      # empty namespace would collapse every such session into one 32-bit space —
      # exactly the collision the composite key exists to prevent. Unreachable
      # while a transcript opens with its header, but `sessions.session_id` IS
      # nullable (AgentSessionJob clears it on recovery paths), so refuse rather
      # than rely on that.
      if namespace.nil?
        skip(result, "neither the transcript header nor the session row carries a session id")
        next
      end
      if active_model.nil?
        skip(result, "no model in force yet — no assistant message or model_change preceded this entry")
        next
      end

      request_id = "#{REQUEST_ID_PREFIX}:#{namespace}:#{entry_id}"
      next unless seen.add?(request_id)

      attribution ||= attribute(header_id, session)

      rows << volumes.merge(
        request_id: request_id,
        session_id: attribution[:session_id],
        agent_root: attribution[:agent_root],
        agent_runtime: RUNTIME,
        runtime_session_id: namespace,
        model: active_model,
        # Pi has no subagent concept, and no server-side tool that bills per
        # request, so these three are constants rather than readings.
        subagent: false,
        web_search_requests: 0,
        web_fetch_requests: 0,
        called_at: parse_time(entry["timestamp"]) || session[:created_at] || now,
        # Left null on purpose: the durable copy of a Pi transcript is
        # `sessions.transcript`, and the clone path it was read from is gone by
        # the time anyone reads this row.
        transcript_path: nil,
        created_at: now,
        updated_at: now
      )
    end

    rows
  end

  # Which Zimmer session this transcript's spend belongs to.
  #
  # The transcript header's own id wins over the row we happened to read it from,
  # for the reason TokenUsageIngestionService prefers a line's `sessionId` over
  # its file's: a forked Pi session's stored transcript opens with the SOURCE
  # session's header, so attributing by the row would credit the source's whole
  # pre-fork spend to the fork.
  def attribute(header_id, session)
    own = { session_id: session[:id], agent_root: session[:agent_root] }
    return own if header_id.blank? || header_id == session[:session_id]

    # Cached across sessions: a source and every fork of it share one header, so
    # a run over a family of forks asks once. Only a HIT is cached — a header
    # that resolves to nothing falls back to the session in hand, and that answer
    # is different for each of them.
    @by_header ||= {}
    return @by_header[header_id] if @by_header.key?(header_id)

    row = Session.where(session_id: header_id).pick(:id, Arel.sql("metadata->>'agent_root_key'"))
    return own unless row

    @by_header[header_id] = { session_id: row.first, agent_root: row.last }
  end

  # Pi's `Usage` onto the table's columns.
  #
  #   input     → input_tokens
  #   output    → output_tokens          (`reasoning` is a subset of it, not extra
  #                                       volume — Pi's own `totalTokens` excludes
  #                                       it and its cost math never prices it)
  #   cacheRead → cache_read_tokens
  #   cacheWrite→ cache_creation_tokens, split 1h/5m
  #
  # THE SPLIT IS THE PRICING. TokenPricing charges an unsplit `cache_creation`
  # at the 1-hour rate (2x base input) because that is the conservative reading
  # of a Claude transcript line that predates the sub-object, and because 95% of
  # this deployment's Claude cache writes really are on the 1-hour TTL. Pi is the
  # other way round: `cacheWrite1h` is an explicit field, its own `calculateCost`
  # prices anything not in it at the SHORT rate (1.25x), and that is what the
  # provider billed. So a bare `cacheWrite` is recorded as a 5-minute write —
  # which is both what happened and what makes Zimmer's figure reproduce the cost
  # Pi recorded alongside it, to the cent.
  def extract_volumes(usage)
    cache_write = count(usage["cacheWrite"])
    write_1h = count(usage["cacheWrite1h"]).clamp(0, cache_write)

    {
      input_tokens: count(usage["input"]),
      output_tokens: count(usage["output"]),
      cache_read_tokens: count(usage["cacheRead"]),
      cache_creation_tokens: cache_write,
      cache_creation_5m_tokens: cache_write - write_1h,
      cache_creation_1h_tokens: write_1h
    }
  end

  # A token count out of a transcript, which is DATA and not a schema.
  #
  # Total on purpose rather than `.to_i`, which raises NoMethodError on the
  # Hash or Array a malformed `usage` could hold — and that exception would
  # escape the per-line parse rescue and take every REMAINING session in the run
  # with it. One odd entry should cost one entry. A negative count is floored
  # for the same reason: it is not a volume, and it would otherwise invert the
  # `clamp` range above into an ArgumentError.
  def count(value)
    return 0 unless value.is_a?(Numeric) || value.is_a?(String)

    [ value.to_i, 0 ].max
  rescue StandardError
    0
  end

  # One skipped entry, counted and said out loud. The counter alone tells an
  # operator that something was dropped and nothing about what, which is the
  # shape of a number nobody can act on; `warn` does not page.
  def skip(result, reason)
    result.skipped_entries += 1
    @logger.warn("[PiTokenUsageIngestion] skipped an entry: #{reason}")
  end

  # `<provider>/<model>`, which is the id ModelCatalog offers and the session
  # config stores ("openrouter/anthropic/claude-opus-4.6"). Storing the qualified
  # form rather than the bare model keeps the Costs page's by-model rollup honest
  # about which provider served the call — and TokenPricing's longest-family
  # match reads through it unchanged, so an `anthropic/claude-*` model prices at
  # the rate OpenRouter publishes for it.
  def model_id(provider, model)
    return nil if model.blank?
    return model.to_s if provider.blank?

    "#{provider}/#{model}"
  end

  def parse_time(raw)
    return nil if raw.blank?
    Time.zone.parse(raw.to_s)
  rescue ArgumentError
    nil
  end

  # Upsert, ignoring conflicts, so re-reading a transcript costs time and nothing
  # else — which is what lets the recurring sweep and the historical one overlap.
  # `returning` makes the count NEW spend rather than lines re-read.
  # Sliced, so BATCH_SIZE is a real bound rather than an approximate one: the
  # caller only checks the batch size between sessions, so a single very long
  # transcript arrives here whole.
  def flush(rows)
    return 0 if rows.empty?

    rows.each_slice(BATCH_SIZE).sum do |slice|
      SessionTokenUsage.insert_all(slice, unique_by: :request_id, returning: [ :id ]).rows.size
    end
  end
end
