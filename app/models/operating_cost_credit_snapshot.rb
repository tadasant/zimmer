# frozen_string_literal: true

# A credit balance on an account on a date. Burn rate and run-out date come from
# the drop between snapshots (OperatingCosts::Report); a rise is a top-up and
# is never read as negative spend.
#
# - `prepaid`: money already paid; consumption is the cost.
# - `promotional`: free credit; the cost is zero until it runs out, then the burn.
# - `plan_included`: a plan's monthly allowance; overage is the cost.
class OperatingCostCreditSnapshot < ApplicationRecord
  KINDS = %w[prepaid promotional plan_included].freeze

  belongs_to :account, class_name: "OperatingCostAccount", inverse_of: :credit_snapshots

  validates :as_of_date, presence: true
  validates :balance, :balance_usd, numericality: true
  validates :kind, inclusion: { in: KINDS }
  validates :source, inclusion: { in: OperatingCostObservation::SOURCES }
  validates :currency, format: { with: /\A[A-Z]{3}\z/ }

  before_validation do
    self.currency = currency.to_s.upcase.presence || "USD"
    self.balance_usd = balance if currency == "USD"
  end

  def as_api_json
    { id: id, account: account.key, as_of_date: as_of_date, balance: balance.to_f, currency: currency,
      balance_usd: balance_usd.to_f, kind: kind, granted_total: granted_total&.to_f, expires_on: expires_on,
      source: source, evidence: evidence }
  end
end
