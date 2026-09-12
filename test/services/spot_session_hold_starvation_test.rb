# frozen_string_literal: true

require "test_helper"

# The starvation lane: the one bound on how long a hold lasts, and the one hole
# in the budget ceiling. These tests pin both halves — that a session held past
# the age ceiling gets through, and that nothing else does (tadasant/zimmer#693).
class SpotSessionHoldStarvationTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    ClaudeAccountQuotaSnapshot.delete_all
    ClaudeAccount.update_all(is_current: false)
    Session.where(status: :running).update_all(status: Session.statuses[:needs_input])
    GoodJob::Job.where(job_class: "AgentSessionJob").delete_all
    @setting = AppSetting.editable
    @setting.update!(spot_gating_enabled: false, spot_starvation_age_ceiling_hours: 24)
  end

  def build_session(genesis = SessionGenesis::GITHUB_ISSUE, status: :waiting, metadata: {})
    Session.create!(git_root: "https://github.com/t/r.git", prompt: "work", genesis: genesis,
                    status: status, agent_runtime: "claude_code", metadata: metadata)
  end

  # The production shape from the issue: a ladder that has been re-armed
  # correctly `count` times, first held `since` ago.
  def held_session(since:, count: 127, reason: "at_utilization_limit", **opts)
    build_session(
      **opts,
      metadata: {
        SpotSessionHold::HELD_AT => 30.minutes.ago.utc.iso8601,
        SpotSessionHold::HELD_SINCE => since.utc.iso8601,
        SpotSessionHold::HELD_REASON => reason,
        SpotSessionHold::HELD_DETAIL => "Holding spot sessions: weekly window has spent its spot budget.",
        SpotSessionHold::HELD_RETRY_AT => 30.minutes.from_now.utc.iso8601,
        SpotSessionHold::HELD_COUNT => count,
        SpotSessionHold::HELD_TURN => SpotSessionHold::TURN_START
      }
    )
  end

  # The job row a worker holds while it runs a turn — what makes a session
  # count as "in flight" to the lane.
  def put_on_a_worker(session)
    GoodJob::Job.create!(active_job_id: SecureRandom.uuid, queue_name: "agents",
      job_class: "AgentSessionJob", serialized_params: { "arguments" => [ session.id ] },
      scheduled_at: 2.minutes.ago, performed_at: 1.minute.ago)
  end

  # --- the ladder's age -------------------------------------------------------

  test "the first hold stamps spot_hold_since and later rungs carry it forward" do
    session = build_session

    SpotGateService.stub(:evaluate, held_decision) do
      assert SpotSessionHold.hold_if_needed(session)
    end
    first = session.reload.metadata[SpotSessionHold::HELD_SINCE]
    assert first.present?, "the first rung must record when the ladder began"
    assert_equal first, session.metadata[SpotSessionHold::HELD_AT]

    travel 3.hours do
      SpotGateService.stub(:evaluate, held_decision) do
        assert SpotSessionHold.hold_if_needed(session)
      end
      session.reload
      assert_equal first, session.metadata[SpotSessionHold::HELD_SINCE],
        "a later rung must not restart the clock — that is how a 127-hold ladder read as an hour old"
      refute_equal first, session.metadata[SpotSessionHold::HELD_AT]
      assert_equal 2, session.metadata[SpotSessionHold::HELD_COUNT]
      assert_in_delta 3.hours.to_i, SpotSessionHold.record_for(session).waiting_for.to_i, 60
    end
  end

  test "a ladder written before spot_hold_since existed inherits its last spot_hold_at" do
    session = build_session(metadata: {
      SpotSessionHold::HELD_AT => 5.hours.ago.utc.iso8601,
      SpotSessionHold::HELD_REASON => "at_utilization_limit",
      SpotSessionHold::HELD_DETAIL => "held",
      SpotSessionHold::HELD_RETRY_AT => 1.minute.ago.utc.iso8601,
      SpotSessionHold::HELD_COUNT => 40
    })

    SpotGateService.stub(:evaluate, held_decision) do
      assert SpotSessionHold.hold_if_needed(session)
    end

    assert_in_delta 5.hours.to_i, SpotSessionHold.record_for(session.reload).waiting_for.to_i, 60
  end

  # --- the lane ---------------------------------------------------------------

  # THE STARVATION PATH. Session 8526's shape: 127 correct holds, five days, a
  # gate that still says no. The lane says yes, once, and writes down that it did.
  test "a session held past the age ceiling is admitted, and the admission is recorded" do
    session = held_session(since: 5.days.ago, count: 127)

    held = nil
    SpotGateService.stub(:evaluate, held_decision) do
      assert_no_enqueued_jobs(only: AgentSessionJob) do
        held = SpotSessionHold.hold_if_needed(session)
      end
    end

    refute held, "the turn must run — this is the whole bound on 'deferred, never cancelled'"
    session.reload
    refute SpotSessionHold.held?(session), "the hold record goes with the admission"
    assert_nil session.metadata[SpotSessionHold::HELD_COUNT]
    assert SpotSessionHold.starvation_admission_for(session)
    admission = SpotSessionHold.starvation_admission_for(session)
    assert_equal 127, admission.after_holds
    assert_in_delta 5.days.to_i, admission.after_seconds, 60
    assert_in_delta Time.current, admission.admitted_at, 5
    assert_match(/admitted by the starvation lane/, admission.sentence(running: true))
    assert_match(/127 times over 5 days.*It runs to its end/, admission.sentence(running: true))
    assert_match(/That turn has ended/, admission.sentence(running: false))
    log = session.logs.where(level: "warning").last
    assert log, "the admission must be readable in the session's own timeline"
    assert_match(/admitted by the starvation lane, not by the gate/, log.content)
    assert_match(/127 times over 5 days/, log.content)
    assert_match(/24 hours/, log.content)
  end

  # The incident's production shape: the session is at rest, its re-check fires
  # (the retry stamp is now in the past) carrying the deferred prompt, and the
  # gate still says no. This is the turn the lane admits.
  test "a resume whose re-check has fired is admitted with its prompt" do
    session = held_session(since: 3.days.ago, count: 73, status: :needs_input)
    session.merge_metadata!(SpotSessionHold::HELD_RETRY_AT => 1.minute.ago.utc.iso8601,
                            SpotSessionHold::HELD_TURN => SpotSessionHold::TURN_RESUME,
                            SpotSessionHold::HELD_PROMPT => "continue")

    SpotGateService.stub(:evaluate, held_decision) do
      assert_no_enqueued_jobs(only: AgentSessionJob) do
        refute SpotSessionHold.hold_if_needed(session, follow_up_prompt: "continue")
      end
    end

    session.reload
    admission = SpotSessionHold.starvation_admission_for(session)
    assert_equal 73, admission.after_holds
    assert_nil session.metadata[SpotSessionHold::HELD_PROMPT], "the hold record, prompt included, goes with the admission"
    assert_equal 0, session.enqueued_messages.count, "the prompt runs now rather than queueing"
  end

  test "a session held for less than the ceiling is held again" do
    session = held_session(since: 23.hours.ago, count: 27)

    SpotGateService.stub(:evaluate, held_decision) do
      assert_enqueued_with(job: AgentSessionJob) do
        assert SpotSessionHold.hold_if_needed(session)
      end
    end

    session.reload
    assert SpotSessionHold.held?(session)
    assert_equal 28, session.metadata[SpotSessionHold::HELD_COUNT]
    assert_nil SpotSessionHold.starvation_admission_for(session)
  end

  test "the lane is one session wide" do
    occupant = build_session(status: :running,
      metadata: { SpotSessionHold::STARVATION_ADMITTED_AT => 10.minutes.ago.utc.iso8601 })
    put_on_a_worker(occupant)
    session = held_session(since: 3.days.ago, count: 70)

    SpotGateService.stub(:evaluate, held_decision) do
      assert_enqueued_with(job: AgentSessionJob) do
        assert SpotSessionHold.hold_if_needed(session), "a second starved session waits for the first's turn to end"
      end
    end

    assert SpotSessionHold.held?(session.reload)
    assert_equal [ occupant.id ], SpotSessionHold.starvation_lane_occupants
  end

  # The marker outlives the turn until the session next meets the gate, so the
  # lane has to read what the session is DOING, not what it carries.
  test "a starvation-admitted session that finished its turn does not hold the lane" do
    finished = build_session(status: :needs_input,
      metadata: { SpotSessionHold::STARVATION_ADMITTED_AT => 3.hours.ago.utc.iso8601 })
    asleep = build_session(status: :waiting,
      metadata: { SpotSessionHold::STARVATION_ADMITTED_AT => 3.hours.ago.utc.iso8601 })
    session = held_session(since: 2.days.ago, count: 50)

    assert_empty SpotSessionHold.starvation_lane_occupants
    SpotGateService.stub(:evaluate, held_decision) do
      refute SpotSessionHold.hold_if_needed(session)
    end
    assert SpotSessionHold.starvation_admission_for(session.reload)
    assert finished.reload.needs_input? && asleep.reload.waiting?
  end

  # #hold! queues a second prompt behind a re-check that is still scheduled so
  # that one session never has two jobs racing it. The lane keeps that: the
  # re-check is the turn it admits, and the prompt is delivered behind it.
  test "a resume arriving while a re-check is still scheduled is queued behind it, not admitted" do
    session = held_session(since: 5.days.ago, count: 127, status: :needs_input)

    SpotGateService.stub(:evaluate, held_decision) do
      assert_no_enqueued_jobs(only: AgentSessionJob) do
        assert SpotSessionHold.hold_if_needed(session, follow_up_prompt: "please continue")
      end
    end

    session.reload
    assert_nil SpotSessionHold.starvation_admission_for(session)
    assert_equal 127, session.metadata[SpotSessionHold::HELD_COUNT], "not a new rung either"
    assert_equal 1, session.enqueued_messages.count, "the prompt waits behind the scheduled re-check"
  end

  test "the lane never overrides the fleet cap, and the surfaces do not count a fleet-cap hold as starved" do
    session = held_session(since: 5.days.ago, count: 127, reason: "fleet_at_cap")

    SpotGateService.stub(:evaluate, fleet_cap_decision) do
      assert_enqueued_with(job: AgentSessionJob) do
        assert SpotSessionHold.hold_if_needed(session), "a full fleet is priority work crowding spot out, which is the intent"
      end
    end

    assert_nil SpotSessionHold.starvation_admission_for(session.reload)
    record = SpotSessionHold.record_for(session)
    refute record.starved?(ceiling: 24.hours), "a surface that called this starved would promise an admission that never comes"
    refute record.lane_applies?
    assert_equal 0, SpotSessionHold.starved_count
  end

  test "the occupancy read leaves the asking session out and ignores a marker-carrier whose only job is scheduled" do
    asker = build_session(status: :waiting,
      metadata: { SpotSessionHold::STARVATION_ADMITTED_AT => 1.minute.ago.utc.iso8601 })
    put_on_a_worker(asker)
    scheduled = build_session(status: :waiting,
      metadata: { SpotSessionHold::STARVATION_ADMITTED_AT => 3.hours.ago.utc.iso8601 })
    GoodJob::Job.create!(active_job_id: SecureRandom.uuid, queue_name: "agents",
      job_class: "AgentSessionJob", serialized_params: { "arguments" => [ scheduled.id ] },
      scheduled_at: 20.minutes.from_now)

    assert_equal [ asker.id ], SpotSessionHold.starvation_lane_occupants
    assert_empty SpotSessionHold.starvation_lane_occupants(excluding: asker.id)
  end

  test "a ceiling of zero turns the lane off" do
    @setting.update!(spot_starvation_age_ceiling_hours: 0)
    session = held_session(since: 30.days.ago, count: 700)

    SpotGateService.stub(:evaluate, held_decision) do
      assert SpotSessionHold.hold_if_needed(session)
    end

    assert SpotSessionHold.held?(session.reload)
    assert_nil SpotSessionHold.starvation_admission_for(session)
    assert_equal 0, SpotSessionHold.starved_count
  end

  test "an unreadable lane admits nothing" do
    session = held_session(since: 5.days.ago, count: 127)

    PendingAgentTurns.stub(:split, ->(*) { raise ActiveRecord::StatementInvalid, "boom" }) do
      build_session(status: :waiting,
        metadata: { SpotSessionHold::STARVATION_ADMITTED_AT => 3.hours.ago.utc.iso8601 })
      assert_equal [ :unreadable ], SpotSessionHold.starvation_lane_occupants
      SpotGateService.stub(:evaluate, held_decision) do
        assert SpotSessionHold.hold_if_needed(session), "a monitoring gap must not become a bypass"
      end
    end

    assert SpotSessionHold.held?(session.reload)
  end

  # --- the admission is one turn ------------------------------------------------

  test "the next turn meets the gate again: an ordinary admission drops the marker, a hold starts a fresh ladder" do
    session = build_session(status: :needs_input,
      metadata: { SpotSessionHold::STARVATION_ADMITTED_AT => 2.hours.ago.utc.iso8601,
                  SpotSessionHold::STARVATION_ADMITTED_AFTER_HOLDS => 127 })

    SpotGateService.stub(:evaluate, allowed_decision) do
      refute SpotSessionHold.hold_if_needed(session, follow_up_prompt: "continue")
    end
    assert_nil SpotSessionHold.starvation_admission_for(session.reload),
      "the marker exempts a turn from the pause sweep, so it must not outlive the turn it was written for"

    session.update!(status: :waiting,
      metadata: { SpotSessionHold::STARVATION_ADMITTED_AT => 2.hours.ago.utc.iso8601 })
    SpotGateService.stub(:evaluate, held_decision) do
      assert SpotSessionHold.hold_if_needed(session, follow_up_prompt: "continue")
    end
    session.reload
    assert_nil SpotSessionHold.starvation_admission_for(session)
    assert_equal 1, session.metadata[SpotSessionHold::HELD_COUNT]
    assert_in_delta Time.current, SpotSessionHold.record_for(session).since, 5
  end

  # --- the readers the surfaces print -----------------------------------------

  test "starved_count, oldest_hold_age and the Record's own reading agree" do
    oldest = held_session(since: 30.hours.ago, count: 31)
    held_session(since: 2.hours.ago, count: 3)
    build_session(metadata: {  # a pre-HELD_SINCE ladder: HELD_AT stands in
      SpotSessionHold::HELD_AT => 26.hours.ago.utc.iso8601,
      SpotSessionHold::HELD_REASON => "at_utilization_limit",
      SpotSessionHold::HELD_RETRY_AT => 30.minutes.from_now.utc.iso8601,
      SpotSessionHold::HELD_COUNT => 30
    })

    assert_equal 2, SpotSessionHold.starved_count
    assert_in_delta 30.hours.to_i, SpotSessionHold.oldest_hold_age.to_i, 60
    assert_equal 1, SpotSessionHold.starved_count(ceiling: 28.hours)
    assert_equal 0, SpotSessionHold.starved_count(ceiling: nil)

    record = SpotSessionHold.record_for(oldest.reload)
    assert record.starved?(ceiling: 24.hours)
    refute record.starved?(ceiling: nil)
    assert_match(/31 holds so far/, record.waiting_sentence)
    assert_match(/1 day/, record.waiting_sentence)
  end

  test "the explanation names the ceiling, the oldest wait, the count past it and the occupant" do
    held_session(since: 30.hours.ago, count: 31)
    occupant = build_session(status: :running,
      metadata: { SpotSessionHold::STARVATION_ADMITTED_AT => 10.minutes.ago.utc.iso8601 })
    put_on_a_worker(occupant)

    starvation = SpotHoldExplanation::Starvation.read(setting: @setting)
    sentence = SpotHoldExplanation.new(held_decision, paused_count: 0, held_count: 1, starvation: starvation)
      .sessions_starved

    assert_match(/oldest has been waiting/, sentence)
    assert_match(/1 has waited past the 24 hours age ceiling/, sentence)
    assert_match(/running session ##{occupant.id}/, sentence)

    @setting.update!(spot_starvation_age_ceiling_hours: 0)
    off = SpotHoldExplanation.new(held_decision, paused_count: 0, held_count: 1,
                                  starvation: SpotHoldExplanation::Starvation.read(setting: @setting.reload))
      .sessions_starved
    assert_match(/starvation lane is off/, off)
    assert_match(/no bound/, off)
  end

  test "the setting is validated and reads as a duration" do
    assert @setting.update(spot_starvation_age_ceiling_hours: 0)
    assert_nil @setting.spot_starvation_age_ceiling
    assert @setting.update(spot_starvation_age_ceiling_hours: 36)
    assert_equal 36.hours, @setting.spot_starvation_age_ceiling
    refute @setting.update(spot_starvation_age_ceiling_hours: -1)
    refute @setting.update(spot_starvation_age_ceiling_hours: AppSetting::MAX_SPOT_STARVATION_AGE_CEILING_HOURS + 1)
  end

  def held_decision
    SpotGateService::Decision.new(
      allowed: false, reason: "at_utilization_limit",
      detail: "Holding spot sessions: weekly window has spent its spot budget, averaged across all 2 accounts.",
      five_hour: nil, weekly: nil, active_sessions: 3, awaiting_sessions: 0, fleet_cap: 10,
      accounts_read: 2, pool_size: 2,
      fleet_burn_usd_per_minute: 0.0, candidate_burn_usd_per_minute: 0.0,
      pool_capacity: nil
    )
  end

  def fleet_cap_decision
    SpotGateService::Decision.new(
      allowed: false, reason: "fleet_at_cap",
      detail: "Holding spot sessions: 10 of 10 session slots taken.",
      five_hour: nil, weekly: nil, active_sessions: 10, awaiting_sessions: 0, fleet_cap: 10,
      accounts_read: 2, pool_size: 2,
      fleet_burn_usd_per_minute: 0.0, candidate_burn_usd_per_minute: 0.0,
      pool_capacity: nil
    )
  end

  def allowed_decision
    SpotGateService::Decision.new(
      allowed: true, reason: "within_limits",
      detail: "1 of 10 session slots taken.",
      five_hour: nil, weekly: nil, active_sessions: 1, awaiting_sessions: 0, fleet_cap: 10,
      accounts_read: 2, pool_size: 2,
      fleet_burn_usd_per_minute: 0.0, candidate_burn_usd_per_minute: 0.0,
      pool_capacity: nil
    )
  end
end

# The lane is exactly one wide, and that has to hold when two re-checks perform
# in the same instant — every re-check whose time passed during a deploy becomes
# ready at once. The occupancy read and the marker write are one critical
# section under an advisory lock; without it both would read an empty lane and
# both admit.
#
# Its own class, off the transactional fixture, because the race needs two real
# connections: under `use_transactional_tests` every thread shares one locked
# connection, the two transactions nest, and nothing is concurrent.
class SpotSessionHoldStarvationLaneRaceTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  setup do
    # `AppSetting.editable` is `order(:id).first || new`, so this line CREATES the
    # singleton row when there is none — and this class is non-transactional, so
    # the row outlives the test and every later one in this parallel worker sees
    # it. That is not a cosmetic leak: `only_one_row` is a create-context
    # validation, so `AppSetting.new(...).valid?` is FALSE while any row exists,
    # and AppSettingTest's positive cases fail wherever the split happens to put
    # them. Two of them did, on the `main` CI run that went red after PR #1180
    # merged — a run whose diff touches nothing near AppSetting.
    #
    # Captured verbatim and put back in teardown, exactly as
    # QuotaAvailabilityMonitorConcurrencyTest does it — which documented this
    # hazard before this class reproduced it.
    # `@sessions` first, so a setup that raises between here and the end still
    # leaves the teardown something to iterate.
    @sessions = []

    existing = AppSetting.order(:id).first
    @previous_setting = existing&.slice(:spot_gating_enabled, :spot_starvation_age_ceiling_hours)

    AppSetting.editable.update!(spot_gating_enabled: false, spot_starvation_age_ceiling_hours: 24)
  end

  teardown do
    # The setting goes back FIRST. ActiveSupport stops the teardown chain at the
    # first callback that raises, and this block is one callback — so a restore
    # placed after the session cleanup is a restore that a failing `destroy_all`
    # skips, which is exactly the leak this teardown exists to prevent.
    if @previous_setting
      AppSetting.editable.update!(@previous_setting)
    else
      AppSetting.delete_all
    end

    ids = @sessions.map(&:id)
    GoodJob::Job.where("serialized_params -> 'arguments' ->> 0 IN (?)", ids.map(&:to_s)).delete_all
    Session.where(id: ids).destroy_all
  end

  def starved_session(since:, count:)
    @sessions << Session.create!(
      git_root: "https://github.com/t/r.git", prompt: "work", genesis: SessionGenesis::GITHUB_ISSUE,
      status: :waiting, agent_runtime: "claude_code",
      metadata: {
        SpotSessionHold::HELD_AT => 30.minutes.ago.utc.iso8601,
        SpotSessionHold::HELD_SINCE => since.utc.iso8601,
        SpotSessionHold::HELD_REASON => "at_utilization_limit",
        SpotSessionHold::HELD_DETAIL => "held",
        SpotSessionHold::HELD_RETRY_AT => 1.minute.ago.utc.iso8601,
        SpotSessionHold::HELD_COUNT => count,
        SpotSessionHold::HELD_TURN => SpotSessionHold::TURN_START
      }
    )
    @sessions.last
  end

  test "two starved sessions admitted concurrently take the lane one at a time" do
    first = starved_session(since: 5.days.ago, count: 127)
    second = starved_session(since: 4.days.ago, count: 100)
    decision = SpotGateService::Decision.new(
      allowed: false, reason: "at_utilization_limit", detail: "Holding spot sessions: budget spent.",
      five_hour: nil, weekly: nil, active_sessions: 3, awaiting_sessions: 0, fleet_cap: 10,
      accounts_read: 2, pool_size: 2, fleet_burn_usd_per_minute: 0.0, candidate_burn_usd_per_minute: 0.0,
      pool_capacity: nil
    )
    # Each admitted session is put on a worker BEFORE its gate check, as it is
    # in production (the re-check job holds the turn while the gate runs), so
    # the first to land its marker is in flight when the second reads the lane.
    [ first, second ].each do |session|
      GoodJob::Job.create!(active_job_id: SecureRandom.uuid, queue_name: "agents",
        job_class: "AgentSessionJob", serialized_params: { "arguments" => [ session.id ] },
        scheduled_at: 2.minutes.ago, performed_at: 1.minute.ago)
    end

    results = {}
    SpotGateService.stub(:evaluate, decision) do
      barrier = Queue.new
      threads = [ first, second ].map do |session|
        Thread.new do
          ActiveRecord::Base.connection_pool.with_connection do
            barrier.pop
            results[session.id] = SpotSessionHold.hold_if_needed(session)
          end
        end
      end
      2.times { barrier << true }
      threads.each(&:join)
    end

    admitted = [ first, second ].count { |session| !results.fetch(session.id) }
    assert_equal 1, admitted, "exactly one of two concurrent starved sessions gets the lane (results: #{results})"
    assert_equal 1, [ first, second ].count { |session| SpotSessionHold.starvation_admission_for(session.reload) }
  end
end
