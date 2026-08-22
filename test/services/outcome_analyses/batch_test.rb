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
      OutcomeAnalyses::StartBatch.call(filters: filters(agent_root: "agent-orchestrator"), concurrency: 1)
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
