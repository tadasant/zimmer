# frozen_string_literal: true

# The canonical daily series: one row per account per day, rebuilt from the raw
# tables by OperatingCosts::Ledger and never written anywhere else. `amount_usd`
# is already multiplied by the account's `zimmer_share`.
class OperatingCostDailyEntry < ApplicationRecord
  BASES = %w[observed differenced prorated_invoice prorated_subscription].freeze

  belongs_to :account, class_name: "OperatingCostAccount", inverse_of: :daily_entries

  validates :date, presence: true
  validates :basis, inclusion: { in: BASES }
  validates :confidence, inclusion: { in: OperatingCostObservation::CONFIDENCES }

  def as_api_json
    { account: account.key, date: date, amount_usd: amount_usd.to_f, basis: basis, confidence: confidence, source: source }
  end
end
