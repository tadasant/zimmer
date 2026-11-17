# frozen_string_literal: true

# An invented deployment for the operating-cost tests: made-up vendors, made-up
# accounts, made-up amounts. Nothing here is a real vendor or a real figure —
# tadasant/zimmer is public, and the taxonomy is deployment data anyway.
module OperatingCostFixtures
  def operating_cost_payload(today: Date.current)
    {
      "functionalities" => [
        { "key" => "listing-search", "name" => "Listing search", "agent_roots" => [ "example-search" ], "position" => 1 },
        { "key" => "voice", "name" => "Voice", "position" => 2 },
        { "key" => "gateway-infra", "name" => "Gateway infrastructure", "position" => 3 },
        { "key" => "agent-inference", "name" => "Agent inference", "position" => 4 }
      ],
      "vendors" => [
        { "key" => "acme-scrape", "name" => "Acme Scrape", "category" => "data", "pricing_model" => "plan_with_included_usage", "ingest_method" => "agent" },
        { "key" => "examplecloud", "name" => "ExampleCloud", "category" => "infrastructure", "ingest_method" => "agent" },
        { "key" => "voiceco", "name" => "VoiceCo", "category" => "inference", "pricing_model" => "prepaid_credits", "ingest_method" => "derived" },
        { "key" => "modelco", "name" => "ModelCo", "category" => "inference", "pricing_model" => "subscription", "ingest_method" => "manual" },
        { "key" => "ci-host", "name" => "CI Host", "category" => "developer_tools", "ingest_method" => "agent" }
      ],
      "accounts" => [
        { "key" => "acme-scrape-plan", "label" => "Acme Scrape plan", "vendor" => "acme-scrape", "functionality" => "listing-search" },
        { "key" => "examplecloud-gw-app", "label" => "Gateway app", "vendor" => "examplecloud", "functionality" => "gateway-infra" },
        { "key" => "examplecloud-gw-db", "label" => "Gateway database", "vendor" => "examplecloud", "functionality" => "gateway-infra" },
        { "key" => "voiceco-api", "label" => "VoiceCo API", "vendor" => "voiceco", "functionality" => "voice",
          "derived_source" => "live_voice_metered", "allocation_rule" => "direct_root", "allocation_config" => { "agent_roots" => [ "live-mode" ] } },
        { "key" => "modelco-seats", "label" => "ModelCo seats", "vendor" => "modelco", "functionality" => "agent-inference",
          "allocation_rule" => "token_spend_share" },
        { "key" => "ci-runner", "label" => "CI runner", "vendor" => "ci-host", "paid_by" => "example-org" }
      ],
      "subscriptions" => [
        { "account" => "acme-scrape-plan", "plan_name" => "Starter", "amount" => 49, "interval" => "month", "included_usage_usd" => 49,
          "started_on" => (today << 8).iso8601 },
        { "account" => "modelco-seats", "plan_name" => "Team", "amount" => 100, "interval" => "month", "quantity" => 2,
          "started_on" => (today << 8).iso8601, "renews_on" => (today + 12).iso8601 }
      ],
      "observations" => (1..6).flat_map do |n|
        month = (today << n).beginning_of_month
        [
          { "account" => "examplecloud-gw-app", "metric" => "invoice", "period_start" => month.iso8601,
            "period_end" => month.end_of_month.iso8601, "amount" => 24 + n, "source" => "agent", "confidence" => "billed" },
          { "account" => "examplecloud-gw-db", "metric" => "invoice", "period_start" => month.iso8601,
            "period_end" => month.end_of_month.iso8601, "amount" => 15, "source" => "agent", "confidence" => "billed" },
          { "account" => "ci-runner", "metric" => "invoice", "period_start" => month.iso8601,
            "period_end" => month.end_of_month.iso8601, "amount" => 30, "source" => "agent", "confidence" => "billed" }
        ]
      end + (1..40).map do |d|
        { "account" => "voiceco-api", "metric" => "daily_cost", "as_of_date" => (today - d).iso8601, "amount" => 0.8,
          "source" => "agent", "confidence" => "metered" }
      end,
      "credit_snapshots" => (0..4).map do |w|
        { "account" => "voiceco-api", "as_of_date" => (today - 1 - 7 * w).iso8601, "balance" => 20 + 7 * w * 0.8,
          "kind" => "prepaid", "source" => "agent" }
      end
    }
  end

  def seed_operating_costs!(today: Date.current)
    OperatingCosts::Recorder.record!(operating_cost_payload(today: today), collector: "agent:fixture", today: today)
  end
end
