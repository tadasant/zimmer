# frozen_string_literal: true

# Search session *transcripts* without handing the caller a gateway timeout.
#
# The problem this exists to solve
# --------------------------------
# `sessions.transcript` is a `json` column holding the entire conversation. There is
# no index an `ILIKE '%…%'` can use — a leading wildcard rules out a btree, and the
# only transcript-related index on the table is a partial index on `id`. So the
# predicate is a sequential scan that detoasts and decompresses every transcript it
# passes: on production that is thousands of sessions and gigabytes of TOAST.
#
# Run as one statement behind kamal-proxy's 30-second target timeout, that is a coin
# flip. It returned sub-second on a quiet box and `real 0m30.069s` under load — a 504
# with nothing in it for the caller to act on (#405). It was also, structurally, run
# *twice*: `Api::BaseController#paginate` calls `scope.count` before `scope.limit(…)`,
# and `per_page` reduces neither scan.
#
# What this does instead
# ----------------------
# 1. **Resolve candidates cheaply.** One id-only query over the caller's filters,
#    newest-first. No transcript is touched, so this costs the same as any other
#    listing.
# 2. **Scan the candidates in chunks**, newest-first, stopping the moment it has
#    `limit` matches. A search whose answer is recent stops after one chunk.
# 3. **Bound the whole thing by a wall-clock budget**, backed by a Postgres
#    `statement_timeout` so no single statement can outlive it either. When the budget
#    runs out the search returns *the matches it already has* plus a cursor, rather
#    than raising or timing out at the proxy.
# 4. **Hand back a keyset cursor** for the point it stopped at, so the caller can
#    resume and eventually cover the whole corpus across several calls. The cursor is
#    `(created_at, id)`, so sessions created between calls never shift it.
#
# There is deliberately no `count`. A total match count over the corpus costs a full
# scan by definition, which is the thing being avoided; callers get "complete" or
# "here is where to resume" instead of a number that cost more than the results.
#
# Why not an index
# ----------------
# Weighed and rejected for now, both stated so the next person does not re-derive it:
# a `pg_trgm` GIN index over `transcript::text` would be built over gigabytes of
# TOASTed text (staging measured 5,038 MB compressed across 5,096 sessions in #495) and
# would be a large multiple of the table it indexes; and `to_tsvector` refuses
# documents over 1 MB, which most transcripts exceed. Either would also have to be
# built and backfilled blind against a managed Postgres this repository's sessions
# cannot reach. Both remain open options once someone can measure them there — this
# class is what makes the surface work in the meantime, and nothing about it forecloses
# adding an index later.
class SessionContentSearch
  # Wall-clock ceiling for one search. Comfortably under kamal-proxy's 30-second
  # default target timeout, so the caller gets a real answer rather than a 504.
  DEFAULT_TIME_BUDGET_SECONDS = 20
  BUDGET_ENV = "ZIMMER_CONTENT_SEARCH_BUDGET_SECONDS"

  # Candidates per statement. Small enough that one chunk cannot spend the whole
  # budget, large enough that the round trips are noise next to the detoasting.
  DEFAULT_CHUNK_SIZE = 100
  CHUNK_SIZE_ENV = "ZIMMER_CONTENT_SEARCH_CHUNK_SIZE"

  DEFAULT_LIMIT = 25

  # Hard ceiling on the server-side statement_timeout, in milliseconds. The budget is
  # an operator-set env var rather than a request parameter, but the value is
  # interpolated into a `SET` (which takes no binds), so it is clamped to a literal
  # range before it ever reaches the string.
  MAX_TIMEOUT_MS = 120_000

  # Postgres bigint ceiling. A cursor is caller-supplied text, so its id is checked
  # against this before it reaches a query — see .decode_cursor.
  MAX_SESSION_ID = 9_223_372_036_854_775_807

  # Upper bound on the candidate id list itself. The pluck is cheap per row, but an
  # unfiltered search should not materialise an unbounded array either.
  MAX_CANDIDATES = 50_000

  Result = Struct.new(
    :matched_ids, :scanned, :candidate_count, :complete, :timed_out, :next_cursor,
    keyword_init: true
  ) do
    def complete? = complete

    # True when the time budget ended the scan — as opposed to the result page
    # filling up, which is the other reason `complete?` can be false.
    def timed_out? = timed_out
    def more? = !complete
  end

  class << self
    # Zero is legal and means "stop before the first chunk" — the setting the mobile QA
    # system test uses to render the stopped-early notice deterministically. A negative
    # is a misconfiguration with no reading at all, so it falls back to the default
    # rather than silently disabling content search.
    def budget_seconds
      seconds = Integer(ENV.fetch(BUDGET_ENV, DEFAULT_TIME_BUDGET_SECONDS))
      seconds.negative? ? DEFAULT_TIME_BUDGET_SECONDS : seconds
    rescue ArgumentError, TypeError
      DEFAULT_TIME_BUDGET_SECONDS
    end

    # A method rather than a bare constant read, so the cap is one seam the tests can
    # move — a capped candidate list changes what `complete?` may claim, and that is
    # not something to leave unpinned.
    def max_candidates
      MAX_CANDIDATES
    end

    def chunk_size
      size = Integer(ENV.fetch(CHUNK_SIZE_ENV, DEFAULT_CHUNK_SIZE))
      size.positive? ? size : DEFAULT_CHUNK_SIZE
    rescue ArgumentError, TypeError
      DEFAULT_CHUNK_SIZE
    end

    # Encode/decode the resume point. Opaque to callers on purpose — it is a keyset
    # position, not an offset, and callers must not do arithmetic on it.
    def encode_cursor(created_at, id)
      return nil if created_at.nil? || id.nil?

      "#{created_at.utc.iso8601(6)}|#{id}"
    end

    def decode_cursor(token)
      return nil if token.blank?

      timestamp, id = token.to_s.split("|", 2)
      parsed = Time.zone.parse(timestamp.to_s)
      return nil if parsed.nil? || id.blank?

      # Range-checked, not merely Integer()-parsed. A cursor is caller-supplied, and a
      # bignum id parses fine here only to blow up later in the adapter's quoting with
      # IntegerOutOf64BitRange — a 500 for what is just a malformed cursor.
      parsed_id = Integer(id)
      return nil unless parsed_id.between?(1, MAX_SESSION_ID)

      [ parsed, parsed_id ]
    rescue ArgumentError, TypeError
      nil
    end
  end

  # @param scope [ActiveRecord::Relation] the already-filtered session scope
  # @param query [String] the raw search string
  # @param limit [Integer] how many matches to collect before stopping
  # @param cursor [String, nil] a `next_cursor` from a previous call, to resume
  # @param budget_seconds [Integer] wall-clock ceiling for this search
  def initialize(scope:, query:, limit: DEFAULT_LIMIT, cursor: nil, budget_seconds: nil, chunk_size: nil)
    @scope = scope
    @query = query.to_s
    @limit = [ limit.to_i, 1 ].max
    @cursor = cursor
    @budget_seconds = (budget_seconds || self.class.budget_seconds).to_f
    @chunk_size = [ (chunk_size || self.class.chunk_size).to_i, 1 ].max
  end

  def call
    # Started before the candidate query, not after: that query is part of what the
    # caller is waiting for, so charging the budget only from the first chunk would
    # make "bounded by 20 seconds" mean 20 seconds plus however long it took to
    # resolve 50,000 ids.
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + @budget_seconds

    candidates = candidate_rows
    return empty_result if candidates.empty?

    # Each match is kept with the candidate position it was found at, because the
    # cursor has to point at the last match the CALLER is shown — not at the last
    # candidate this scan happened to read. A chunk can produce more matches than
    # fit on the page, and resuming past the whole chunk would silently drop the
    # ones that did not fit.
    matched = []
    scanned = 0
    timed_out = false

    with_statement_timeout do
      candidates.each_slice(@chunk_size) do |chunk|
        # Both ways the budget can end the scan set the same flag: the wall clock
        # running out before a chunk, and Postgres cancelling one mid-flight. To the
        # caller they are the same fact — "I ran out of time", not "I ran out of
        # corpus" — and reporting the first as anything else mislabels why an
        # incomplete scan stopped.
        if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
          timed_out = true
          break
        end

        chunk_ids = chunk.map(&:first)
        begin
          hits = matching_ids(chunk_ids)
        rescue ActiveRecord::QueryCanceled
          timed_out = true
          break
        end

        # Preserve the scan order (newest first) rather than the order Postgres
        # happened to return, so the cursor and the result list agree.
        chunk_ids.each_with_index do |id, offset|
          matched << [ id, scanned + offset ] if hits.include?(id)
        end
        scanned += chunk_ids.size
        break if matched.size >= @limit
      end
    end

    # Three separate reasons this scan may not have covered everything, and all three
    # have to reach `complete`. The third is the easiest to miss: `candidate_rows`
    # caps its own list at MAX_CANDIDATES, so `scanned >= candidates.size` can be true
    # of a list that was itself cut short — which would report "these are every match"
    # about a corpus the scan never reached the end of, with no cursor to resume from.
    capped = candidates.size >= self.class.max_candidates
    truncated = matched.size > @limit
    matched = matched.first(@limit)
    # How far the caller has actually been shown. When the page filled mid-chunk it
    # is the position of the last match on it; otherwise it is everything read.
    covered = truncated ? matched.last.last + 1 : scanned
    complete = !truncated && !timed_out && !capped && scanned >= candidates.size
    last_covered = candidates[covered - 1] if covered.positive?

    Result.new(
      matched_ids: matched.map(&:first),
      scanned: covered,
      candidate_count: candidates.size,
      complete: complete,
      timed_out: timed_out,
      # Where to resume. When nothing was covered at all — the budget was already
      # gone, or the very first statement was cancelled — there is no new position,
      # so the caller's own cursor is handed straight back rather than a fabricated
      # one that would skip candidates nobody looked at.
      next_cursor: complete ? nil : (self.class.encode_cursor(last_covered&.last, last_covered&.first) || @cursor.presence)
    )
  end

  private

  attr_reader :scope, :query, :limit

  def empty_result
    Result.new(
      matched_ids: [], scanned: 0, candidate_count: 0,
      complete: true, timed_out: false, next_cursor: nil
    )
  end

  # [[id, created_at], …] newest first. `except(:includes)` matters: the callers'
  # scopes carry `includes(:category)`, which would turn this id-only pluck into an
  # eager load of every candidate row.
  def candidate_rows
    relation = scope.except(:includes, :eager_load, :preload, :order, :limit, :offset)
      .reorder(created_at: :desc, id: :desc)
      .limit(self.class.max_candidates)

    if (position = self.class.decode_cursor(@cursor))
      relation = relation.where(
        "(sessions.created_at, sessions.id) < (?, ?)", position.first, position.last
      )
    end

    relation.pluck(:id, :created_at)
  end

  def matching_ids(chunk_ids)
    Session.where(id: chunk_ids)
      .where(SessionSearchable::CONTENT_PREDICATE, q: search_term)
      .pluck(:id)
      .to_set
  end

  def search_term
    @search_term ||= "%#{ActiveRecord::Base.sanitize_sql_like(query)}%"
  end

  # A server-side ceiling under the wall-clock budget, so a single pathological
  # statement cannot outlive it either. Session-scoped rather than `SET LOCAL`
  # because this runs outside a transaction in production and inside the suite's
  # wrapping transaction in tests; `SET LOCAL` would be discarded in the first case
  # and would leak past a savepoint in the second.
  # `SET` takes no bind parameters, so the value is interpolated — which is only
  # safe because it is forced through Integer() and clamped here, never carried
  # from the request. Everything a caller supplies reaches Postgres as a bind.
  def with_statement_timeout
    connection = Session.connection
    milliseconds = Integer((@budget_seconds * 1000).ceil).clamp(1, MAX_TIMEOUT_MS)
    connection.execute("SET statement_timeout = #{milliseconds}")
    yield
  ensure
    begin
      connection&.execute("SET statement_timeout = DEFAULT")
    rescue ActiveRecord::ActiveRecordError => e
      # `SET` is session-scoped and Rails does not reset GUCs on checkin, so a
      # connection we could not restore would carry this search's timeout into every
      # later request that leases it. Drop it from the pool instead — a reconnect is
      # cheap next to silently capping unrelated queries.
      Rails.logger.error(
        "[SessionContentSearch] could not reset statement_timeout (#{milliseconds}ms); " \
        "discarding connection: #{e.class}"
      )
      begin
        Session.connection_pool.remove(connection)
      rescue StandardError => remove_error
        Rails.logger.error("[SessionContentSearch] could not discard connection: #{remove_error.class}")
      end
    end
  end
end
