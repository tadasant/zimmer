# frozen_string_literal: true

require "test_helper"

class OutcomeAnalyses::LedgerQueryTest < ActiveSupport::TestCase
  setup do
    # The fixture set carries archived sessions of its own, and this class is
    # about exactly which rows the ledger returns. Clear the table so the
    # assertions are about the query rather than about the fixtures.
    Session.delete_all

    @archived = create_session(title: "Archived", status: :archived, runtime: "claude_code", model: "opus", root: "zimmer")
    @other_root = create_session(title: "Other root", status: :archived, runtime: "codex", model: "gpt-5.6-terra", root: "agents")
    @live = create_session(title: "Still going", status: :needs_input, runtime: "claude_code", model: "opus", root: "zimmer")
  end

  def create_session(title:, status:, runtime:, model:, root:, created_at: 2.days.ago, metadata: {})
    Session.create!(
      title: title, prompt: "x", git_root: "https://github.com/tadasant/zimmer.git",
      status: status, archived_at: (status == :archived ? 1.day.ago : nil), agent_runtime: runtime,
      config: { "model" => model }, metadata: { "agent_root_key" => root }.merge(metadata),
      created_at: created_at
    )
  end

  def analyze!(session, outcome: "Success", failures: 0)
    children = Array.new(failures) do |i|
      { "id" => "S0.#{i}", "trigger" => { "kind" => "New", "source" => "agent" },
        "goal" => { "text" => "g", "kind" => "Plan" },
        "outcome" => { "kind" => "Failure", "explanation" => "no" }, "meta" => {}, "children" => [] }
    end
    OutcomeAnalyses::Save.call(session: session, root: {
      "id" => "S0", "trigger" => { "kind" => "New", "source" => "user" },
      "goal" => { "text" => "g", "kind" => "Action" },
      "outcome" => { "kind" => outcome, "explanation" => "e" }, "meta" => {}, "children" => children
    }).analysis
  end

  def query(params = {}) = OutcomeAnalyses::LedgerQuery.new(OutcomeAnalyses::LedgerFilters.from_params(params))

  test "lists only archived sessions" do
    ids = query.rows.map(&:id)

    assert_includes ids, @archived.id
    refute_includes ids, @live.id
  end

  test "excludes the analysis sessions Zimmer spawns for this feature" do
    analyzer = create_session(title: "Outcome analysis: x", status: :archived, runtime: "claude_code",
                              model: "opus", root: "general-agent",
                              metadata: { Session::OUTCOME_ANALYSIS_MARKER => @archived.id.to_s })

    refute_includes query.rows.map(&:id), analyzer.id
  end

  test "attaches the current analysis without selecting the tree" do
    analyze!(@archived, failures: 2)

    row = query.rows.find { |r| r.id == @archived.id }

    assert_equal "Success", row.analysis_root_outcome
    assert_equal 3, row.analysis_segment_count
    assert_equal 2, row.analysis_failure_segment_count
    # The Segment tree is deliberately not in the payload — that is what keeps a
    # ledger of thousands of rows cheap.
    refute row.attributes.key?("root")
  end

  test "a superseded analysis does not show on the row" do
    analyze!(@archived)
    analyze!(@archived, outcome: "Failure")

    row = query.rows.find { |r| r.id == @archived.id }

    assert_equal "Failure", row.analysis_root_outcome
    assert_equal 1, OutcomeAnalysis.current.where(session: @archived).count
  end

  test "filters by agent root, harness and model" do
    assert_equal [ @archived.id ], query(agent_root: "zimmer").rows.map(&:id)
    assert_equal [ @other_root.id ], query(agent_runtime: "codex").rows.map(&:id)
    assert_equal [ @other_root.id ], query(model: "gpt-5.6-terra").rows.map(&:id)
  end

  test "an unknown harness is ignored rather than matching nothing" do
    assert_equal query.rows.map(&:id).sort, query(agent_runtime: "not-a-runtime").rows.map(&:id).sort
  end

  test "filters by created-at window, inclusive of the end day" do
    old = create_session(title: "Old", status: :archived, runtime: "claude_code", model: "opus",
                         root: "zimmer", created_at: 40.days.ago)

    recent = query(from: 10.days.ago.to_date.to_s).rows.map(&:id)
    assert_includes recent, @archived.id
    refute_includes recent, old.id

    # `to` is a date, so it has to cover the whole of that day.
    same_day = query(to: @archived.created_at.to_date.to_s).rows.map(&:id)
    assert_includes same_day, @archived.id
  end

  test "filters by analyzed and by transcript outcome" do
    analyze!(@archived, outcome: "Failure")

    assert_equal [ @archived.id ], query(analyzed: "yes").rows.map(&:id)
    assert_equal [ @other_root.id ], query(analyzed: "no").rows.map(&:id)
    assert_equal [ @archived.id ], query(outcome: "Failure").rows.map(&:id)
    assert_empty query(outcome: "Success").rows.map(&:id)
  end

  test "counts total, analyzed and pending in one pass" do
    analyze!(@archived)

    assert_equal({ total: 2, analyzed: 1, unanalyzed: 1 }, query.counts)
  end

  test "analyzable_session_ids skips what is already analyzed" do
    analyze!(@archived)

    assert_equal [ @other_root.id ], query.analyzable_session_ids
  end

  test "model_options lists distinct models on archived sessions" do
    assert_equal [ "gpt-5.6-terra", "opus" ], OutcomeAnalyses::LedgerQuery.model_options
  end

  test "renders a large ledger in a bounded number of queries" do
    30.times { |i| create_session(title: "Bulk #{i}", status: :archived, runtime: "claude_code", model: "opus", root: "zimmer") }
    Session.archived.limit(15).each { |s| analyze!(s, failures: 2) }

    count = 0
    counter = ->(*, payload) { count += 1 unless payload[:name].to_s.in?([ "SCHEMA", "TRANSACTION" ]) }
    ActiveSupport::Notifications.subscribed(counter, "sql.active_record") do
      query.rows.to_a
    end

    assert_equal 1, count, "the ledger must be one query regardless of how many rows it returns"
  end
end
