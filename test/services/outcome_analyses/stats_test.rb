# frozen_string_literal: true

require "test_helper"

class OutcomeAnalyses::StatsTest < ActiveSupport::TestCase
  setup do
    Session.delete_all

    # Two harnesses, deliberately different shapes: claude_code always succeeds
    # overall but carries failed segments; codex has an abandoned transcript.
    analyze(runtime: "claude_code", model: "opus", root: "zimmer", outcome: "Success", failures: 2, successes: 3)
    analyze(runtime: "claude_code", model: "opus", root: "zimmer", outcome: "Success", failures: 1, successes: 4)
    analyze(runtime: "codex", model: "gpt-5.6-terra", root: "agents", outcome: "Failure", failures: 6, successes: 1)
    analyze(runtime: "codex", model: "gpt-5.6-terra", root: "agents", outcome: "Success", failures: 0, successes: 2)
  end

  def analyze(runtime:, model:, root:, outcome:, failures:, successes:, created_at: 2.days.ago)
    session = Session.create!(
      title: "S", prompt: "x", git_root: "https://github.com/tadasant/zimmer.git", status: :archived,
      archived_at: 1.day.ago, agent_runtime: runtime, config: { "model" => model },
      metadata: { "agent_root_key" => root }, created_at: created_at
    )
    children = []
    failures.times { |i| children << leaf("S0.#{children.size}", "Failure") }
    successes.times { children << leaf("S0.#{children.size}", "Success") }

    OutcomeAnalyses::Save.call(session: session, root: {
      "id" => "S0", "trigger" => { "kind" => "New", "source" => "user" },
      "goal" => { "text" => "g", "kind" => "Action" },
      "outcome" => { "kind" => outcome, "explanation" => "e" }, "meta" => {}, "children" => children
    }).analysis
  end

  def leaf(id, outcome)
    { "id" => id, "trigger" => { "kind" => "New", "source" => "agent" },
      "goal" => { "text" => "g", "kind" => "Plan" },
      "outcome" => { "kind" => outcome, "explanation" => "e" }, "meta" => {}, "children" => [] }
  end

  def stats(params = {}, grouping: "agent_runtime")
    OutcomeAnalyses::Stats.new(filters: OutcomeAnalyses::LedgerFilters.from_params(params), grouping: grouping)
  end

  test "transcript-level and segment-level rates are different numbers" do
    totals = stats.totals

    assert_equal 4, totals.transcripts
    assert_equal 3, totals.successes
    assert_equal 1, totals.failures
    assert_in_delta 0.75, totals.transcript_success_rate
    # 4 roots + 9 failed leaves + 10 successful leaves = 23 segments, 9 failed.
    assert_equal 23, totals.segments
    # The failed ROOT of the abandoned codex transcript is itself a failed segment.
    assert_equal 10, totals.failed_segments
    assert_in_delta 13 / 23.0, totals.segment_success_rate
  end

  test "groups by harness, busiest first" do
    rows = stats.rows

    assert_equal %w[claude_code codex], rows.map(&:key).sort
    claude = rows.find { |r| r.key == "claude_code" }
    assert_equal 2, claude.transcripts
    assert_in_delta 1.0, claude.transcript_success_rate
    assert_in_delta 1.5, claude.avg_failed_segments
  end

  test "groups by model and by agent root" do
    assert_equal %w[gpt-5.6-terra opus], stats({}, grouping: "model").rows.map(&:key).sort
    assert_equal %w[agents zimmer], stats({}, grouping: "agent_root").rows.map(&:key).sort
  end

  test "an unknown grouping falls back to the default rather than erroring" do
    assert_equal OutcomeAnalyses::Stats::DEFAULT_GROUPING, stats({}, grouping: "colour").grouping
  end

  test "windows on the analyzed session's created_at, not on when it was analyzed" do
    analyze(runtime: "codex", model: "gpt-5.6-terra", root: "agents", outcome: "Success",
            failures: 0, successes: 1, created_at: 200.days.ago)

    assert_equal 5, stats.totals.transcripts
    assert_equal 4, stats({ from: 30.days.ago.to_date.to_s }).totals.transcripts
  end

  test "filters narrow the population the same way the ledger's do" do
    assert_equal 2, stats({ agent_runtime: "codex" }).totals.transcripts
    assert_equal 2, stats({ model: "opus" }).totals.transcripts
    assert_equal 2, stats({ agent_root: "agents" }).totals.transcripts
    assert_equal 1, stats({ outcome: "Failure" }).totals.transcripts
  end

  test "failure distribution buckets the population" do
    distribution = stats.failure_distribution.index_by { |b| b[:label] }

    assert_equal 1, distribution["0"][:count]
    assert_equal 1, distribution["1"][:count]
    assert_equal 1, distribution["2"][:count]
    assert_equal 1, distribution["6–10"][:count]
    assert_equal OutcomeAnalyses::Stats::DISTRIBUTION_BUCKETS.size, stats.failure_distribution.size
  end

  test "worst transcripts are ranked by failed segments and carry no tree" do
    worst = stats.worst_transcripts(limit: 2)

    assert_equal 7, worst.first.failure_segment_count
    refute worst.first.attributes.key?("root")
  end

  test "an empty population reports nothing rather than dividing by zero" do
    empty = stats({ agent_root: "general-agent" })

    refute empty.any?
    assert_equal 0, empty.totals.transcripts
    assert_nil empty.totals.transcript_success_rate
    assert_nil empty.totals.segment_success_rate
    assert_in_delta 0.0, empty.totals.avg_failed_segments
  end

  test "superseded analyses are excluded" do
    session = OutcomeAnalysis.current.first.session
    OutcomeAnalyses::Save.call(session: session, root: {
      "id" => "S0", "trigger" => { "kind" => "New", "source" => "user" },
      "goal" => { "text" => "g", "kind" => "Action" },
      "outcome" => { "kind" => "Failure", "explanation" => "e" }, "meta" => {}, "children" => []
    })

    assert_equal 4, stats.totals.transcripts
  end

  test "grouping is one query regardless of population size" do
    count = 0
    counter = ->(*, payload) { count += 1 unless payload[:name].to_s.in?([ "SCHEMA", "TRANSACTION" ]) }
    ActiveSupport::Notifications.subscribed(counter, "sql.active_record") { stats.rows }

    assert_equal 1, count
  end
end
