# frozen_string_literal: true

require "test_helper"

class OperatingCosts::LedgerTest < ActiveSupport::TestCase
  setup do
    @vendor = OperatingCostVendor.create!(key: "examplecloud", name: "ExampleCloud")
    @account = OperatingCostAccount.create!(key: "box", label: "Box", vendor: @vendor)
    @day = Date.new(2026, 3, 10)
  end

  def observe(**attrs)
    @account.observations.create!({ source: "agent", confidence: "metered", amount: 1 }.merge(attrs))
  end

  def entry(date) = @account.daily_entries.find_by(date: date)

  def rebuild(from: Date.new(2026, 3, 1), to: Date.new(2026, 3, 31))
    OperatingCosts::Ledger.rebuild!(account: @account, from: from, to: to)
  end

  test "an invoice is spread over its period and outranks usage and estimates" do
    observe(metric: "invoice", period_start: Date.new(2026, 3, 1), period_end: Date.new(2026, 3, 31), as_of_date: Date.new(2026, 3, 31),
            amount: 31, confidence: "billed")
    observe(metric: "daily_cost", as_of_date: @day, amount: 9)
    observe(metric: "daily_cost", as_of_date: @day, amount: 7, source: "derived", confidence: "estimated")

    rebuild

    assert_equal 31, @account.daily_entries.count
    assert_equal 1, entry(@day).amount_usd
    assert_equal %w[prorated_invoice billed], [ entry(@day).basis, entry(@day).confidence ]
  end

  test "an external daily figure replaces Zimmer's own estimate for the same day" do
    observe(metric: "daily_cost", as_of_date: @day, amount: 7, source: "derived", confidence: "estimated")
    rebuild
    assert_equal 7, entry(@day).amount_usd

    observe(metric: "daily_cost", as_of_date: @day, amount: 9)
    rebuild
    assert_equal 9, entry(@day).amount_usd
    assert_equal 1, @account.daily_entries.count, "replaced, not added"
  end

  test "consecutive daily reports of a running total each land their own day's increase" do
    period = Date.new(2026, 3, 1)
    observe(metric: "period_to_date", period_start: period, as_of_date: period, amount: 2)
    observe(metric: "period_to_date", period_start: period, as_of_date: period + 1, amount: 5)
    observe(metric: "period_to_date", period_start: period, as_of_date: period + 2, amount: 9)

    rebuild

    assert_equal [ 2, 3, 4 ], (0..2).map { |d| entry(period + d).amount_usd }
    assert_equal %w[differenced metered], [ entry(period + 1).basis, entry(period + 1).confidence ]
  end

  test "the first report of a period, made mid-period, spreads over the period up to it" do
    period = Date.new(2026, 3, 1)
    observe(metric: "period_to_date", period_start: period, as_of_date: Date.new(2026, 3, 17), amount: 34)
    observe(metric: "period_to_date", period_start: period, as_of_date: Date.new(2026, 3, 18), amount: 36)

    rebuild

    assert_equal [ 2 ] * 18, (1..18).map { |d| entry(Date.new(2026, 3, d)).amount_usd }
    assert_nil entry(Date.new(2026, 3, 19)), "nothing is invented past the latest report"
    assert_equal 36, @account.daily_entries.sum(:amount_usd)
  end

  test "a report after a gap spreads its increase over the days since the previous report" do
    period = Date.new(2026, 3, 1)
    observe(metric: "period_to_date", period_start: period, as_of_date: Date.new(2026, 3, 2), amount: 2)
    observe(metric: "period_to_date", period_start: period, as_of_date: Date.new(2026, 3, 6), amount: 14)

    rebuild

    assert_equal [ 1, 1, 3, 3, 3, 3 ], (1..6).map { |d| entry(Date.new(2026, 3, d)).amount_usd }
    assert_equal 14, @account.daily_entries.sum(:amount_usd)
  end

  test "an uneven spread puts the rounding remainder on the last day, so the month total is exact" do
    period = Date.new(2026, 3, 1)
    observe(metric: "period_to_date", period_start: period, as_of_date: Date.new(2026, 3, 3), amount: 10)

    rebuild

    assert_equal [ 3.3333, 3.3333, 3.3334 ].map(&:to_d), (1..3).map { |d| entry(Date.new(2026, 3, d)).amount_usd }
    assert_equal 10, @account.daily_entries.sum(:amount_usd)
  end

  test "a running total that goes down spreads the drop as negative days, so the period sums to its latest total" do
    period = Date.new(2026, 3, 1)
    observe(metric: "period_to_date", period_start: period, as_of_date: Date.new(2026, 3, 2), amount: 10)
    observe(metric: "period_to_date", period_start: period, as_of_date: Date.new(2026, 3, 4), amount: 6)
    observe(metric: "period_to_date", period_start: period, as_of_date: Date.new(2026, 3, 5), amount: 9)

    rebuild

    assert_equal [ 5, 5, -2, -2, 3 ], (1..5).map { |d| entry(Date.new(2026, 3, d)).amount_usd }
    assert_equal 9, @account.daily_entries.sum(:amount_usd)
  end

  test "a new period's first report spreads from its own start, not from the previous period's last report" do
    observe(metric: "period_to_date", period_start: Date.new(2026, 2, 1), as_of_date: Date.new(2026, 2, 27), amount: 50)
    observe(metric: "period_to_date", period_start: Date.new(2026, 3, 1), as_of_date: Date.new(2026, 3, 2), amount: 4)

    rebuild(from: Date.new(2026, 2, 1))

    assert_equal 50, @account.daily_entries.where(date: Date.new(2026, 2, 1)..Date.new(2026, 2, 28)).sum(:amount_usd)
    assert_equal [ 2, 2 ], (1..2).map { |d| entry(Date.new(2026, 3, d)).amount_usd }
  end

  test "two sources reporting the same running total are never added together" do
    observe(metric: "period_to_date", period_start: Date.new(2026, 2, 28), as_of_date: Date.new(2026, 3, 4), amount: 10,
            source: "billing_api")
    observe(metric: "period_to_date", period_start: Date.new(2026, 3, 1), as_of_date: Date.new(2026, 3, 5), amount: 10)

    rebuild(from: Date.new(2026, 2, 28))

    assert_equal [ 2 ] * 5, (0..4).map { |d| entry(Date.new(2026, 2, 28) + d).amount_usd }, "billing_api wins every day it covers"
    assert_equal 2, entry(Date.new(2026, 3, 5)).amount_usd, "the agent's own share fills the day billing_api has not reached"
    assert_equal "agent", entry(Date.new(2026, 3, 5)).source
  end

  test "a lagging source is not differenced against a more trusted one" do
    period = Date.new(2026, 3, 1)
    observe(metric: "period_to_date", period_start: period, as_of_date: Date.new(2026, 3, 2), amount: 10, source: "billing_api")
    observe(metric: "period_to_date", period_start: period, as_of_date: Date.new(2026, 3, 3), amount: 9)

    rebuild

    assert_equal [ 5, 5, 3 ], (1..3).map { |d| entry(Date.new(2026, 3, d)).amount_usd }, "no negative day from mixing sources"
  end

  test "a report dated before its period starts lands on the period's first day" do
    observe(metric: "period_to_date", period_start: Date.new(2026, 3, 5), period_end: Date.new(2026, 3, 31),
            as_of_date: Date.new(2026, 3, 3), amount: 4)

    rebuild

    assert_nil entry(Date.new(2026, 3, 3))
    assert_equal 4, entry(Date.new(2026, 3, 5)).amount_usd
  end

  test "an included-usage allowance applies to running-total usage spread over the month" do
    @account.subscriptions.create!(plan_name: "Starter", amount: 0, interval: "month", included_usage_usd: 10,
                                   started_on: Date.new(2026, 1, 1))
    observe(metric: "period_to_date", period_start: Date.new(2026, 3, 1), as_of_date: Date.new(2026, 3, 4), amount: 16)

    rebuild(to: Date.new(2026, 3, 4))

    assert_equal [ 0, 0, 2, 4 ], (1..4).map { |d| entry(Date.new(2026, 3, d)).amount_usd }
  end

  test "a subscription accrues daily where nothing else covers the day, within its dates" do
    @account.subscriptions.create!(plan_name: "Seat", amount: 36.5, interval: "month", started_on: Date.new(2026, 3, 5),
                                   ended_on: Date.new(2026, 3, 20))

    rebuild

    assert_nil entry(Date.new(2026, 3, 4))
    assert_in_delta 36.5 / OperatingCostSubscription::DAYS_PER_MONTH, entry(Date.new(2026, 3, 5)).amount_usd, 0.0001
    assert_nil entry(Date.new(2026, 3, 21))
  end

  test "a plan with included usage charges its fee plus only the usage beyond the allowance" do
    @account.subscriptions.create!(plan_name: "Starter", amount: 0, interval: "month", included_usage_usd: 10,
                                   started_on: Date.new(2026, 1, 1))
    (1..4).each { |d| observe(metric: "daily_cost", as_of_date: Date.new(2026, 3, d), amount: 4) }

    rebuild(to: Date.new(2026, 3, 4))

    assert_equal [ 0, 0, 2, 4 ], (1..4).map { |d| entry(Date.new(2026, 3, d)).amount_usd }
  end

  test "another subscription beside an included-usage plan still accrues" do
    @account.subscriptions.create!(plan_name: "Starter", amount: 0, interval: "month", included_usage_usd: 10,
                                   started_on: Date.new(2026, 1, 1))
    @account.subscriptions.create!(plan_name: "Extra seat", amount: 30.4375, interval: "month", started_on: Date.new(2026, 1, 1))

    rebuild(to: Date.new(2026, 3, 1))

    assert_in_delta 1, entry(Date.new(2026, 3, 1)).amount_usd, 0.0001
  end

  test "zimmer_share scales every figure" do
    @account.update!(zimmer_share: 0.25)
    observe(metric: "daily_cost", as_of_date: @day, amount: 8)

    rebuild

    assert_equal 2, entry(@day).amount_usd
  end

  test "a rebuild is idempotent" do
    observe(metric: "daily_cost", as_of_date: @day, amount: 8)
    rebuild
    before = @account.daily_entries.pluck(:date, :amount_usd)

    rebuild

    assert_equal before, @account.daily_entries.pluck(:date, :amount_usd)
  end
end
