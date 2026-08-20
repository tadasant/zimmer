# frozen_string_literal: true

# Behaviour shared by the two token-usage tables.
#
# `session_token_usages` and `adhoc_token_usages` hold the same measurements
# about the same kind of event — one Anthropic API call — and differ only in what
# they hang off (an agent session vs a piece of Zimmer's own machinery). Keeping
# the columns and the arithmetic identical is what lets the Costs page add the
# two together without special-casing either.
module TokenAccounting
  extend ActiveSupport::Concern

  # The four buckets the API reports. The 5m/1h columns are a breakdown of
  # `cache_creation_tokens`, not additional volume, so they are excluded from
  # any total-tokens sum.
  VOLUME_COLUMNS = %i[
    input_tokens output_tokens cache_read_tokens cache_creation_tokens
  ].freeze

  PRICING_ATTRIBUTES = %i[
    model input_tokens output_tokens cache_read_tokens cache_creation_tokens
    cache_creation_5m_tokens cache_creation_1h_tokens web_search_requests
  ].freeze

  SUMMED_COLUMNS = %i[
    input_tokens output_tokens cache_read_tokens cache_creation_tokens
    cache_creation_5m_tokens cache_creation_1h_tokens
    web_search_requests web_fetch_requests
  ].freeze

  included do
    validates :request_id, presence: true, uniqueness: true
    validates :model, presence: true
    validates :called_at, presence: true

    scope :in_window, ->(from, to) { where(called_at: from..to) }
    scope :for_model, ->(model) { where(model: model) }

    # Newest first is what every consumer wants: the Costs page, the API index,
    # and the MCP tool all read "recent spend".
    scope :recent_first, -> { order(called_at: :desc) }
  end

  class_methods do
    # Every column sum plus the priced total, in ONE query. The alternative —
    # loading rows and adding them in Ruby — is fine for a day and ruinous for a
    # year; this table grows by roughly 8,500 rows a day on this deployment.
    def totals
      selects = SUMMED_COLUMNS.map { |c| "COALESCE(SUM(#{c}), 0) AS #{c}" }
      selects << "COUNT(*) AS api_calls"
      selects << "COALESCE(SUM(#{TokenPricing.cost_sql(table_name)}), 0) AS cost_usd"

      row = unscope(:order).pick(Arel.sql(selects.join(", ")))
      values = Array(row)

      totals = SUMMED_COLUMNS.each_with_index.to_h { |c, i| [ c, values[i].to_i ] }
      totals[:api_calls] = values[SUMMED_COLUMNS.length].to_i
      totals[:cost_usd] = values[SUMMED_COLUMNS.length + 1].to_f
      totals[:total_tokens] = VOLUME_COLUMNS.sum { |c| totals[c] }
      totals
    end

    # `SUM(cost)` as a reusable fragment for GROUP BY rollups.
    def cost_sum_sql = Arel.sql("COALESCE(SUM(#{TokenPricing.cost_sql(table_name)}), 0)")

    def total_tokens_sql
      Arel.sql("COALESCE(SUM(#{VOLUME_COLUMNS.join(' + ')}), 0)")
    end
  end

  # Total tokens moved by this call.
  def total_tokens = VOLUME_COLUMNS.sum { |c| public_send(c).to_i }

  # USD at current list price. Deliberately not persisted — see TokenPricing.
  def cost_usd
    TokenPricing.cost_for(**attributes.symbolize_keys.slice(*PRICING_ATTRIBUTES))
  end

  def priced? = TokenPricing.priced?(model)
end
