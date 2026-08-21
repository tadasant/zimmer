# frozen_string_literal: true

require "test_helper"

class Mcp::Tools::SaveOutcomeAnalysisTest < ActiveSupport::TestCase
  setup do
    @tool = Mcp::Tools::SaveOutcomeAnalysis.new(context: Mcp::Context.new(tool_groups: "sessions"))
    @session = sessions(:archived)
  end

  def tree(outcome: "Success", children: [])
    {
      "id" => "S0",
      "trigger" => { "kind" => "New", "source" => "user" },
      "goal" => { "text" => "Ship it", "kind" => "Action" },
      "outcome" => { "kind" => outcome, "explanation" => "It shipped." },
      "meta" => { "event_range" => nil, "wall_clock_s" => nil, "tokens_in" => nil, "tokens_out" => nil, "model" => nil },
      "children" => children
    }
  end

  def failed_child(id)
    { "id" => id, "trigger" => { "kind" => "New", "source" => "agent" },
      "goal" => { "text" => "Try", "kind" => "Plan" },
      "outcome" => { "kind" => "Failure", "explanation" => "Did not work." }, "meta" => {}, "children" => [] }
  end

  test "saves an analysis and reports what it stored" do
    output = @tool.call("session_id" => @session.id, "schema_version" => "1", "root" => tree(children: [ failed_child("S0.0") ]))

    analysis = OutcomeAnalysis.current.find_by(session_id: @session.id)
    assert_equal "Success", analysis.root_outcome
    assert_equal 2, analysis.segment_count
    assert_equal 1, analysis.failure_segment_count
    assert_includes output, "Outcome analysis saved"
    assert_includes output, "- **Root outcome:** Success"
    assert_includes output, "- **Segments:** 2 (1 Failure, 1 Success)"
    assert_includes output, "/outcomes/#{@session.id}"
  end

  test "accepts a slug as well as an id" do
    @session.update!(slug: "the-archived-one")

    @tool.call("session_id" => "the-archived-one", "root" => tree)

    assert OutcomeAnalysis.current.exists?(session_id: @session.id)
  end

  test "a second save supersedes and says so" do
    @tool.call("session_id" => @session.id, "root" => tree)

    output = @tool.call("session_id" => @session.id, "root" => tree(outcome: "Failure"))

    assert_includes output, "superseded the previous analysis"
    assert_equal 1, OutcomeAnalysis.current.where(session_id: @session.id).count
    assert_equal "Failure", OutcomeAnalysis.current.find_by(session_id: @session.id).root_outcome
  end

  test "rejects a malformed tree with every problem named and stores nothing" do
    bad = tree.merge("id" => "S1", "outcome" => { "kind" => "Success", "explanation" => "" })

    error = assert_raises(Mcp::ToolError) { @tool.call("session_id" => @session.id, "root" => bad) }

    assert_match(/nothing was saved/, error.message)
    assert_match(/depth-first position makes it "S0"/, error.message)
    assert_match(/explanation is required/, error.message)
    assert_equal 0, OutcomeAnalysis.where(session_id: @session.id).count
  end

  test "refuses a session that is not archived" do
    live = sessions(:running)

    error = assert_raises(Mcp::ToolError) { @tool.call("session_id" => live.id, "root" => tree) }

    assert_match(/Only archived sessions can be analyzed/, error.message)
  end

  test "refuses an unknown session" do
    assert_raises(Mcp::ToolError) { @tool.call("session_id" => 999_999_999, "root" => tree) }
  end

  test "records the analyzer session" do
    analyzer = sessions(:waiting)

    @tool.call("session_id" => @session.id, "analyzer_session_id" => analyzer.id, "root" => tree)

    assert_equal analyzer.id, OutcomeAnalysis.current.find_by(session_id: @session.id).analyzer_session_id
  end

  test "a stale analyzer id costs the provenance link, not the analysis" do
    @tool.call("session_id" => @session.id, "analyzer_session_id" => 999_999_999, "root" => tree)

    analysis = OutcomeAnalysis.current.find_by(session_id: @session.id)
    assert analysis.present?
    assert_nil analysis.analyzer_session_id
  end

  test "is served by the sessions group and by nothing narrower" do
    sessions_tools = Mcp::Registry.tools_for([ "sessions" ]).map(&:tool_name)
    self_session_tools = Mcp::Registry.tools_for([ "self_session" ]).map(&:tool_name)
    readonly_tools = Mcp::Registry.tools_for([ "sessions_readonly" ]).map(&:tool_name)

    assert_includes sessions_tools, "save_outcome_analysis"
    # It is a write, so the read-only variant must not carry it, and a session
    # managing itself has no business writing analyses of other transcripts.
    refute_includes readonly_tools, "save_outcome_analysis"
    refute_includes self_session_tools, "save_outcome_analysis"
  end

  test "its description states the two deviations from the upstream spec" do
    description = Mcp::Tools::SaveOutcomeAnalysis.rendered_description

    assert_match(/required on Success as well as Failure/, description)
    assert_match(/Outcome is local to the Goal/, description)
    assert_match(/failures do NOT propagate up/, description)
  end
end
