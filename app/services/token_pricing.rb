# frozen_string_literal: true

# Anthropic list prices, and the one place that turns stored token volumes into
# money.
#
# Volumes are what we persist; prices are applied at read time. Rates change and
# models get added, and we want yesterday's window re-priced at today's rates
# without a backfill — and we want to ask "what would this workload have cost on
# Sonnet" against the same volumes. Baking dollars into the rows would foreclose
# both. This mirrors the method used in PulseMCP/pulsemcp
# `agents/agent-roots/inference-metrics`, whose stored dataset is likewise
# volumes-only.
#
# CACHE RATES ARE DERIVED, NOT TYPED. Anthropic's cache multipliers are uniform
# across the model line — a cache read is 0.1x that model's base input rate, a
# 5-minute cache write 1.25x, a 1-hour cache write 2x — and that holds on Opus,
# Sonnet and Haiku alike. Deriving them means a new model needs two numbers
# instead of five, and makes the "cache write costs double a fresh input token"
# relationship legible rather than something you have to spot across a table.
module TokenPricing
  # Per million tokens, USD.
  Rate = Struct.new(:input, :output, keyword_init: true) do
    # Rounded because the derived rates are money, and binary floats are not:
    # 3.0 * 0.1 is 0.30000000000000004, which would otherwise reach the API's
    # published rate table and the generated SQL looking like a mistake. Six
    # places is far finer than any real per-MTok rate.
    def cache_read = derive(CACHE_READ_MULTIPLIER)
    def cache_write_5m = derive(CACHE_WRITE_5M_MULTIPLIER)
    def cache_write_1h = derive(CACHE_WRITE_1H_MULTIPLIER)

    private

    def derive(multiplier) = (input * multiplier).round(6)
  end

  CACHE_READ_MULTIPLIER = 0.1
  CACHE_WRITE_5M_MULTIPLIER = 1.25
  CACHE_WRITE_1H_MULTIPLIER = 2.0

  # Server-side tools bill per request, not per token.
  WEB_SEARCH_PER_1K_REQUESTS = 10.0

  # Keyed by model family. `resolve` matches the longest family key contained in
  # the model id, so `claude-haiku-4-5-20251001` and `claude-haiku-4-5` both land
  # on the same rate without needing a row per dated snapshot.
  #
  # Sonnet 5 carries an introductory $2/$10 through 2026-08-31; we price at
  # standard list ($3/$15) so the figures stay comparable across the window
  # rather than stepping when the promotion lapses.
  RATES = {
    "fable" => Rate.new(input: 10.0, output: 50.0),
    "mythos" => Rate.new(input: 10.0, output: 50.0),
    "opus" => Rate.new(input: 5.0, output: 25.0),
    "sonnet" => Rate.new(input: 3.0, output: 15.0),
    "haiku" => Rate.new(input: 1.0, output: 5.0)
  }.freeze

  # Unknown models price at zero rather than guessing. A wrong rate is worse than
  # a visibly missing one: it lands in a total that reads as authoritative. The
  # Costs page surfaces unpriced models explicitly so a new model id shows up as
  # something to add here, not as silent under-counting.
  UNPRICED = Rate.new(input: 0.0, output: 0.0)

  module_function

  # @param model [String, nil] a model id as it appears in the transcript
  # @return [Rate]
  def rate_for(model)
    key = family_for(model)
    key ? RATES.fetch(key) : UNPRICED
  end

  # @return [String, nil] the family key, or nil when nothing matches
  def family_for(model)
    id = model.to_s.downcase
    return nil if id.empty?

    RATES.keys.select { |family| id.include?(family) }.max_by(&:length)
  end

  def priced?(model) = !family_for(model).nil?

  # Cost of one usage record, in USD.
  #
  # `cache_creation_tokens` is the total the API reports; the 5m/1h split is a
  # breakdown of it. When the split is absent (older transcript lines predate the
  # `cache_creation` sub-object) the whole amount is charged at the 1-hour rate —
  # the conservative reading, and the correct one for this deployment, where 95%
  # of observed cache writes are on the 1-hour TTL.
  def cost_for(model:, input_tokens: 0, output_tokens: 0, cache_read_tokens: 0,
               cache_creation_tokens: 0, cache_creation_5m_tokens: 0,
               cache_creation_1h_tokens: 0, web_search_requests: 0, **)
    rate = rate_for(model)

    split_total = cache_creation_5m_tokens.to_i + cache_creation_1h_tokens.to_i
    if split_total.zero?
      write_5m = 0
      write_1h = cache_creation_tokens.to_i
    else
      write_5m = cache_creation_5m_tokens.to_i
      write_1h = cache_creation_1h_tokens.to_i
    end

    per_token = (
      input_tokens.to_i * rate.input +
      output_tokens.to_i * rate.output +
      cache_read_tokens.to_i * rate.cache_read +
      write_5m * rate.cache_write_5m +
      write_1h * rate.cache_write_1h
    ) / 1_000_000.0

    per_token + (web_search_requests.to_i * WEB_SEARCH_PER_1K_REQUESTS / 1_000.0)
  end

  # The SQL expression that prices a row, for aggregate queries that must not
  # load every record into Ruby to add them up. Kept beside `cost_for` so the two
  # cannot drift: any rate change here changes both.
  #
  # The tables this may be asked to price, and whether each carries the
  # per-request server-tool counters.
  #
  # `cost_sql` interpolates the table name into SQL, and an allowlist is cheaper
  # than trusting every future caller to pass a constant — it makes "this string
  # is never user input" a property of the method rather than a claim about its
  # call sites. Keeping the server-tool flag here rather than in a keyword
  # argument means the call shape stays `cost_sql(table_name)` everywhere, with
  # one table-shaped fact in one place.
  #
  # `token_usage_features` is false: a web search bills per REQUEST, not per
  # token, so there is no defensible way to split it across the content features
  # inside that request. It stays on the parent row, which leaves it in the
  # unattributed residual — the honest place for a charge no feature can claim.
  PRICEABLE_TABLES = {
    "session_token_usages" => true,
    "adhoc_token_usages" => true,
    "token_usage_features" => false
  }.freeze

  # The family every quota figure is denominated in.
  #
  # Anthropic reports quota as a bare percentage, so turning it into money needs
  # a unit — and the only unit that means anything on this deployment is Opus,
  # which is what more than 99% of the fleet's spend runs on. QuotaCapacity\
  # Calibrator re-prices every stored volume at this family's rate before
  # dividing by utilization, so "the weekly window is worth $26k" reads as "$26k
  # of Opus", not as an average over whatever model mix happened to run.
  QUOTA_DENOMINATION_FAMILY = "opus"

  # @param table [String] the table to qualify columns with
  # @param as_family [String, nil] price every row at this family's rate instead
  #   of the row's own model. Nil is the honest bill; a family is the
  #   counterfactual — "what would these volumes have cost on Opus" — which is
  #   what a quota figure denominated in one model needs.
  # @raise [ArgumentError] if asked to price a table that is not one of ours, or
  #   to denominate in a family with no rate
  def cost_sql(table, as_family: nil)
    unless PRICEABLE_TABLES.key?(table.to_s)
      raise ArgumentError, "refusing to build pricing SQL for unknown table #{table.inspect}"
    end
    if as_family && !RATES.key?(as_family.to_s)
      raise ArgumentError, "no rate for family #{as_family.inspect}"
    end

    # Longest key first, mirroring `family_for`: SQL CASE takes the first match,
    # so a future family key that is a substring of another must not shadow it.
    families = RATES.sort_by { |family, _| -family.length }.map do |family, rate|
      # Denominating replaces the RATE, never the MATCH: a row still has to be a
      # model we recognize to be priced at all, so an unpriced model stays
      # visibly unpriced instead of quietly inheriting Opus money.
      rate = RATES.fetch(as_family.to_s) if as_family
      <<~SQL.squish
        WHEN POSITION('#{family}' IN LOWER(#{table}.model)) > 0 THEN (
          #{table}.input_tokens * #{rate.input}
          + #{table}.output_tokens * #{rate.output}
          + #{table}.cache_read_tokens * #{rate.cache_read}
          + CASE
              WHEN #{table}.cache_creation_5m_tokens + #{table}.cache_creation_1h_tokens = 0
                THEN #{table}.cache_creation_tokens * #{rate.cache_write_1h}
              ELSE #{table}.cache_creation_5m_tokens * #{rate.cache_write_5m}
                   + #{table}.cache_creation_1h_tokens * #{rate.cache_write_1h}
            END
        )
      SQL
    end

    server_tools = if PRICEABLE_TABLES.fetch(table.to_s)
      "+ #{table}.web_search_requests * #{WEB_SEARCH_PER_1K_REQUESTS} / 1000.0"
    else
      ""
    end

    <<~SQL.squish
      (CASE #{families.join(" ")} ELSE 0 END) / 1000000.0
      #{server_tools}
    SQL
  end
end
