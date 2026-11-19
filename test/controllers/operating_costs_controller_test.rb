# frozen_string_literal: true

require "test_helper"

class OperatingCostsControllerTest < ActionDispatch::IntegrationTest
  include OperatingCostFixtures

  test "renders the empty state before anything is recorded" do
    get operating_costs_path

    assert_response :success
    assert_select "h1", "Costs"
    assert_select "#costs-empty"
    assert_match "OperatingCostsCollectionJob", response.body
  end

  test "renders every section once costs exist" do
    seed_operating_costs!

    get operating_costs_path

    assert_response :success
    assert_select "#costs-tiles"
    assert_select "#costs-monthly"
    assert_select "#costs-by-functionality", text: /Gateway infrastructure/
    assert_select "#costs-by-vendor", text: /ExampleCloud/
    assert_select "#costs-by-agent-root"
    assert_select "#costs-credits", text: /VoiceCo API/
    assert_select "#costs-subscriptions", text: /Team × 2/
    assert_select "#costs-paid-by-others", text: /example-org/
    assert_select "#costs-sources", text: %r{agent:fixture}
    assert_select "#costs-manage form", minimum: 8
  end

  test "an account billed in arrears shows its accrued month to date as an estimate, not as zero" do
    travel_to Time.zone.local(2026, 11, 17, 12) do
      seed_operating_costs!(today: Date.current)
      OperatingCostsCollectionJob.perform_now

      get operating_costs_path

      assert_select "#costs-tiles", text: /incl\. \$[0-9.]+ estimated/
      assert_select "#costs-by-functionality", text: /Gateway infrastructure.*estimated\)/m
      assert_select "#costs-by-functionality", text: /not billed yet this month/
    end
  end

  test "an externally paid account is listed but kept out of the functionality breakdown" do
    seed_operating_costs!

    get operating_costs_path

    assert_select "#costs-by-functionality", text: /CI runner/, count: 0
    assert_select "#costs-paid-by-others", text: /CI runner/

    get operating_costs_path(include_external: "1")
    assert_select "#costs-by-functionality", text: /CI runner/
  end

  test "narrowing to one functionality keeps only its rows and offers a way back" do
    seed_operating_costs!

    get operating_costs_path(functionality: "voice")

    assert_response :success
    assert_select "#costs-by-vendor", text: /VoiceCo/
    assert_select "#costs-by-vendor", text: /ExampleCloud/, count: 0
    assert_select "a[href=?]", operating_costs_path(month: Date.current.strftime("%Y-%m"))
  end

  test "an unknown filter or a bad month says so instead of failing" do
    get operating_costs_path(vendor: "nope")
    assert_response :success
    assert_match "Unknown vendor: nope", response.body

    get operating_costs_path(month: "banana")
    assert_response :success
    assert_match "month must be YYYY-MM", response.body
  end

  test "a past month shows that month's total and no projection" do
    seed_operating_costs!
    month = (Date.current << 2).strftime("%Y-%m")

    get operating_costs_path(month: month)

    assert_response :success
    assert_select "#costs-month", (Date.current << 2).strftime("%B %Y")
  end

  test "the forms write through the shared action set" do
    post operating_costs_actions_path, params: {
      operation: "upsert_vendor", item: { key: "newco", name: "NewCo", category: "saas", pricing_model: "subscription",
                                          ingest_method: "manual", active: "1" }
    }
    assert_redirected_to operating_costs_path
    assert_equal "NewCo", OperatingCostVendor.find_by!(key: "newco").name

    post operating_costs_actions_path, params: {
      operation: "upsert_functionality", item: { key: "chat", name: "Chat", agent_roots: "root-a\nroot-b", active: "1" }
    }
    assert_equal %w[root-a root-b], OperatingCostFunctionality.find_by!(key: "chat").agent_roots

    post operating_costs_actions_path, params: {
      operation: "upsert_account", item: { key: "newco-seat", label: "NewCo seat", vendor: "newco", functionality: "chat",
                                           allocation_rule: "direct_root", allocation_config: '{"agent_roots":["root-a"]}', active: "1" }
    }
    account = OperatingCostAccount.find_by!(key: "newco-seat")
    assert_equal({ "agent_roots" => [ "root-a" ] }, account.allocation_config)

    post operating_costs_actions_path, params: {
      operation: "upsert_subscription", item: { account: "newco-seat", plan_name: "Pro", amount: "12", interval: "month",
                                                quantity: "1", started_on: (Date.current << 1).iso8601, auto_renew: "1" }
    }
    assert account.reload.daily_entries.exists?, "the subscription accrues as soon as it is saved"
    assert_match "1 created", flash[:notice]
  end

  test "editing one field of an existing account from the form leaves the rest alone" do
    seed_operating_costs!
    before = OperatingCostAccount.find_by!(key: "voiceco-api").as_api_json

    post operating_costs_actions_path, params: {
      operation: "upsert_account",
      item: { key: "voiceco-api", label: "Renamed", vendor: "", functionality: "", paid_by: "", allocation_rule: "",
              allocation_config: "", derived_source: "", active: "", agent_roots: "" }
    }

    after = OperatingCostAccount.find_by!(key: "voiceco-api").as_api_json
    assert_equal "Renamed", after[:label]
    assert_equal before.except(:label), after.except(:label)

    post operating_costs_actions_path, params: { operation: "upsert_account", item: { key: "voiceco-api", functionality: "unattributed", derived_source: "none" } }
    account = OperatingCostAccount.find_by!(key: "voiceco-api")
    assert_nil account.functionality
    assert_nil account.derived_source
  end

  test "a non-USD credit balance can be recorded from the page" do
    seed_operating_costs!

    post operating_costs_actions_path, params: {
      operation: "upsert_credit_snapshot",
      item: { account: "voiceco-api", as_of_date: "2026-01-05", balance: "10", currency: "EUR", balance_usd: "11", kind: "prepaid", source: "manual" }
    }

    assert_equal 11, OperatingCostCreditSnapshot.find_by!(as_of_date: Date.new(2026, 1, 5)).balance_usd
  end

  test "a form error comes back as an alert, keeping the filters" do
    post operating_costs_actions_path, params: { operation: "upsert_account", item: { key: "x", label: "X", vendor: "missing" },
                                                 return_to: { month: "2026-01" } }

    assert_redirected_to operating_costs_path(month: "2026-01")
    assert_match "Unknown vendor: missing", flash[:alert]
  end

  test "collect now enqueues the daily job" do
    assert_enqueued_with(job: OperatingCostsCollectionJob) do
      post operating_costs_actions_path, params: { operation: "collect_now" }
    end
    assert_redirected_to operating_costs_path
  end

  test "deleting a figure rebuilds its account" do
    seed_operating_costs!
    observation = OperatingCostObservation.find_by!(metric: "daily_cost", as_of_date: Date.current - 1)

    post operating_costs_actions_path, params: { operation: "delete_observation", id: observation.id }

    assert_not OperatingCostObservation.exists?(observation.id)
    assert_not OperatingCostDailyEntry.exists?(account_id: observation.account_id, date: Date.current - 1)
  end

  test "an old session-scoped /costs link lands on Token Spend" do
    get "/costs?session_id=42&days=7"

    assert_redirected_to "/token-spend?session_id=42&days=7"
  end

  test "the dashboard menu lists Costs directly above Token Spend" do
    get root_path

    body = response.body
    positions = [ body.index(">\n                Costs\n"), body.index(">\n                Token Spend\n") ]
    assert positions.all?, "menu entries missing"
    assert_equal positions.sort, positions
    assert_select "a[href=?]", operating_costs_path, minimum: 2
    assert_select "a[href=?]", token_spend_path, minimum: 2
  end
end
