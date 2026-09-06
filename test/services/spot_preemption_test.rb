# frozen_string_literal: true

require "test_helper"

# The concurrency ceiling's active half: a priority session starting into a full
# fleet takes a slot off a running spot session rather than making the fleet one
# wider than the operator's number.
#
# What these pin down, in order of how much damage getting them wrong would do:
# a priority session is never the victim, the fleet is never touched when it is
# not full, the same session is not preempted twice in a row, a mark that stops
# being necessary is released without costing a turn, and a preempted session
# lands in exactly the queue SpotSessionPause already resumes.
class SpotPreemptionTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    # Same isolation the other spot suites use: the cap counts every running
    # Claude Code session in the database, so a fixture row in `running` decides
    # these tests instead of the ones they create.
    ClaudeAccountQuotaSnapshot.delete_all
    ClaudeAccount.update_all(is_current: false)
    Session.where(status: :running).update_all(status: Session.statuses[:needs_input])
    @setting = AppSetting.editable
    @setting.update!(spot_gating_enabled: true, spot_preemption_enabled: true,
                     spot_max_concurrent_sessions: 2)
  end

  # A session a WORKER is executing, which is the only population the cap counts.
  def running_session(genesis: SessionGenesis::GITHUB_ISSUE, scheduling_class: nil,
                      precedence: 0, runtime: "claude_code", metadata: {}, created_at: 1.hour.ago)
    record = Session.create!(
      git_root: "https://github.com/t/r.git", prompt: "work", genesis: genesis,
      scheduling_class: scheduling_class, precedence: precedence, status: :running,
      agent_runtime: runtime, session_id: "cli-#{SecureRandom.hex(4)}", metadata: metadata,
      created_at: created_at
    )
    GoodJob::Job.create!(active_job_id: SecureRandom.uuid, queue_name: "agents",
      job_class: "AgentSessionJob", serialized_params: { "arguments" => [ record.id ] },
      scheduled_at: 2.minutes.ago, performed_at: 1.minute.ago)
    record
  end

  # The priority session about to take a slot: `waiting`, which since #1040 is
  # where an ordinary turn reaches the gate.
  def incoming_priority_session
    Session.create!(git_root: "https://github.com/t/r.git", prompt: "urgent",
                    genesis: SessionGenesis::GITHUB_ISSUE, scheduling_class: SessionGenesis::PRIORITY,
                    status: :waiting, agent_runtime: "claude_code")
  end

  def spot_session(**kwargs)
    running_session(scheduling_class: SessionGenesis::SPOT, **kwargs)
  end

  # === Making room ===

  test "a priority session starting into a full fleet preempts a running spot session" do
    victim = spot_session(precedence: -1)
    spot_session(precedence: 10) # a second slot, so the fleet is at its cap of 2
    incoming = incoming_priority_session

    preempted = SpotPreemption.make_room_for(incoming)

    assert_equal victim.id, preempted&.id
    victim.reload
    assert_equal SpotSessionPause::PREEMPTED_REASON,
      victim.metadata[SpotSessionPause::PAUSED_REASON]
    assert_equal incoming.id, victim.metadata[SpotSessionPause::PREEMPT_FOR_SESSION]
    assert_equal SpotSessionPause::PAUSED_BY, victim.metadata["paused_by"]
    assert_equal 1, victim.metadata[SpotPreemption::COUNT]
    # The turn is not interrupted — the mark is what carries the session into the
    # queue when the turn ends.
    assert victim.running?, "the victim keeps its turn until the turn ends"
    assert_equal true, victim.metadata["pending_sleep"]
  end

  test "nothing is preempted while the fleet has a free slot" do
    @setting.update!(spot_max_concurrent_sessions: 5)
    victim = spot_session

    assert_nil SpotPreemption.make_room_for(incoming_priority_session)
    assert_nil victim.reload.metadata[SpotSessionPause::PAUSED_REASON]
  end

  test "a priority session is never the victim" do
    priority = running_session(scheduling_class: SessionGenesis::PRIORITY, precedence: -100)
    victim = spot_session(precedence: 50)

    preempted = SpotPreemption.make_room_for(incoming_priority_session)

    assert_equal victim.id, preempted&.id, "the spot session yields even though it outranks"
    assert_nil priority.reload.metadata[SpotSessionPause::PAUSED_REASON]
  end

  test "a spot session that is already spot does not preempt for itself" do
    spot_session
    spot_session
    incoming = Session.create!(git_root: "https://github.com/t/r.git", prompt: "queued",
                               genesis: SessionGenesis::GITHUB_ISSUE,
                               scheduling_class: SessionGenesis::SPOT, status: :waiting,
                               agent_runtime: "claude_code")

    assert_nil SpotPreemption.make_room_for(incoming)
  end

  test "a Codex priority session takes no Claude slot, so it preempts nobody" do
    spot_session
    spot_session
    incoming = Session.create!(git_root: "https://github.com/t/r.git", prompt: "urgent",
                               genesis: SessionGenesis::GITHUB_ISSUE,
                               scheduling_class: SessionGenesis::PRIORITY, status: :waiting,
                               agent_runtime: "codex")

    assert_nil SpotPreemption.make_room_for(incoming)
  end

  test "the switch turns preemption off without turning the gate off" do
    @setting.update!(spot_preemption_enabled: false)
    victim = spot_session
    spot_session

    assert_nil SpotPreemption.make_room_for(incoming_priority_session)
    assert_nil victim.reload.metadata[SpotSessionPause::PAUSED_REASON]
  end

  # === Choosing who yields ===

  test "the lowest-precedence running spot session is the one that yields" do
    high = spot_session(precedence: 100)
    low = spot_session(precedence: -10)

    assert_equal low.id, SpotPreemption.make_room_for(incoming_priority_session)&.id
    assert_nil high.reload.metadata[SpotSessionPause::PAUSED_REASON]
  end

  test "a precedence tie goes to the session with fewer prior preemptions" do
    # `fresh` FIRST, so the last tiebreak (newest wins) would pick the veteran if
    # the ledger key were not consulted. The assertion is about the ledger.
    fresh = spot_session
    spot_session(metadata: { SpotPreemption::COUNT => 3 })

    assert_equal fresh.id, SpotPreemption.make_room_for(incoming_priority_session)&.id
  end

  test "a session a human has spoken to is spared over one nobody has" do
    # `untouched` FIRST, so the last tiebreak (newest wins) would pick the one
    # with the human message if involvement were not consulted.
    untouched = spot_session
    talked_to = spot_session
    HumanMessage.create!(session: talked_to, author: "tadasant", channel: HumanMessage::WEB_UI,
                         content: "keep going", occurred_at: Time.current,
                         provenance: { "entry_point" => "web_ui.follow_up" })

    assert_equal untouched.id, SpotPreemption.make_room_for(incoming_priority_session)&.id
  end

  test "a session inside its cooldown is not preempted again" do
    recent = spot_session(metadata: { SpotPreemption::LAST_AT => 5.minutes.ago.utc.iso8601 })
    other = spot_session(precedence: 100)

    assert_equal other.id, SpotPreemption.make_room_for(incoming_priority_session)&.id
    assert_nil recent.reload.metadata[SpotSessionPause::PAUSED_REASON]
  end

  test "with every candidate cooling down, the fleet is left over its cap" do
    cooling = spot_session(metadata: { SpotPreemption::LAST_AT => 1.minute.ago.utc.iso8601 })
    spot_session(metadata: { SpotPreemption::LAST_AT => 1.minute.ago.utc.iso8601 })

    assert_nil SpotPreemption.make_room_for(incoming_priority_session)
    assert_nil cooling.reload.metadata[SpotSessionPause::PAUSED_REASON]
  end

  test "a session already carrying a pause record is never picked" do
    parked = spot_session(metadata: {
      SpotSessionPause::PAUSED_REASON => SpotSessionPause::QUEUED_REASON,
      SpotSessionPause::PAUSED_DETAIL => "parked"
    })
    other = spot_session(precedence: 100)

    assert_equal other.id, SpotPreemption.make_room_for(incoming_priority_session)&.id
    assert_equal SpotSessionPause::QUEUED_REASON,
      parked.reload.metadata[SpotSessionPause::PAUSED_REASON], "its own story is not overwritten"
  end

  test "one priority start takes exactly one slot" do
    spot_session(precedence: -1)
    spot_session(precedence: 10)

    SpotPreemption.make_room_for(incoming_priority_session)

    assert_equal 1, Session.where("metadata->>? = ?", SpotSessionPause::PAUSED_REASON,
                                  SpotSessionPause::PREEMPTED_REASON).count
  end

  # === Resolving a mark ===

  test "a mark is released, at no cost, once the fleet is under its cap again" do
    victim = spot_session(precedence: -1)
    other = spot_session(precedence: 10)
    assert_equal victim.id, SpotPreemption.make_room_for(incoming_priority_session)&.id
    # Something finished and freed a slot before the marked turn ended.
    other.update!(status: :needs_input)

    result = SpotPreemption.sweep!

    assert_equal 1, result.released
    assert_equal 0, result.halted
    victim.reload
    assert victim.running?, "the victim never stopped"
    assert_nil victim.metadata[SpotSessionPause::PAUSED_REASON]
    assert_nil victim.metadata["pending_sleep"]
  end

  test "a mark inside its grace is left alone while the fleet is still full" do
    victim = spot_session(precedence: -1)
    spot_session(precedence: 10)
    SpotPreemption.make_room_for(incoming_priority_session)

    result = SpotPreemption.sweep!

    assert_equal 0, result.released
    assert_equal 0, result.halted
    assert_equal 1, result.waiting
    assert_equal SpotSessionPause::PREEMPTED_REASON,
      victim.reload.metadata[SpotSessionPause::PAUSED_REASON]
  end

  test "a turn that outlasts the grace with the fleet still full is halted" do
    victim = spot_session(precedence: -1)
    spot_session(precedence: 10)
    SpotPreemption.make_room_for(incoming_priority_session)
    victim.merge_metadata!(
      SpotSessionPause::PREEMPT_MARKED_AT => (SpotPreemption::GRACE + 1.minute).ago.utc.iso8601
    )

    result = SpotPreemption.sweep!

    assert_equal 1, result.halted
    victim.reload
    assert victim.waiting?, "the halt lands the session in the queue"
    assert_equal SpotSessionPause::PREEMPTED_REASON,
      victim.metadata[SpotSessionPause::PAUSED_REASON]
  end

  test "a mark with no timestamp is never escalated" do
    victim = spot_session(precedence: -1)
    spot_session(precedence: 10)
    SpotPreemption.make_room_for(incoming_priority_session)
    victim.remove_metadata!(SpotSessionPause::PREEMPT_MARKED_AT)

    assert_equal 0, SpotPreemption.sweep!.halted
    assert victim.reload.running?
  end

  # === It joins the queue SpotSessionPause already owns ===

  test "a preempted session that has gone dormant is resumed by the ceiling sweep" do
    victim = spot_session(precedence: -1)
    spot_session(precedence: 10)
    SpotPreemption.make_room_for(incoming_priority_session)
    # Its turn ended: the pause callback's execute_pending_sleep is what carries
    # it needs_input -> waiting. Simulated here, since no CLI process is running.
    victim.update!(status: :waiting)
    # And the fleet emptied.
    Session.where(status: :running).update_all(status: Session.statuses[:needs_input])
    GoodJob::Job.delete_all

    assert_equal 1, SpotSessionPause.preempted_count
    assert_equal 0, SpotSessionPause.paused_count,
      "a preempted session is not charged to the budget ceiling"

    result = SpotSessionPause.sweep!

    assert_equal 1, result.resumed
    victim.reload
    assert_nil victim.metadata[SpotSessionPause::PAUSED_REASON]
    assert_nil victim.metadata[SpotSessionPause::PREEMPT_FOR_SESSION]
    assert_equal 1, victim.metadata[SpotPreemption::COUNT],
      "the durable ledger survives the resume, so the cooldown still applies"
  end

  test "the budget ceiling does not overwrite a preemption mark with its own reason" do
    victim = spot_session
    # Marked by hand, exactly as make_room_for leaves it.
    victim.merge_metadata!(
      SpotSessionPause::PAUSED_REASON => SpotSessionPause::PREEMPTED_REASON,
      SpotSessionPause::PAUSED_DETAIL => "preempted"
    )
    decision = SpotGateService::Decision.new(
      allowed: false, reason: SpotGateService::UTILIZATION_REASON, detail: "budget spent",
      five_hour: nil, weekly: nil, active_sessions: 1, awaiting_sessions: 0, fleet_cap: 2,
      accounts_read: 1, pool_size: 1, fleet_burn_usd_per_minute: nil,
      candidate_burn_usd_per_minute: nil, pool_capacity: nil
    )

    SpotSessionPause.send(:pause_running!, decision, {}, StructuredLogger.new({}))

    assert_equal SpotSessionPause::PREEMPTED_REASON,
      victim.reload.metadata[SpotSessionPause::PAUSED_REASON]
  end

  # === Fail-safe ===

  test "an error while choosing a victim leaves the fleet exactly as it was" do
    victim = spot_session(precedence: -1)
    spot_session(precedence: 10)

    SpotPreemption.stub(:preemptable_sessions, ->(*) { raise ActiveRecord::StatementInvalid, "boom" }) do
      assert_nil SpotPreemption.make_room_for(incoming_priority_session)
    end

    assert_nil victim.reload.metadata[SpotSessionPause::PAUSED_REASON]
  end

  test "the spot gate calls preemption for a priority turn and never holds it" do
    victim = spot_session(precedence: -1)
    spot_session(precedence: 10)
    incoming = incoming_priority_session

    refute SpotSessionHold.hold_if_needed(incoming), "a priority turn is never held"
    assert_equal SpotSessionPause::PREEMPTED_REASON,
      victim.reload.metadata[SpotSessionPause::PAUSED_REASON]
  end
end
