# frozen_string_literal: true

require "test_helper"

class Mcp::Tools::GetOutcomeAnalysisTest < ActiveSupport::TestCase
  setup do
    @tool = Mcp::Tools::GetOutcomeAnalysis.new(context: Mcp::Context.new(tool_groups: "sessions_readonly"))
  end

  def archived(title:, created_at: 2.days.ago, model: "claude-opus-5", root: "zimmer")
    Session.create!(
      title: title, prompt: "x", git_root: "https://github.com/tadasant/zimmer.git",
      status: :archived, archived_at: 1.day.ago, created_at: created_at, agent_runtime: "claude_code",
      metadata: { "agent_root_key" => root }, config: { "model" => model }
    )
  end

  def segment(id, outcome, children: [], goal: "Goal #{id}")
    {
      "id" => id, "trigger" => { "kind" => "New", "source" => "agent" },
      "goal" => { "text" => goal, "kind" => "Action" },
      "outcome" => { "kind" => outcome, "explanation" => "#{outcome} at #{id}" }, "meta" => {}, "children" => children
    }
  end

  def analyze!(session, root)
    OutcomeAnalyses::Save.call(session: session, root: root)
  end

  # --- analysis view ------------------------------------------------------------

  test "session_id alone reads that session's analysis with its tree and a flat list of where it failed" do
    session = archived(title: "Recovered")
    analyze!(session, segment("S0", "Success", children: [
      segment("S0.0", "Failure", goal: "First try"),
      segment("S0.1", "Success", children: [ segment("S0.1.0", "Failure", goal: "Nested slip") ])
    ]))

    result = @tool.call("session_id" => session.id)

    assert_equal session.id, result[:session][:id]
    assert_equal "Success", result[:analysis][:root_outcome]
    assert_equal "S0", result[:analysis][:root]["id"], "the tree comes back whole"
    assert_equal 4, result[:analysis][:segment_count]
    assert_equal [ [ "S0.0", 1, "First try" ], [ "S0.1.0", 2, "Nested slip" ] ],
                 result[:failed_segments].map { |f| [ f[:id], f[:depth], f[:goal] ] }
    assert_equal "Failure at S0.0", result[:failed_segments].first[:explanation]
    assert_match %r{/outcomes/#{session.id}\z}, result[:view_url]
  end

  test "a re-analysis reads as the current one, with the earlier reading listed without its tree" do
    session = archived(title: "Twice")
    analyze!(session, segment("S0", "Failure"))
    analyze!(session, segment("S0", "Success"))

    result = @tool.call("view" => "analysis", "session_id" => session.id)

    assert_equal "Success", result[:analysis][:root_outcome]
    assert_equal [ "Failure" ], result[:previous_analyses].map { |a| a[:root_outcome] }
    assert_not result[:previous_analyses].first.key?(:root)
  end

  test "an unanalyzed session reads as null, and names the analysis in flight when there is one" do
    session = archived(title: "Pending")

    result = @tool.call("session_id" => session.id)
    assert_nil result[:analysis]
    assert_nil result[:analysis_in_flight]
    assert_equal "Not analyzed yet.", result[:note]

    analyzer = Session.create!(prompt: "a", git_root: "https://github.com/tadasant/zimmer.git", status: :waiting,
                               metadata: { Session::OUTCOME_ANALYSIS_MARKER => session.id.to_s })

    result = @tool.call("session_id" => session.id)
    assert_equal analyzer.id, result[:analysis_in_flight][:id]
    assert_match(/Session ##{analyzer.id} is analyzing it now/, result[:note])
  end

  test "says why a live session has no analysis" do
    result = @tool.call("session_id" => sessions(:running).id)

    assert_nil result[:analysis]
    assert_match(/Only archived sessions can be analyzed, and this one is running/, result[:note])
  end

  test "the analysis view needs a session" do
    error = assert_raises(Mcp::ToolError) { @tool.call("view" => "analysis") }
    assert_match(/needs a session_id/, error.message)
  end

  # --- ledger view --------------------------------------------------------------

  test "the ledger lists archived sessions matching the filters, with each one's analysis columns and the counts" do
    failed = archived(title: "Last week, failed", created_at: Date.new(2026, 9, 3).noon)
    passed = archived(title: "Last week, passed", created_at: Date.new(2026, 9, 4).noon)
    pending = archived(title: "Last week, pending", created_at: Date.new(2026, 9, 5).noon)
    archived(title: "Too old", created_at: Date.new(2026, 8, 1).noon)
    analyze!(failed, segment("S0", "Failure"))
    analyze!(passed, segment("S0", "Success"))

    week = { "from" => "2026-09-01", "to" => "2026-09-07", "agent_root" => "zimmer" }

    all = @tool.call(week)
    assert_equal({ total: 3, analyzed: 2, unanalyzed: 1 }, all[:counts])
    assert_equal [ pending.id, passed.id, failed.id ], all[:rows].map { |r| r[:session_id] }, "newest first"
    assert_nil all[:rows].first[:analysis]
    assert_equal "Failure", all[:rows].last[:analysis][:root_outcome]
    assert_equal "claude-opus-5", all[:rows].last[:model]
    assert_equal "zimmer", all[:rows].last[:agent_root]
    assert_equal({ "from" => "2026-09-01", "to" => "2026-09-07", "agent_root" => "zimmer" }, all[:filters][:applied])
    assert_equal false, all[:has_next_page]

    failures = @tool.call(week.merge("view" => "ledger", "outcome" => "Failure"))
    assert_equal [ failed.id ], failures[:rows].map { |r| r[:session_id] }
  end

  test "Zimmer's own analysis sessions are never on the ledger" do
    target = archived(title: "Target")
    Session.create!(prompt: "a", git_root: "https://github.com/tadasant/zimmer.git", status: :archived,
                    metadata: { "agent_root_key" => "zimmer", Session::OUTCOME_ANALYSIS_MARKER => target.id.to_s })

    assert_equal [ target.id ], @tool.call("agent_root" => "zimmer")[:rows].map { |r| r[:session_id] }
  end

  test "a filter value that names nothing is refused rather than silently dropped" do
    error = assert_raises(Mcp::ToolError) { @tool.call("view" => "ledger", "from" => "last tuesday") }
    assert_match(/"from" must be a date in YYYY-MM-DD form/, error.message)

    error = assert_raises(Mcp::ToolError) { @tool.call("view" => "stats", "agent_runtime" => "gpt-cli") }
    assert_match(/Unknown agent_runtime "gpt-cli"/, error.message)
    assert_match(/claude_code/, error.message)
  end

  # --- stats view ---------------------------------------------------------------

  test "stats aggregates current analyses by the chosen dimension without loading a tree" do
    a = archived(title: "A", model: "claude-opus-5")
    b = archived(title: "B", model: "claude-opus-5")
    c = archived(title: "C", model: "claude-sonnet-5")
    analyze!(a, segment("S0", "Success", children: [ segment("S0.0", "Failure") ]))
    analyze!(b, segment("S0", "Failure"))
    analyze!(c, segment("S0", "Success"))

    result = @tool.call("view" => "stats", "agent_root" => "zimmer", "group_by" => "model")

    assert_equal "model", result[:group_by]
    assert_equal 3, result[:totals][:transcripts]
    assert_equal 2, result[:totals][:successes]
    assert_equal 4, result[:totals][:segments]
    assert_equal 2, result[:totals][:failed_segments]
    assert_equal 0.5, result[:totals][:segment_success_rate]

    opus = result[:rows].find { |row| row[:key] == "claude-opus-5" }
    assert_equal 2, opus[:transcripts]
    assert_equal 0.5, opus[:transcript_success_rate]
    assert_equal 3, result[:rows].sum { |row| row[:transcripts] }

    assert_equal [ 1, 2, 0, 0, 0, 0 ], result[:failure_distribution].map { |bucket| bucket[:count] }
    assert_equal a.id, result[:worst_transcripts].first[:session_id], "the most failed segments first"
    assert_not result[:worst_transcripts].first.key?(:root)
  end

  # --- batches view -------------------------------------------------------------

  test "batches lists recent batches with who started them, and the MCP limits in force" do
    starter = sessions(:running)
    web = OutcomeAnalysisBatch.create!(filters: { "agent_root" => "zimmer" }, concurrency: 5, total_count: 0,
                                       status: OutcomeAnalysisBatch::COMPLETED)
    mcp = OutcomeAnalysisBatch.create!(filters: {}, concurrency: 2, total_count: 0,
                                       started_via: OutcomeAnalysisBatch::STARTED_VIA_MCP, started_by_session: starter)

    result = @tool.call("view" => "batches")

    assert_equal [ mcp.id, web.id ], result[:batches].first(2).map { |b| b[:id] }
    assert_equal "mcp", result[:batches].first[:started_via]
    assert_equal starter.id, result[:batches].first[:started_by_session_id]
    assert_equal "web_ui", result[:batches].second[:started_via]
    assert_equal "root zimmer", result[:batches].second[:filter_summary]
    assert_equal OutcomeAnalysisBatch::AGENT_MAX_CONCURRENCY, result[:agent_limits][:max_batch_concurrency]
    assert_equal mcp.id, result[:agent_limits][:running_mcp_batch_id]
  end

  test "the goal_checks view is the same tally the web page renders, with the filters it applied" do
    pr = "https://github.com/tadasant/zimmer/pull/11"
    router = archived(title: "Router", root: "zimmer-orchestrator")
    router.update!(goal: "open-reviewed-green-pr")
    child = archived(title: "Child")
    child.update!(goal: "open-reviewed-green-pr", parent_session_id: router.id, custom_metadata: {
      "github_pull_request_urls" => [ pr ], "github_pull_request_statuses" => { pr => "merged" },
      "github_pull_request_goal_facts" => {
        pr => { "verification_section" => true, "verification_checked_boxes" => 2, "unchecked_boxes" => 0, "labels" => [] }
      }
    })

    result = @tool.call("view" => "goal_checks", "agent_root" => "zimmer-orchestrator")

    assert_equal "zimmer-orchestrator", result[:filters][:applied]["agent_root"]
    assert_equal 1, result[:checked_sessions]
    assert_equal({ "met" => 1, "unmet" => 0, "pending" => 0 }, result[:verdicts])
    assert_equal 1, result[:delegated_sessions]
    assert_match %r{/outcomes/goal_checks\z}, result[:view_url]

    error = assert_raises(Mcp::ToolError) { @tool.call("view" => "goal_checks", "from" => "last week") }
    assert_match(/YYYY-MM-DD/, error.message)
  end

  test "one batch by id comes back with the error on each failed item" do
    target = archived(title: "Doomed")
    batch = OutcomeAnalysisBatch.create!(filters: {}, concurrency: 1, total_count: 1)
    batch.items.create!(session: target, state: OutcomeAnalysisBatchItem::FAILED, position: 0,
                        error: "The analysis session failed without saving an analysis.")

    result = @tool.call("view" => "batches", "batch_id" => batch.id)

    assert_equal batch.id, result[:batch][:id]
    assert_equal 1, result[:batch][:counts][:failed]
    assert_equal [ [ target.id, "The analysis session failed without saving an analysis." ] ],
                 result[:batch][:failed_items].map { |item| [ item[:session_id], item[:error] ] }

    error = assert_raises(Mcp::ToolError) { @tool.call("view" => "batches", "batch_id" => 0) }
    assert_match(/Batch not found/, error.message)
  end
end
