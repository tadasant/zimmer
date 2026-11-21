# frozen_string_literal: true

# One session's spend, as the session page and `get_session` both state it.
#
# The same figure the muted cost badge shows, plus what that figure is made of:
# token volumes by kind, the number of API calls, when the newest one landed, and
# which models in it carry no price. One grouped query over the session's ledger
# rows, so the detail page and the MCP dump read the same numbers and cannot
# disagree.
#
# What the dollars MEAN depends on the runtime, and the summary says which:
# Claude Code and Codex are subscription-billed, so their figure is list price — a
# comparable unit, not money owed. Pi is metered by OpenRouter, so its figure IS
# money owed, priced at the rate OpenRouter publishes for the model (and, for every
# priced model, identical to the per-call cost Pi records in its own transcript).
class SessionCostSummary
  METERED_RUNTIMES = %w[pi].freeze

  attr_reader :session, :cost, :api_calls, :input_tokens, :output_tokens,
              :cache_read_tokens, :cache_write_tokens, :last_called_at, :unpriced_models

  # @param session [Session]
  def self.for(session) = new(session)

  # Whether a runtime's spend is metered money owed rather than subscription list price.
  def self.metered?(runtime) = METERED_RUNTIMES.include?(runtime.to_s)

  def initialize(session)
    @session = session
    rows = SessionTokenUsage.where(session_id: session.id)

    cost, calls, input, output, cache_read, cache_write, last = rows.pick(
      SessionTokenUsage.cost_sum_sql,
      Arel.sql("COUNT(*)"),
      Arel.sql("COALESCE(SUM(input_tokens), 0)"),
      Arel.sql("COALESCE(SUM(output_tokens), 0)"),
      Arel.sql("COALESCE(SUM(cache_read_tokens), 0)"),
      Arel.sql("COALESCE(SUM(cache_creation_tokens), 0)"),
      Arel.sql("MAX(called_at)")
    )

    @cost = cost.to_f
    @api_calls = calls.to_i
    @input_tokens = input.to_i
    @output_tokens = output.to_i
    @cache_read_tokens = cache_read.to_i
    @cache_write_tokens = cache_write.to_i
    @last_called_at = last
    @unpriced_models = @api_calls.zero? ? [] : rows.distinct.pluck(:model).reject { |m| TokenPricing.priced?(m) }.sort
  end

  def any? = api_calls.positive?

  def total_tokens = input_tokens + output_tokens + cache_read_tokens + cache_write_tokens

  def metered? = self.class.metered?(session.agent_runtime)

  # Usage stored, but none of it carries a price — so "$0" would assert it was free.
  def unpriced? = any? && cost.zero? && unpriced_models.any?

  # One sentence on what the dollar figure is, for the tooltip and the MCP dump.
  def basis
    if metered?
      "Metered through OpenRouter, so this is money owed, priced at the rate OpenRouter publishes for the model."
    else
      "Subscription-billed, so this is list price: a comparable unit, not a bill."
    end
  end

  # Said wherever the figure is: the ledger is swept from the transcript, not read
  # live from the API.
  def freshness
    if metered?
      "Updated as each model response lands."
    else
      "Swept from the transcript every ten minutes, so the last few minutes may be missing."
    end
  end

  # The breakdown as one line, for a `title` attribute.
  def breakdown_sentence
    [
      "#{delimit(input_tokens)} input",
      "#{delimit(output_tokens)} output",
      "#{delimit(cache_read_tokens)} cache read",
      "#{delimit(cache_write_tokens)} cache write",
      "across #{delimit(api_calls)} API #{api_calls == 1 ? 'call' : 'calls'}"
    ].join(", ") + "."
  end

  # "2.37M", "58.6K", "940" — the compact form for the meta row.
  def self.compact_tokens(count)
    count = count.to_i
    # 999,950 rounds to "1000.0K"; it reads as 1M.
    if count >= 999_950
      "#{format('%.2f', count / 1_000_000.0).sub(/\.?0+\z/, '')}M"
    elsif count >= 1_000
      "#{format('%.1f', count / 1_000.0).sub(/\.0\z/, '')}K"
    else
      count.to_s
    end
  end

  private

  def delimit(number) = ActiveSupport::NumberHelper.number_to_delimited(number)
end
