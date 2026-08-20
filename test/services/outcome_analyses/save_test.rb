# frozen_string_literal: true

require "test_helper"

class OutcomeAnalyses::SaveTest < ActiveSupport::TestCase
  setup do
    @session = Session.create!(
      title: "Analyzed transcript", prompt: "x", git_root: "https://github.com/tadasant/zimmer.git",
      status: :archived, archived_at: 1.day.ago, agent_runtime: "codex",
      config: { "model" => "gpt-5.6-terra" }, metadata: { "agent_root_key" => "zimmer" }
    )
  end

  def tree(outcome: "Success", children: [])
    {
      "id" => "S0",
      "trigger" => { "kind" => "New", "source" => "user" },
      "goal" => { "text" => "Ship the change", "kind" => "Action" },
      "outcome" => { "kind" => outcome, "explanation" => "Landed." },
      "meta" => {},
      "children" => children
    }
  end

  def child(id, outcome: "Failure")
    {
      "id" => id, "trigger" => { "kind" => "New", "source" => "agent" },
      "goal" => { "text" => "Try it", "kind" => "Plan" },
      "outcome" => { "kind" => outcome, "explanation" => "Nope." }, "meta" => {}, "children" => []
    }
  end

  test "denormalizes the session's attributes and the tree's counts" do
    result = OutcomeAnalyses::Save.call(session: @session, root: tree(children: [ child("S0.0") ]))
    analysis = result.analysis

    assert_equal "zimmer", analysis.agent_root
    assert_equal "codex", analysis.agent_runtime
    assert_equal "gpt-5.6-terra", analysis.model
    assert_equal @session.created_at.to_i, analysis.session_created_at.to_i
    assert_equal "Success", analysis.root_outcome
    assert_equal 2, analysis.segment_count
    assert_equal 1, analysis.failure_segment_count
    assert_equal 2, analysis.max_depth
    assert_not result.superseded
  end

  test "re-analysis supersedes rather than duplicating" do
    first = OutcomeAnalyses::Save.call(session: @session, root: tree).analysis
    second = OutcomeAnalyses::Save.call(session: @session, root: tree(outcome: "Failure"))

    assert second.superseded
    assert_equal 1, OutcomeAnalysis.current.where(session: @session).count
    assert_equal second.analysis.id, OutcomeAnalysis.current.find_by(session: @session).id
    assert first.reload.superseded_at.present?
    # The earlier reading is kept, not destroyed.
    assert_equal 2, OutcomeAnalysis.where(session: @session).count
  end

  test "the database refuses two current analyses for one session" do
    OutcomeAnalyses::Save.call(session: @session, root: tree)

    assert_raises(ActiveRecord::RecordNotUnique) do
      OutcomeAnalysis.create!(
        session: @session, schema_version: "1", root: tree, agent_runtime: "codex",
        session_created_at: @session.created_at, root_outcome: "Success",
        segment_count: 1, failure_segment_count: 0, max_depth: 1, analyzed_at: Time.current
      )
    end
  end

  test "refuses a session that is not archived" do
    live = Session.create!(prompt: "x", git_root: "https://github.com/tadasant/zimmer.git", status: :needs_input)

    error = assert_raises(OutcomeAnalyses::Save::UnanalyzableSession) do
      OutcomeAnalyses::Save.call(session: live, root: tree)
    end
    assert_match(/Only archived sessions can be analyzed/, error.message)
  end

  test "refuses to analyze one of Zimmer's own analysis sessions" do
    analyzer = Session.create!(
      prompt: "x", git_root: "https://github.com/tadasant/zimmer.git", status: :archived,
      metadata: { Session::OUTCOME_ANALYSIS_MARKER => @session.id.to_s }
    )

    error = assert_raises(OutcomeAnalyses::Save::UnanalyzableSession) do
      OutcomeAnalyses::Save.call(session: analyzer, root: tree)
    end
    # The ledger excludes these, so an analysis of one would be a row only the
    # stats view could see — the two would disagree about how many exist.
    assert_match(/itself an outcome-analysis session/, error.message)
  end

  test "caps notes rather than storing an essay" do
    analysis = OutcomeAnalyses::Save.call(session: @session, root: tree, notes: "n" * 5_000).analysis

    assert_equal OutcomeAnalyses::SegmentTree::NOTES_MAX, analysis.notes.length
  end

  test "stores nothing when the tree is invalid" do
    assert_no_difference -> { OutcomeAnalysis.count } do
      assert_raises(OutcomeAnalyses::SegmentTree::InvalidTree) do
        OutcomeAnalyses::Save.call(session: @session, root: tree.merge("id" => "S9"))
      end
    end
  end

  test "records the analyzer session when one is named" do
    analyzer = Session.create!(prompt: "x", git_root: "https://github.com/tadasant/zimmer.git", status: :archived)

    analysis = OutcomeAnalyses::Save.call(session: @session, root: tree, analyzer_session: analyzer).analysis

    assert_equal analyzer.id, analysis.analyzer_session_id
  end

  test "deleting the analyzed session takes its analyses with it" do
    OutcomeAnalyses::Save.call(session: @session, root: tree)

    assert_difference -> { OutcomeAnalysis.count }, -1 do
      @session.destroy!
    end
  end

  test "deleting the analyzer session leaves the analysis standing" do
    analyzer = Session.create!(prompt: "x", git_root: "https://github.com/tadasant/zimmer.git", status: :archived)
    analysis = OutcomeAnalyses::Save.call(session: @session, root: tree, analyzer_session: analyzer).analysis

    analyzer.destroy!

    assert_nil analysis.reload.analyzer_session_id
    assert_equal "Success", analysis.root_outcome
  end
end
