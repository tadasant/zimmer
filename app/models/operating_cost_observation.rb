# frozen_string_literal: true

# One money fact about one account, as it was reported. Never edited in place:
# the same (account, metric, as-of date, period start, source) written again
# replaces the figure, and anything else is a new row.
#
# - `daily_cost`: what one day cost (period_start = period_end = the day).
# - `period_to_date`: a running total for a billing period; the ledger spreads
#   each report's increase over the days since the previous report.
# - `invoice`: a closed bill for a period, spread evenly over it.
class OperatingCostObservation < ApplicationRecord
  METRICS = %w[daily_cost period_to_date invoice].freeze
  SOURCES = %w[derived billing_api agent manual card_statement].freeze
  CONFIDENCES = %w[billed metered estimated].freeze

  belongs_to :account, class_name: "OperatingCostAccount", inverse_of: :observations

  validates :metric, inclusion: { in: METRICS }
  validates :source, inclusion: { in: SOURCES }
  validates :confidence, inclusion: { in: CONFIDENCES }
  validates :as_of_date, :period_start, :period_end, presence: true
  validates :amount, :amount_usd, numericality: true
  validates :currency, format: { with: /\A[A-Z]{3}\z/ }
  validate :period_is_ordered

  before_validation do
    self.currency = currency.to_s.upcase.presence || "USD"
    # A USD figure is its own USD amount, on every write: an upsert that changes
    # `amount` must not leave the old dollars behind.
    self.amount_usd = amount if currency == "USD"
    if metric == "daily_cost" && as_of_date
      self.period_start ||= as_of_date
      self.period_end ||= as_of_date
    end
    self.period_end ||= as_of_date if metric == "period_to_date"
    self.as_of_date ||= period_end if metric == "invoice"
  end

  def as_api_json
    { id: id, account: account.key, metric: metric, as_of_date: as_of_date, period_start: period_start,
      period_end: period_end, amount: amount.to_f, currency: currency, amount_usd: amount_usd.to_f, source: source,
      confidence: confidence, collector: collector, evidence: evidence, recorded_by_session_id: recorded_by_session_id }
  end

  private

  def period_is_ordered
    return unless period_start && period_end

    errors.add(:period_end, "must be on or after period_start") if period_end < period_start
  end
end
