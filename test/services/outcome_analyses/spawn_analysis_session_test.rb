# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"

class OutcomeAnalyses::SpawnAnalysisSessionTest < ActiveSupport::TestCase
  setup do
    # The spawn's job is to produce a correctly configured Session row; actually
    # running an agent is AgentSessionJob's business and is not what this covers.
    AgentSessionJob.stubs(:enqueue_new_session).returns(nil)

    @target = Session.create!(
      title: "Fix the login redirect loop", prompt: "x",
      git_root: "https://github.com/tadasant/zimmer.git", status: :archived, archived_at: 1.day.ago
    )
  end

  test "spawns a spot-classed session on the configured root with the save tool's server" do
    analysis = OutcomeAnalyses::SpawnAnalysisSession.call(session: @target)

    assert_equal OutcomeAnalyses::Config.agent_root, analysis.metadata["agent_root_key"]
    assert_equal [ OutcomeAnalyses::Config.mcp_server_name ], analysis.mcp_servers
    assert_equal SessionGenesis::SPOT, analysis.scheduling_class
    assert_equal SessionGenesis::WEB_UI, analysis.genesis
  end

  test "is identifiable as an analysis session and stays out of the ledger" do
    analysis = OutcomeAnalyses::SpawnAnalysisSession.call(session: @target)

    assert_equal @target.id.to_s, analysis.metadata[Session::OUTCOME_ANALYSIS_MARKER]
    assert_includes Session.outcome_analysis_sessions, analysis
    refute_includes Session.excluding_outcome_analysis_sessions, analysis
  end

  test "titles the session after what it is analyzing" do
    analysis = OutcomeAnalyses::SpawnAnalysisSession.call(session: @target)

    assert_equal "Outcome analysis: Fix the login redirect loop", analysis.title
  end

  test "falls back to the session number when the target has no title" do
    @target.update!(title: nil)

    assert_equal "Outcome analysis: session ##{@target.id}", OutcomeAnalyses::SpawnAnalysisSession.call(session: @target).title
  end

  test "records the batch it belongs to" do
    batch = OutcomeAnalysisBatch.create!(filters: {}, concurrency: 1, total_count: 0)

    analysis = OutcomeAnalyses::SpawnAnalysisSession.call(session: @target, batch: batch)

    assert_equal batch.id.to_s, analysis.metadata["outcome_analysis_batch_id"]
  end

  test "attaches the analysis skill when the catalog has it" do
    OutcomeAnalyses::Config.stubs(:skill_available?).returns(true)
    OutcomeAnalyses::Config.stubs(:skill_id).returns("open-pr") # any real catalog id

    assert_equal [ "open-pr" ], OutcomeAnalyses::SpawnAnalysisSession.call(session: @target).catalog_skills
  end

  test "spawns without the skill rather than failing when the catalog lacks it" do
    OutcomeAnalyses::Config.stubs(:skill_available?).returns(false)

    analysis = OutcomeAnalyses::SpawnAnalysisSession.call(session: @target)

    assert_empty analysis.catalog_skills
    # The contract still reaches the session, so it can do the job unaided.
    assert_match(/is not in this deployment's catalog yet/, analysis.prompt)
    assert_match(/save_outcome_analysis/, analysis.prompt)
  end

  test "the prompt carries the schema the save tool enforces" do
    prompt = OutcomeAnalyses::SpawnAnalysisSession.call(session: @target).prompt

    assert_match(/Trigger → Goal → Outcome/, prompt)
    assert_match(/Outcome is local/, prompt)
    assert_match(/#{OutcomeAnalyses::SegmentTree::EXPLANATION_MAX} characters/, prompt)
    assert_match(/depth-first/i, prompt)
    assert_match(/##{@target.id}/, prompt)
  end

  test "refuses to analyze a session that is not archived" do
    @target.update!(status: :needs_input)

    assert_raises(OutcomeAnalyses::SpawnAnalysisSession::Error) do
      OutcomeAnalyses::SpawnAnalysisSession.call(session: @target)
    end
  end

  test "reports what is missing from the catalog without raising" do
    OutcomeAnalyses::Config.stubs(:skill_available?).returns(false)

    reasons = OutcomeAnalyses::Config.unavailable_reasons

    assert_equal 1, reasons.size
    assert_match(/#{OutcomeAnalyses::Config.skill_id}/, reasons.first)
  end
end
