# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"

class Mcp::Tools::ActionOutcomeAnalysisTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    # The spawn builds a real Session row; running an agent is AgentSessionJob's
    # business and not what this covers.
    AgentSessionJob.stubs(:enqueue_new_session).returns(nil)

    @caller = Session.create!(prompt: "sweep", git_root: "https://github.com/tadasant/zimmer.git",
                              status: :running, genesis: SessionGenesis::SCHEDULE)
    @tool = tool_for(session_id: @caller.id)

    @targets = Array.new(4) do |i|
      Session.create!(
        title: "Target #{i}", prompt: "x", git_root: "https://github.com/tadasant/zimmer.git",
        status: :archived, archived_at: 1.day.ago, agent_runtime: "claude_code",
        metadata: { "agent_root_key" => "zimmer" }, config: { "model" => "claude-opus-5" }
      )
    end
  end

  def tool_for(**context)
    Mcp::Tools::ActionOutcomeAnalysis.new(context: Mcp::Context.new(tool_groups: "outcome_analyses", **context))
  end

  def analyze_all(**args)
    @tool.call({ "action" => "analyze_all", "agent_root" => "zimmer", "expected_count" => 4 }.merge(args.stringify_keys))
  end

  # --- analyze ------------------------------------------------------------------

  test "analyze spawns one spot analysis session that records the caller and inherits its line of work" do
    output = @tool.call("action" => "analyze", "session_id" => @targets.first.id)

    analysis = Session.outcome_analysis_sessions.sole
    assert_equal @targets.first.id.to_s, analysis.metadata[Session::OUTCOME_ANALYSIS_MARKER]
    assert_equal "mcp", analysis.metadata[OutcomeAnalyses::SpawnAnalysisSession::REQUESTED_VIA_KEY]
    assert_equal @caller.id.to_s, analysis.metadata[OutcomeAnalyses::SpawnAnalysisSession::REQUESTED_BY_KEY]
    assert_equal SessionGenesis::SPOT, analysis.scheduling_class
    assert_equal SessionGenesis::SCHEDULE, analysis.genesis, "an MCP request belongs to the caller's line of work, not the web UI's"
    assert_includes output, "## Analysis started"
    assert_includes output, "##{analysis.id}"
  end

  test "with no calling session on the connection, an MCP analysis is an api spawn" do
    tool_for.call("action" => "analyze", "session_id" => @targets.first.id)

    analysis = Session.outcome_analysis_sessions.sole
    assert_equal SessionGenesis::API, analysis.genesis
    assert_equal "mcp", analysis.metadata[OutcomeAnalyses::SpawnAnalysisSession::REQUESTED_VIA_KEY]
    assert_nil analysis.metadata[OutcomeAnalyses::SpawnAnalysisSession::REQUESTED_BY_KEY]
  end

  test "analyze says when the new analysis will supersede one" do
    OutcomeAnalyses::Save.call(session: @targets.first, root: {
      "id" => "S0", "trigger" => { "kind" => "New", "source" => "user" }, "goal" => { "text" => "g", "kind" => "Action" },
      "outcome" => { "kind" => "Success", "explanation" => "ok" }, "meta" => {}, "children" => []
    })

    assert_includes @tool.call("action" => "analyze", "session_id" => @targets.first.id), "supersedes it when it saves"
  end

  test "analyze refuses a live session, an analysis session, and a second analysis of the same transcript" do
    error = assert_raises(Mcp::ToolError) { @tool.call("action" => "analyze", "session_id" => sessions(:running).id) }
    assert_match(/not archived/, error.message)

    @tool.call("action" => "analyze", "session_id" => @targets.first.id)
    analysis = Session.outcome_analysis_sessions.sole
    analysis.update!(status: :archived)
    error = assert_raises(Mcp::ToolError) { @tool.call("action" => "analyze", "session_id" => analysis.id) }
    assert_match(/itself an outcome analysis session/, error.message)

    analysis.update!(status: :running)
    error = assert_raises(Mcp::ToolError) { @tool.call("action" => "analyze", "session_id" => @targets.first.id) }
    assert_match(/already being analyzed by session ##{analysis.id}/, error.message)
    assert_equal 1, Session.outcome_analysis_sessions.count
  end

  test "at most AGENT_MAX_CONCURRENCY single analyses requested over MCP are in flight at once" do
    cap = OutcomeAnalysisBatch::AGENT_MAX_CONCURRENCY
    assert_operator @targets.size, :>, cap

    @targets.first(cap).each { |target| @tool.call("action" => "analyze", "session_id" => target.id) }

    error = assert_raises(Mcp::ToolError) { @tool.call("action" => "analyze", "session_id" => @targets.last.id) }
    assert_match(/#{cap} analyses requested one at a time over MCP are already in flight/, error.message)
    assert_match(/analyze_all/, error.message)
    assert_equal cap, Session.outcome_analysis_sessions.count

    # One finishing frees a slot.
    Session.outcome_analysis_sessions.first.update!(status: :archived)
    @tool.call("action" => "analyze", "session_id" => @targets.last.id)
    assert_equal cap + 1, Session.outcome_analysis_sessions.count
  end

  test "an analysis stuck for longer than the pump's stale window stops holding a slot or its transcript" do
    cap = OutcomeAnalysisBatch::AGENT_MAX_CONCURRENCY
    @targets.first(cap).each { |target| @tool.call("action" => "analyze", "session_id" => target.id) }
    stuck = Session.outcome_analysis_sessions.order(:id).first
    stuck.update_columns(status: Session.statuses[:needs_input], created_at: (OutcomeAnalyses::PumpBatch::STALE_AFTER + 1.minute).ago)

    # Its transcript is analyzable again, and its slot is free for that.
    @tool.call("action" => "analyze", "session_id" => stuck.metadata[Session::OUTCOME_ANALYSIS_MARKER])
    assert_equal cap + 1, Session.outcome_analysis_sessions.count

    # The fresh ones still hold theirs.
    error = assert_raises(Mcp::ToolError) { @tool.call("action" => "analyze", "session_id" => @targets.last.id) }
    assert_match(/#{cap} analyses requested one at a time over MCP are already in flight/, error.message)
  end

  test "a web-UI analysis in flight does not count against the agent cap" do
    @targets.first(OutcomeAnalysisBatch::AGENT_MAX_CONCURRENCY).each do |target|
      OutcomeAnalyses::SpawnAnalysisSession.call(session: target)
    end

    @tool.call("action" => "analyze", "session_id" => @targets.last.id)
    assert_equal OutcomeAnalysisBatch::AGENT_MAX_CONCURRENCY + 1, Session.outcome_analysis_sessions.count
  end

  test "a connection fenced away from the analysis root cannot start an analysis" do
    fenced = tool_for(session_id: @caller.id, allowed_agent_roots: "zimmer")

    [ { "action" => "analyze", "session_id" => @targets.first.id },
      { "action" => "analyze_all", "agent_root" => "zimmer", "expected_count" => 4 } ].each do |args|
      error = assert_raises(Mcp::ToolError) { fenced.call(args) }
      assert_match(/agent root "#{OutcomeAnalyses::Config.agent_root}" is not permitted/, error.message)
    end
    assert_empty Session.outcome_analysis_sessions
    assert_equal 0, OutcomeAnalysisBatch.count

    allowed = tool_for(session_id: @caller.id, allowed_agent_roots: "zimmer,#{OutcomeAnalyses::Config.agent_root}")
    allowed.call("action" => "analyze", "session_id" => @targets.first.id)
    assert_equal 1, Session.outcome_analysis_sessions.count
  end

  # --- analyze_all --------------------------------------------------------------

  test "analyze_all goes through StartBatch: a batch row, a frozen queue, the pump kicked, and who started it" do
    output = nil
    assert_enqueued_with(job: OutcomeAnalysisBatchPumpJob) { output = analyze_all }

    batch = OutcomeAnalysisBatch.sole
    assert_equal OutcomeAnalysisBatch::STARTED_VIA_MCP, batch.started_via
    assert_equal @caller, batch.started_by_session
    assert_equal 1, batch.concurrency, "concurrency defaults to fully sequential"
    assert_equal 4, batch.total_count
    assert_equal @targets.map(&:id).sort, batch.items.pluck(:session_id).sort
    assert_equal({ "agent_root" => "zimmer" }, batch.filters)
    assert_includes output, "## Batch ##{batch.id} started"
    assert_includes output, "cancel_batch"
  end

  test "analyze_all honors a concurrency up to the agent cap" do
    analyze_all(concurrency: OutcomeAnalysisBatch::AGENT_MAX_CONCURRENCY)

    assert_equal OutcomeAnalysisBatch::AGENT_MAX_CONCURRENCY, OutcomeAnalysisBatch.sole.concurrency
  end

  test "analyze_all refuses a concurrency above the agent cap rather than clamping it, and creates nothing" do
    error = assert_raises(Mcp::ToolError) { analyze_all(concurrency: OutcomeAnalysisBatch::AGENT_MAX_CONCURRENCY + 1) }

    assert_match(/at most #{OutcomeAnalysisBatch::AGENT_MAX_CONCURRENCY} analyses at a time/, error.message)
    assert_match(/Analyze All button on \/outcomes/, error.message)
    assert_equal 0, OutcomeAnalysisBatch.count
  end

  test "only one MCP-started batch runs at a time, and a web-UI batch does not count" do
    OutcomeAnalyses::StartBatch.call(filters: OutcomeAnalyses::LedgerFilters.new(agent_root: "zimmer"), concurrency: 50)

    analyze_all
    first = OutcomeAnalysisBatch.started_via_mcp.sole

    extra = Session.create!(title: "Later", prompt: "x", git_root: "https://github.com/tadasant/zimmer.git",
                            status: :archived, archived_at: 1.hour.ago, metadata: { "agent_root_key" => "zimmer" })
    error = assert_raises(Mcp::ToolError) { analyze_all(expected_count: 1) }
    assert_match(/Batch ##{first.id}, started over MCP, is still running/, error.message)
    assert_match(/batch_id: #{first.id}/, error.message)
    assert_equal 1, OutcomeAnalysisBatch.started_via_mcp.count

    # Stopping it frees the slot. Its sessions were never analyzed, so the next
    # batch covers them again, plus the one archived since.
    @tool.call("action" => "cancel_batch", "batch_id" => first.id)
    analyze_all(expected_count: 5)
    assert_includes OutcomeAnalysisBatch.started_via_mcp.active.sole.items.pluck(:session_id), extra.id
  end

  test "analyze_all needs the expected count, and refuses a batch of any other size" do
    error = assert_raises(Mcp::ToolError) { @tool.call("action" => "analyze_all", "agent_root" => "zimmer") }
    assert_match(/"expected_count" is required/, error.message)

    error = assert_raises(Mcp::ToolError) { analyze_all(expected_count: 3) }
    assert_match(/match 4 unanalyzed archived sessions, not the 3 expected. Nothing was queued/, error.message)
    assert_equal 0, OutcomeAnalysisBatch.count
  end

  test "analyze_all refuses a filter that names nothing instead of widening the batch" do
    error = assert_raises(Mcp::ToolError) { analyze_all(from: "yesterday") }

    assert_match(/"from" must be a date/, error.message)
    assert_equal 0, OutcomeAnalysisBatch.count
  end

  test "analyze_all says so when nothing matches" do
    error = assert_raises(Mcp::ToolError) { analyze_all(agent_root: "fleet-maintenance", expected_count: 1) }

    assert_match(/No unanalyzed archived sessions match/, error.message)
  end

  # --- cancel_batch -------------------------------------------------------------

  test "cancel_batch stops a running batch, even one a human started, and leaves in-flight items to finish" do
    batch = OutcomeAnalyses::StartBatch.call(filters: OutcomeAnalyses::LedgerFilters.new(agent_root: "zimmer"), concurrency: 1)
    batch.items.in_order.first.update!(state: OutcomeAnalysisBatchItem::RUNNING, started_at: Time.current)

    output = @tool.call("action" => "cancel_batch", "batch_id" => batch.id)

    assert_equal OutcomeAnalysisBatch::CANCELED, batch.reload.status
    assert_equal 3, batch.items.where(state: OutcomeAnalysisBatchItem::CANCELED).count
    assert_equal 1, batch.items.running.count
    assert_includes output, "- **Canceled:** 3 queued analyses"
    assert_includes output, "- **Still in flight:** 1"
  end

  test "cancel_batch refuses a batch that is not running rather than relabelling it" do
    batch = OutcomeAnalysisBatch.create!(filters: {}, concurrency: 1, total_count: 0, status: OutcomeAnalysisBatch::COMPLETED)

    error = assert_raises(Mcp::ToolError) { @tool.call("action" => "cancel_batch", "batch_id" => batch.id) }
    assert_match(/already completed; there is nothing to stop/, error.message)
    assert_equal OutcomeAnalysisBatch::COMPLETED, batch.reload.status

    error = assert_raises(Mcp::ToolError) { @tool.call("action" => "cancel_batch", "batch_id" => 0) }
    assert_match(/Batch not found/, error.message)
    error = assert_raises(Mcp::ToolError) { @tool.call("action" => "cancel_batch") }
    assert_match(/"batch_id" is required/, error.message)
  end

  test "an unknown action names the valid ones" do
    error = assert_raises(Mcp::ToolError) { @tool.call("action" => "analyze_everything") }
    assert_match(/Valid actions: analyze, analyze_all, cancel_batch/, error.message)
  end
end
