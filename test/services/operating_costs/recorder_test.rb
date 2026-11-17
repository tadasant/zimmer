# frozen_string_literal: true

require "test_helper"

class OperatingCosts::RecorderTest < ActiveSupport::TestCase
  include OperatingCostFixtures

  test "a batch creates the taxonomy and figures by key, and the same batch again changes nothing" do
    first = seed_operating_costs!

    assert_equal 6, first.counts["accounts"]["created"]
    assert OperatingCostDailyEntry.exists?, "touched accounts are rebuilt"
    assert OperatingCostMonthlyAllocation.exists?, "and their months allocated"
    assert_equal "succeeded", OperatingCostCollectionRun.find_by!(collector: "agent:fixture").status

    second = OperatingCosts::Recorder.record!(operating_cost_payload)

    assert second.counts.values.all? { |c| c["created"].zero? && c["updated"].zero? }, second.counts.inspect
  end

  test "re-recording a figure with a new amount moves its USD amount and its daily series with it" do
    seed_operating_costs!
    item = { "account" => "examplecloud-gw-app", "metric" => "daily_cost", "as_of_date" => (Date.current - 1).iso8601,
             "amount" => 5, "source" => "manual", "confidence" => "metered" }
    OperatingCosts::Recorder.record!({ "observations" => [ item ] })

    result = OperatingCosts::Recorder.record!({ "observations" => [ item.merge("amount" => 7) ] })

    assert_equal 1, result.counts["observations"]["updated"]
    assert_equal 7, OperatingCostObservation.find_by!(source: "manual").amount_usd
    assert_equal 7, OperatingCostDailyEntry.find_by!(account: OperatingCostAccount.find_by!(key: "examplecloud-gw-app"),
                                                     date: Date.current - 1).amount_usd
  end

  test "only the daily job may write the derived source" do
    seed_operating_costs!
    item = { "account" => "voiceco-api", "metric" => "daily_cost", "as_of_date" => "2026-01-02", "amount" => 1,
             "source" => "derived", "confidence" => "estimated" }

    error = assert_raises(OperatingCosts::Recorder::Error) { OperatingCosts::Recorder.record!({ "observations" => [ item ] }) }
    assert_match "only the daily job", error.message
    assert OperatingCosts::Recorder.record!({ "observations" => [ item ] }, derived: true)
  end

  test "one bad item rolls the whole batch back and names itself" do
    payload = {
      "vendors" => [ { "key" => "fine", "name" => "Fine" } ],
      "accounts" => [ { "key" => "a", "label" => "A", "vendor" => "fine" }, { "key" => "b", "label" => "B", "vendor" => "nope" } ]
    }

    error = assert_raises(OperatingCosts::Recorder::Error) { OperatingCosts::Recorder.record!(payload, collector: "agent:test") }

    assert_equal "accounts[1]: Unknown vendor: nope", error.message
    assert_not OperatingCostVendor.exists?(key: "fine")
    assert_equal "failed", OperatingCostCollectionRun.sole.status, "a failed batch still answers 'has it run'"
  end

  test "an unknown payload key or an empty payload is refused" do
    assert_raises(OperatingCosts::Recorder::Error) { OperatingCosts::Recorder.record!({ "bills" => [] }) }
    assert_raises(OperatingCosts::Recorder::Error) { OperatingCosts::Recorder.record!({}) }
  end

  test "a non-USD figure needs its USD amount" do
    seed_operating_costs!
    payload = { "observations" => [ { "account" => "examplecloud-gw-app", "metric" => "daily_cost", "as_of_date" => "2026-01-02",
                                      "amount" => 10, "currency" => "EUR", "source" => "agent", "confidence" => "metered" } ] }

    error = assert_raises(OperatingCosts::Recorder::Error) { OperatingCosts::Recorder.record!(payload) }
    assert_match "Amount usd", error.message
  end

  test "a raw payload is redacted before it is stored" do
    seed_operating_costs!
    secret = "sk-ant-oat01-#{'a' * 80}"
    OperatingCosts::Recorder.record!({ "observations" => [ {
      "account" => "examplecloud-gw-app", "metric" => "daily_cost", "as_of_date" => "2026-01-02", "amount" => 1,
      "source" => "agent", "confidence" => "metered", "raw_payload" => { "token" => secret, "total" => 1 }
    } ] })

    stored = OperatingCostObservation.find_by!(as_of_date: Date.new(2026, 1, 2)).raw_payload
    assert_not_includes stored.to_json, secret
    assert_equal 1, stored["total"]
  end

  test "changing which roots a functionality claims re-splits months already allocated" do
    today = Date.current
    seed_operating_costs!(today: today)
    usage = { model: "claude-opus-5", called_at: (today - 1).beginning_of_day + 1.hour, input_tokens: 0, output_tokens: 1_000_000 }
    SessionTokenUsage.create!(usage.merge(request_id: "r1", agent_root: "other-root"))
    OperatingCostsCollectionJob.perform_now
    seats = OperatingCostAccount.find_by!(key: "modelco-seats")
    month = (today - 1).beginning_of_month
    assert_equal [ OperatingCostFunctionality.find_by!(key: "agent-inference").id ],
                 seats.monthly_allocations.where(month: month).pluck(:functionality_id).uniq

    OperatingCosts::Recorder.record!({ "functionalities" => [ { "key" => "voice", "agent_roots" => [ "other-root" ] } ] })

    assert_equal [ OperatingCostFunctionality.find_by!(key: "voice").id ],
                 seats.monthly_allocations.where(month: month).pluck(:functionality_id).uniq
  end
end
