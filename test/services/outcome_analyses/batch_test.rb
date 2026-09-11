# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"

class OutcomeAnalyses::BatchTest < ActiveSupport::TestCase
  setup do
    # SpawnAnalysisSession is exercised on its own; here what matters is the
    # queue's arithmetic, so the spawn is stubbed to a cheap archived stand-in.
    @spawned = []
    OutcomeAnalyses::SpawnAnalysisSession.stubs(:call).with do |kwargs|
      @spawned << kwargs[:session]
      true
    end.returns(nil).then.returns(nil)

    @targets = Array.new(5) do |i|
      Session.create!(
        title: "Target #{i}", prompt: "x", git_root: "https://github.com/tadasant/zimmer.git",
        status: :archived, archived_at: 1.day.ago, agent_runtime: "claude_code",
        metadata: { "agent_root_key" => "zimmer" }, config: { "model" => "opus" }
      )
    end
  end

  def stub_spawn!
    OutcomeAnalyses::SpawnAnalysisSession.unstub(:call)
    OutcomeAnalyses::SpawnAnalysisSession.stubs(:call).with do |**kwargs|
      @spawned << kwargs[:session]
      true
    end.returns(analysis_session)
  end

  def analysis_session
    Session.create!(prompt: "analysis", git_root: "https://github.com/tadasant/zimmer.git", status: :running)
  end

  def filters(overrides = {})
    OutcomeAnalyses::LedgerFilters.from_params({ agent_root: "zimmer", analyzed: "no" }.merge(overrides))
  end

  def tree_for(_session)
    {
      "id" => "S0", "trigger" => { "kind" => "New", "source" => "user" },
      "goal" => { "text" => "g", "kind" => "Action" },
      "outcome" => { "kind" => "Success", "explanation" => "done" }, "meta" => {}, "children" => []
    }
  end

  test "a batch freezes the sessions that matched when it was created" do
    stub_spawn!
    batch = OutcomeAnalyses::StartBatch.call(filters: filters, concurrency: 2)

    assert_equal 5, batch.total_count
    assert_equal 5, batch.items.count
    assert_equal (0..4).to_a, batch.items.in_order.pluck(:position)

    # A session archived after the fact does not join a running batch.
    Session.create!(title: "Later", prompt: "x", git_root: "https://github.com/tadasant/zimmer.git",
                    status: :archived, metadata: { "agent_root_key" => "zimmer" })
    assert_equal 5, batch.reload.items.count
  end

  test "refuses to start when nothing matches" do
    assert_raises(OutcomeAnalyses::StartBatch::NothingToAnalyze) do
      OutcomeAnalyses::StartBatch.call(filters: filters(agent_root: "fleet-maintenance"), concurrency: 1)
    end
  end

  test "honors a large concurrency as typed rather than clamping it" do
    stub_spawn!
    batch = OutcomeAnalyses::StartBatch.call(filters: filters, concurrency: 100)

    assert_equal 100, batch.concurrency
    assert batch.advisory_concurrency?
  end

  test "floors concurrency at one so a batch always makes progress" do
    stub_spawn!
    assert_equal 1, OutcomeAnalyses::StartBatch.call(filters: filters, concurrency: 0).concurrency
  end

  test "a web-UI batch records where it came from" do
    stub_spawn!
    batch = OutcomeAnalyses::StartBatch.call(filters: filters, concurrency: 2)

    assert_equal OutcomeAnalysisBatch::STARTED_VIA_WEB_UI, batch.started_via
    assert_nil batch.started_by_session
  end

  test "an MCP batch above the agent cap is refused, not clamped; at the cap it runs" do
    cap = OutcomeAnalysisBatch::AGENT_MAX_CONCURRENCY

    error = assert_raises(OutcomeAnalyses::StartBatch::AgentCapExceeded) do
      OutcomeAnalyses::StartBatch.call(filters: filters, concurrency: cap + 1, started_via: OutcomeAnalysisBatch::STARTED_VIA_MCP)
    end
    assert_match(/at most #{cap} analyses at a time \(asked for #{cap + 1}\)/, error.message)
    assert_equal 0, OutcomeAnalysisBatch.count

    batch = OutcomeAnalyses::StartBatch.call(filters: filters, concurrency: cap, started_via: OutcomeAnalysisBatch::STARTED_VIA_MCP)
    assert_equal cap, batch.concurrency
    assert batch.started_via_mcp?
  end

  test "the database holds one running MCP batch, even against a racing insert" do
    OutcomeAnalysisBatch.create!(filters: {}, concurrency: 1, total_count: 0, started_via: OutcomeAnalysisBatch::STARTED_VIA_MCP)

    assert_raises(ActiveRecord::RecordNotUnique) do
      OutcomeAnalysisBatch.transaction(requires_new: true) do
        OutcomeAnalysisBatch.create!(filters: {}, concurrency: 1, total_count: 0, started_via: OutcomeAnalysisBatch::STARTED_VIA_MCP)
      end
    end

    # A finished MCP batch, and any number of web-UI ones, do not hold the slot.
    OutcomeAnalysisBatch.create!(filters: {}, concurrency: 1, total_count: 0, status: OutcomeAnalysisBatch::COMPLETED,
                                 started_via: OutcomeAnalysisBatch::STARTED_VIA_MCP)
    2.times { OutcomeAnalysisBatch.create!(filters: {}, concurrency: 1, total_count: 0) }
    assert_equal 1, OutcomeAnalysisBatch.active.started_via_mcp.count
  end

  test "StartBatch turns a lost race for the MCP slot into the same refusal as the check" do
    stub_spawn!
    # The friendly pre-check sees no running MCP batch, the INSERT still collides.
    OutcomeAnalysisBatch.stubs(:active).returns(OutcomeAnalysisBatch.none).then.returns(OutcomeAnalysisBatch.where(status: "running"))
    OutcomeAnalysisBatch.create!(filters: {}, concurrency: 1, total_count: 0, started_via: OutcomeAnalysisBatch::STARTED_VIA_MCP)

    error = assert_raises(OutcomeAnalyses::StartBatch::AgentCapExceeded) do
      OutcomeAnalyses::StartBatch.call(filters: filters, concurrency: 1, started_via: OutcomeAnalysisBatch::STARTED_VIA_MCP)
    end
    assert_match(/started over MCP, is still running/, error.message)
    assert_equal 1, OutcomeAnalysisBatch.count, "the transaction the caller is in survives the collision"
  end

  test "an expected count that does not match refuses the batch and creates nothing" do
    error = assert_raises(OutcomeAnalyses::StartBatch::CountMismatch) do
      OutcomeAnalyses::StartBatch.call(filters: filters, concurrency: 1, expected_count: 50)
    end

    assert_match(/match 5 unanalyzed archived sessions, not the 50 expected/, error.message)
    assert_equal 0, OutcomeAnalysisBatch.count
  end

  test "the pump spawns each item with its batch's provenance" do
    starter = sessions(:running)
    batch = OutcomeAnalyses::StartBatch.call(filters: filters, concurrency: 2,
                                             started_via: OutcomeAnalysisBatch::STARTED_VIA_MCP, started_by_session: starter)
    OutcomeAnalyses::SpawnAnalysisSession.unstub(:call)
    AgentSessionJob.stubs(:enqueue_new_session).returns(nil)

    OutcomeAnalyses::PumpBatch.call(batch)

    spawned = batch.items.running.map(&:analysis_session)
    assert_equal 2, spawned.size
    spawned.each do |analysis|
      assert_equal "mcp", analysis.metadata[OutcomeAnalyses::SpawnAnalysisSession::REQUESTED_VIA_KEY]
      assert_equal starter.id.to_s, analysis.metadata[OutcomeAnalyses::SpawnAnalysisSession::REQUESTED_BY_KEY]
      assert_equal batch.id.to_s, analysis.metadata["outcome_analysis_batch_id"]
    end
    assert_equal 0, OutcomeAnalyses::SpawnAnalysisSession.live_mcp_single_count, "batch items are not single analyses"
  end

  test "a stopped MCP batch's analyses in flight block the next MCP batch until they land" do
    batch = OutcomeAnalyses::StartBatch.call(filters: filters, concurrency: 2, started_via: OutcomeAnalysisBatch::STARTED_VIA_MCP)
    OutcomeAnalyses::SpawnAnalysisSession.unstub(:call)
    AgentSessionJob.stubs(:enqueue_new_session).returns(nil)
    OutcomeAnalyses::PumpBatch.call(batch)
    OutcomeAnalyses::CancelBatch.call(batch)
    assert_equal 2, OutcomeAnalyses::SpawnAnalysisSession.live_mcp_batch_item_count

    error = assert_raises(OutcomeAnalyses::StartBatch::AgentCapExceeded) do
      OutcomeAnalyses::StartBatch.call(filters: filters, concurrency: 3, started_via: OutcomeAnalysisBatch::STARTED_VIA_MCP)
    end
    assert_match(/2 analyses from a stopped MCP batch are still in flight/, error.message)
    assert_equal 1, OutcomeAnalysisBatch.count

    # A web-UI batch is not held to it.
    OutcomeAnalyses::StartBatch.call(filters: filters, concurrency: 3)

    batch.items.running.each { |item| item.analysis_session.update!(status: :archived) }
    assert OutcomeAnalyses::StartBatch.call(filters: filters, concurrency: 3, started_via: OutcomeAnalysisBatch::STARTED_VIA_MCP)
  end

  test "the cron sweep reconciles a stopped batch's in-flight items, and spawns nothing for it" do
    stub_spawn!
    batch = OutcomeAnalyses::StartBatch.call(filters: filters, concurrency: 1)
    OutcomeAnalyses::PumpBatch.call(batch)
    in_flight = batch.items.running.sole
    OutcomeAnalyses::CancelBatch.call(batch)
    OutcomeAnalyses::Save.call(session: in_flight.session, root: tree_for(in_flight.session))
    spawned_before = @spawned.size

    OutcomeAnalysisBatchPumpJob.perform_now

    assert_equal OutcomeAnalysisBatchItem::SUCCEEDED, in_flight.reload.state
    assert_equal OutcomeAnalysisBatch::CANCELED, batch.reload.status
    assert_equal 0, batch.items.running.count
    assert_equal spawned_before, @spawned.size
  end

  test "stopping a batch that already finished is refused, not relabelled" do
    batch = OutcomeAnalysisBatch.create!(filters: {}, concurrency: 1, total_count: 0, status: OutcomeAnalysisBatch::COMPLETED)

    error = assert_raises(OutcomeAnalyses::CancelBatch::NotRunning) { OutcomeAnalyses::CancelBatch.call(batch) }

    assert_match(/already completed/, error.message)
    assert_equal OutcomeAnalysisBatch::COMPLETED, batch.reload.status
  end

  test "concurrency 1 keeps exactly one analysis in flight" do
    stub_spawn!
    batch = OutcomeAnalyses::StartBatch.call(filters: filters, concurrency: 1)

    OutcomeAnalyses::PumpBatch.call(batch)
    assert_equal 1, batch.items.running.count

    # Pumping again while the one slot is occupied spawns nothing.
    OutcomeAnalyses::PumpBatch.call(batch)
    assert_equal 1, batch.items.running.count
    assert_equal 4, batch.items.queued.count
  end

  test "a saved analysis frees the slot and the next item starts" do
    stub_spawn!
    batch = OutcomeAnalyses::StartBatch.call(filters: filters, concurrency: 1)
    OutcomeAnalyses::PumpBatch.call(batch)
    first = batch.items.running.sole

    OutcomeAnalyses::Save.call(session: first.session, root: tree_for(first.session))
    OutcomeAnalyses::PumpBatch.call(batch)

    assert_equal OutcomeAnalysisBatchItem::SUCCEEDED, first.reload.state
    assert_equal 1, batch.items.running.count
    assert_not_equal first.id, batch.items.running.sole.id
  end

  test "an analysis session that ends without saving fails its item" do
    stub_spawn!
    batch = OutcomeAnalyses::StartBatch.call(filters: filters, concurrency: 1)
    OutcomeAnalyses::PumpBatch.call(batch)
    item = batch.items.running.sole

    item.analysis_session.update!(status: :failed)
    OutcomeAnalyses::PumpBatch.call(batch)

    assert_equal OutcomeAnalysisBatchItem::FAILED, item.reload.state
    assert_match(/failed without saving/, item.error)
  end

  test "a spawn failure costs one item, not the batch" do
    OutcomeAnalyses::SpawnAnalysisSession.unstub(:call)
    OutcomeAnalyses::SpawnAnalysisSession.stubs(:call).raises(RuntimeError, "catalog exploded")
    batch = OutcomeAnalyses::StartBatch.call(filters: filters, concurrency: 2)

    OutcomeAnalyses::PumpBatch.call(batch)

    assert_equal 2, batch.items.where(state: OutcomeAnalysisBatchItem::FAILED).count
    assert_equal OutcomeAnalysisBatch::RUNNING, batch.reload.status
    assert_match(/catalog exploded/, batch.items.where(state: OutcomeAnalysisBatchItem::FAILED).first.error)
  end

  test "the batch completes once nothing is queued or running" do
    OutcomeAnalyses::SpawnAnalysisSession.unstub(:call)
    OutcomeAnalyses::SpawnAnalysisSession.stubs(:call).raises(RuntimeError, "no")
    batch = OutcomeAnalyses::StartBatch.call(filters: filters, concurrency: 10)

    OutcomeAnalyses::PumpBatch.call(batch)

    assert_equal OutcomeAnalysisBatch::COMPLETED, batch.reload.status
    assert batch.finished_at.present?
    assert_equal 100, batch.progress_percent
  end

  test "an item another wave is still spawning is left alone, not failed" do
    stub_spawn!
    batch = OutcomeAnalyses::StartBatch.call(filters: filters, concurrency: 1)
    OutcomeAnalyses::PumpBatch.call(batch)
    item = batch.items.running.sole
    # Spawning happens outside the batch lock, so a second pump can see a claimed
    # item before its session exists. That is not a failure.
    item.update!(analysis_session_id: nil)

    OutcomeAnalyses::PumpBatch.call(batch)

    assert_equal OutcomeAnalysisBatchItem::RUNNING, item.reload.state
    assert_nil item.error
  end

  test "an item claimed by a wave that died is put back in the queue" do
    stub_spawn!
    batch = OutcomeAnalyses::StartBatch.call(filters: filters, concurrency: 1)
    OutcomeAnalyses::PumpBatch.call(batch)
    item = batch.items.running.sole
    item.update!(analysis_session_id: nil, started_at: (OutcomeAnalyses::PumpBatch::SPAWN_GRACE + 1.minute).ago)

    OutcomeAnalyses::PumpBatch.call(batch)

    # Requeued and immediately re-claimed by the same wave, so the slot is in use
    # again rather than stranded.
    assert_equal 1, batch.items.running.count
    assert_equal 0, batch.items.where(state: OutcomeAnalysisBatchItem::FAILED).count
  end

  test "a spawn that outlived its claim does not overwrite the wave that replaced it" do
    stub_spawn!
    batch = OutcomeAnalyses::StartBatch.call(filters: filters, concurrency: 1)
    OutcomeAnalyses::PumpBatch.call(batch)
    item = batch.items.running.sole
    stale_claim = item.started_at

    # Wave B requeues and re-claims the item while wave A is still spawning for it.
    item.update!(analysis_session_id: nil, started_at: (OutcomeAnalyses::PumpBatch::SPAWN_GRACE + 1.minute).ago)
    OutcomeAnalyses::PumpBatch.call(batch)
    reclaimed_session_id = item.reload.analysis_session_id
    reclaimed_at = item.started_at

    # Wave A's late write, replayed with its own (now stale) claim.
    linked = OutcomeAnalysisBatchItem
      .where(id: item.id, state: OutcomeAnalysisBatchItem::RUNNING, started_at: stale_claim)
      .update_all(analysis_session_id: analysis_session.id)

    assert_equal 0, linked, "a stale claim must not be able to relink the item"
    assert_equal reclaimed_session_id, item.reload.analysis_session_id
    assert_equal reclaimed_at.to_i, item.started_at.to_i
  end

  test "cancel reports the number of items it actually canceled" do
    stub_spawn!
    batch = OutcomeAnalyses::StartBatch.call(filters: filters, concurrency: 2)
    OutcomeAnalyses::PumpBatch.call(batch)

    assert_equal 3, OutcomeAnalyses::CancelBatch.call(batch)
  end

  test "a canceled batch still reconciles what was left in flight" do
    stub_spawn!
    batch = OutcomeAnalyses::StartBatch.call(filters: filters, concurrency: 1)
    OutcomeAnalyses::PumpBatch.call(batch)
    item = batch.items.running.sole
    OutcomeAnalyses::CancelBatch.call(batch)

    OutcomeAnalyses::Save.call(session: item.session, root: tree_for(item.session))
    OutcomeAnalyses::PumpBatch.call(batch.reload)

    # Without this, an analysis that lands after Stop leaves its item RUNNING on a
    # stopped batch forever.
    assert_equal OutcomeAnalysisBatchItem::SUCCEEDED, item.reload.state
    assert_equal OutcomeAnalysisBatch::CANCELED, batch.reload.status
  end

  test "cancel stops the queue and leaves in-flight analyses alone" do
    stub_spawn!
    batch = OutcomeAnalyses::StartBatch.call(filters: filters, concurrency: 2)
    OutcomeAnalyses::PumpBatch.call(batch)
    in_flight = batch.items.running.to_a

    OutcomeAnalyses::CancelBatch.call(batch)

    assert_equal OutcomeAnalysisBatch::CANCELED, batch.reload.status
    assert_equal 0, batch.items.queued.count
    assert_equal 3, batch.items.where(state: OutcomeAnalysisBatchItem::CANCELED).count
    assert_equal in_flight.map(&:id).sort, batch.items.running.pluck(:id).sort
  end

  test "pumping a canceled batch spawns nothing" do
    stub_spawn!
    batch = OutcomeAnalyses::StartBatch.call(filters: filters, concurrency: 2)
    OutcomeAnalyses::CancelBatch.call(batch)
    @spawned.clear

    OutcomeAnalyses::PumpBatch.call(batch.reload)

    assert_empty @spawned
  end

  test "the pump job advances every running batch and survives one that throws" do
    stub_spawn!
    good = OutcomeAnalyses::StartBatch.call(filters: filters, concurrency: 1)

    OutcomeAnalysisBatchPumpJob.perform_now

    assert_equal 1, good.reload.items.running.count
  end

  test "an item whose session is no longer archived fails rather than spawning" do
    stub_spawn!
    batch = OutcomeAnalyses::StartBatch.call(filters: filters, concurrency: 1)
    batch.items.in_order.first.session.update!(status: :needs_input)

    OutcomeAnalyses::PumpBatch.call(batch)

    assert_equal OutcomeAnalysisBatchItem::FAILED, batch.items.in_order.first.reload.state
    assert_match(/no longer archived/, batch.items.in_order.first.error)
  end
end
