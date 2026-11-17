# frozen_string_literal: true

require "test_helper"

class OperatingCosts::ReportTest < ActiveSupport::TestCase
  include OperatingCostFixtures

  setup do
    @today = Date.new(2026, 11, 17)
    travel_to(@today.in_time_zone.change(hour: 12))
    seed_operating_costs!(today: @today)
    OperatingCostsCollectionJob.perform_now
  end

  def report(**args) = OperatingCosts::Report.new(today: @today, **args)

  def row(rows, key) = rows.find { |r| r[:key] == key }

  test "a closed month is the sum of its bills, by functionality" do
    gateway = row(report.breakdown("functionality"), "gateway-infra")

    assert_in_delta 25 + 15, gateway[:previous_month_usd], 0.01
    assert_equal [ "Gateway app", "Gateway database" ], gateway[:accounts].map { |a| a[:label] }.sort
  end

  test "an account billed by invoice is projected from its last invoice, not from an empty month" do
    gateway = row(report.breakdown("functionality"), "gateway-infra")

    assert_equal 0, gateway[:month_to_date_usd], "no November invoice yet"
    assert_in_delta 40.0 / 31 * 30, gateway[:month_projected_usd], 0.01, "October's daily rate over all 30 days"
    assert_in_delta 40, gateway[:forward_monthly_usd], 1.5
  end

  test "a subscription with no metered usage is carried forward at its monthly price" do
    inference = row(report.breakdown("functionality"), "agent-inference")

    assert_in_delta 200, inference[:forward_monthly_usd], 0.01
  end

  test "externally paid accounts are reported apart and kept out of the totals unless asked" do
    others = report.paid_by_others

    assert_equal [ "example-org" ], others.map { |o| o[:paid_by] }
    assert_nil row(report.breakdown("account"), "ci-runner")
    assert row(report(include_external: true).breakdown("account"), "ci-runner")
    assert_operator report(include_external: true).totals[:previous_month_usd], :>, report.totals[:previous_month_usd]
  end

  test "credits report burn and run-out from the drop in balance" do
    credit = report.credits.sole

    assert_in_delta 0.8, credit[:burn_per_day_usd], 0.01
    assert_equal @today - 1 + 25, credit[:run_out_on]
  end

  test "promotional credit costs nothing until it runs out, then the forward months carry the burn" do
    OperatingCostCreditSnapshot.where(account: OperatingCostAccount.find_by!(key: "voiceco-api")).update_all(kind: "promotional")
    strip = report.monthly_strip.select { |m| m[:kind] == "forward" }

    assert_operator strip.first[:credit_cliff_usd], :>, 0, "December carries the days after the 11th"
    assert_in_delta 0.8 * 31, strip.second[:credit_cliff_usd], 0.01
  end

  test "the credit cliff follows the page's filters and leaves out accounts others pay for" do
    OperatingCostCreditSnapshot.update_all(kind: "promotional")

    assert_equal 0, report(functionality: "gateway-infra").monthly_strip.last[:credit_cliff_usd]
    OperatingCostAccount.find_by!(key: "voiceco-api").update!(paid_by: "example-org")
    assert_equal 0, report.monthly_strip.last[:credit_cliff_usd]
  end

  test "an old failure from a collector never run again stops warning once it ages out" do
    OperatingCostCollectionRun.create!(collector: "agent:one-off", status: "failed", started_at: 1.hour.ago, error: "nope")
    assert_match "agent:one-off", report.stale_reasons.join

    OperatingCostCollectionRun.where(collector: "agent:one-off").update_all(started_at: 3.days.ago)
    assert_empty report.stale_reasons
  end

  test "the monthly strip runs six closed months, this month and three ahead" do
    kinds = report.monthly_strip.map { |m| m[:kind] }

    assert_equal [ "closed" ] * 6 + [ "current" ] + [ "forward" ] * 3, kinds
  end

  test "filters narrow every figure" do
    voice = report(functionality: "voice")

    assert_equal [ "VoiceCo" ], voice.breakdown("vendor").map { |r| r[:label] }
    assert_equal [ "live-mode" ], voice.breakdown("agent_root").map { |r| r[:key] }
    assert_equal [ "ExampleCloud" ], report(vendor: "examplecloud").breakdown("vendor").map { |r| r[:label] }
  end

  test "an unknown filter or month is an argument error" do
    assert_raises(ArgumentError) { report(functionality: "nope") }
    assert_raises(ArgumentError) { report(month: "2026-13") }
    assert_raises(ArgumentError) { report.timeseries(granularity: "week") }
  end

  test "the daily series splits each day the way its month was split" do
    series = report.timeseries(group_by: "agent_root", granularity: "day", from: @today - 3, to: @today - 1)

    assert_equal 3, series.size
    assert(series.all? { |day| day[:groups].any? { |g| g[:label] == "live-mode" } })
  end

  test "it is stale when the derived collection has not run recently" do
    assert_empty report.stale_reasons

    OperatingCostCollectionRun.where(collector: "derived").update_all(finished_at: 3.days.ago)

    assert_match "last succeeded", report.stale_reasons.sole
  end

  test "every view serializes" do
    OperatingCosts::Report::VIEWS.each do |view|
      json = report.as_api_json(view: view)
      assert_equal "2026-11-16", json[:as_of].iso8601
      assert JSON.generate(json)
    end
  end
end
