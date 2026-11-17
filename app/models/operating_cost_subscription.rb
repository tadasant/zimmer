# frozen_string_literal: true

# A fixed, effective-dated charge on an account: a seat, a plan, a yearly
# membership. OperatingCosts::Ledger prorates it daily wherever no observed bill
# covers the day, and OperatingCosts::Report carries it forward while it is
# active. `included_usage_usd` is a plan that includes usage (credits a month);
# usage observations on the account count only above it.
class OperatingCostSubscription < ApplicationRecord
  INTERVALS = %w[month year].freeze
  DAYS_PER_MONTH = 365.25 / 12

  belongs_to :account, class_name: "OperatingCostAccount", inverse_of: :subscriptions

  validates :plan_name, presence: true
  validates :amount, :amount_usd, numericality: { greater_than_or_equal_to: 0 }
  validates :interval, inclusion: { in: INTERVALS }
  validates :quantity, numericality: { only_integer: true, greater_than: 0 }
  validates :currency, format: { with: /\A[A-Z]{3}\z/ }
  validates :started_on, presence: true
  validates :included_usage_usd, numericality: { greater_than_or_equal_to: 0 }, allow_nil: true
  validate :ends_after_it_starts

  before_validation do
    self.currency = currency.to_s.upcase.presence || "USD"
    self.amount_usd = amount if currency == "USD"
  end

  def active_on?(date) = started_on <= date && (ended_on.nil? || ended_on >= date)

  # The whole charge, all seats, per month.
  def monthly_usd = interval == "year" ? amount_usd * quantity / 12 : amount_usd * quantity

  # The same year (365.25 days) the forward rate uses, so accrual and projection agree.
  def daily_usd = monthly_usd / DAYS_PER_MONTH

  def as_api_json
    { account: account.key, plan_name: plan_name, amount: amount.to_f, currency: currency, amount_usd: amount_usd.to_f,
      interval: interval, quantity: quantity, monthly_usd: monthly_usd.to_f.round(2),
      included_usage_usd: included_usage_usd&.to_f, started_on: started_on, ended_on: ended_on,
      renews_on: renews_on, auto_renew: auto_renew, notes: notes }
  end

  private

  def ends_after_it_starts
    errors.add(:ended_on, "must be on or after started_on") if ended_on && started_on && ended_on < started_on
  end
end
