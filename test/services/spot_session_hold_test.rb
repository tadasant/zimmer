# frozen_string_literal: true

require "test_helper"

# The hold is a DEFERRAL, not a refusal. These tests exist mostly to pin that
# down: nothing here may ever start failing a session or dropping its work.
class SpotSessionHoldTest < ActiveSupport::TestCase
  # Not included globally by test_helper — the retry enqueue is the whole point of
  # a deferral, so this test has to be able to see it.
  include ActiveJob::TestHelper

  setup do
    # Same isolation as SpotGateServiceTest: the controller sizes the whole
    # account pool and multiplies by the running fleet.
    ClaudeAccountQuotaSnapshot.delete_all
    ClaudeAccount.update_all(is_current: false)
    Session.where(status: :running).update_all(status: Session.statuses[:needs_input])
    @setting = AppSetting.editable
    @setting.update!(spot_gating_enabled: false)
  end

  def build_session(genesis)
    Session.create!(git_root: "https://github.com/t/r.git", prompt: "work", genesis: genesis, status: :waiting)
  end

  # Regression: the hold path and SpotGateService.allow_start? must make the SAME
  # decision. When hold_if_needed called the argument-free evaluate, it used the
  # informational reading — which excludes the candidate — so a session
  # allow_start? refused was never actually held, and the gate did nothing.
  test "the hold path makes the same decision as allow_start?" do
    account = ClaudeAccount.create!(email: "hold-parity@example.com", runtime: "claude_code",
                                    oauth_config: { "x" => 1 }, is_current: true)
    now = Time.current
    # 4%/session-hour against a 5-hour window sitting at 79%: one point of
    # headroom carries one concurrent session, and one is already running.
    util = 0.71
    [ 120, 90, 60, 30 ].each do |mins|
      ClaudeAccountQuotaSnapshot.create!(claude_account: account, utilization_5h: util, utilization_7d: 0.10,
        reset_5h: now + 2.hours, reset_7d: now + 2.days, active_session_count: 1,
        trigger: "usage_sample", created_at: now - mins.minutes)
      util += 0.02
    end
    ClaudeAccountQuotaSnapshot.create!(claude_account: account, utilization_5h: 0.79, utilization_7d: 0.10,
      reset_5h: now + 2.hours, reset_7d: now + 2.days, active_session_count: 1,
      trigger: "usage_sample", created_at: now)
    Session.create!(git_root: "https://github.com/t/r.git", prompt: "running", genesis: SessionGenesis::WEB_UI,
                    status: :running, agent_runtime: "claude_code")
    @setting.update!(spot_gating_enabled: true,
                     spot_gate_five_hour_threshold_pct: 80, spot_gate_weekly_threshold_pct: 80)

    session = build_session(SessionGenesis::GITHUB_ISSUE)
    refute SpotGateService.allow_start?(session)
    assert SpotSessionHold.hold_if_needed(session), "hold_if_needed must hold what allow_start? refuses"
  end

  test "a priority session is never held" do
    session = build_session(SessionGenesis::WEB_UI)
    SpotGateService.stub(:evaluate, held_decision) do
      refute SpotSessionHold.hold_if_needed(session)
    end
  end

  test "a spot session is held when the gate says no" do
    session = build_session(SessionGenesis::GITHUB_ISSUE)

    held = nil
    SpotGateService.stub(:evaluate, held_decision) do
      assert_enqueued_with(job: AgentSessionJob) do
        held = SpotSessionHold.hold_if_needed(session)
      end
    end

    assert held
    session.reload
    assert_equal "waiting", session.status, "a held session must stay waiting, not fail"
    assert session.metadata[SpotSessionHold::HELD_DETAIL].present?
    assert_equal 1, session.metadata[SpotSessionHold::HELD_COUNT]
    assert session.metadata[SpotSessionHold::HELD_RETRY_AT].present?
    assert session.metadata[SpotSessionHold::HELD_SINCE].present?
  end

  test "repeated holds increment the counter and keep the original hold time" do
    session = build_session(SessionGenesis::GITHUB_ISSUE)

    SpotGateService.stub(:evaluate, held_decision) do
      SpotSessionHold.hold_if_needed(session)
      first_held = session.reload.metadata[SpotSessionHold::HELD_SINCE]
      SpotSessionHold.hold_if_needed(session.reload)

      assert_equal first_held, session.reload.metadata[SpotSessionHold::HELD_SINCE],
        "the starvation clock measures from the FIRST hold, so re-holding must not reset it"
    end

    assert_equal 2, session.reload.metadata[SpotSessionHold::HELD_COUNT]
  end

  # Held sessions re-check within a jittered spread rather than all at once: a
  # backlog held in the same minute would otherwise re-evaluate in lockstep, every
  # one of them reading the same fleet size before any of them had started.
  test "the retry is delayed by a control interval plus jitter" do
    floor = SpotGateService::CONTROL_INTERVAL
    ceiling = floor + SpotSessionHold::RETRY_JITTER

    5.times do
      session = build_session(SessionGenesis::GITHUB_ISSUE)
      SpotGateService.stub(:evaluate, held_decision) { SpotSessionHold.hold_if_needed(session) }

      retry_at = Time.zone.parse(session.reload.metadata[SpotSessionHold::HELD_RETRY_AT])
      assert_operator retry_at, :>=, Time.current + floor - 5.seconds
      assert_operator retry_at, :<=, Time.current + ceiling + 5.seconds
    end
  end

  # Liveness. Production held session #4562 for 23 hours with nothing bounding it.
  # The floor is deliberately narrow: the deadline has to have passed AND the
  # fleet has to be empty, so it drains a starved queue without becoming a second
  # way to run work while the deployment is already busy.
  test "a session held past the deadline is released once nothing is running" do
    session = build_session(SessionGenesis::GITHUB_ISSUE)
    SpotGateService.stub(:evaluate, held_decision) { SpotSessionHold.hold_if_needed(session) }

    age_the_hold(session, SpotGateService::CONTROL_INTERVAL)
    SpotGateService.stub(:evaluate, held_decision) do
      assert SpotSessionHold.hold_if_needed(session.reload), "not starved yet — the deadline has not passed"
    end

    age_the_hold(session, SpotSessionHold::STARVATION_DEADLINE + 1.minute)
    SpotGateService.stub(:evaluate, held_decision) do
      refute SpotSessionHold.hold_if_needed(session.reload), "a starved session starts once the fleet is idle"
    end

    session.reload
    SpotSessionHold::METADATA_KEYS.each do |key|
      refute session.metadata.key?(key), "#{key} should be cleared when the session is released"
    end
  end

  test "the starvation floor does not fire while the fleet is busy" do
    session = build_session(SessionGenesis::GITHUB_ISSUE)
    SpotGateService.stub(:evaluate, held_decision) { SpotSessionHold.hold_if_needed(session) }
    age_the_hold(session, SpotSessionHold::STARVATION_DEADLINE + 1.hour)
    Session.create!(git_root: "https://github.com/t/r.git", prompt: "running", genesis: SessionGenesis::WEB_UI,
                    status: :running, agent_runtime: "claude_code")

    SpotGateService.stub(:evaluate, held_decision) do
      assert SpotSessionHold.hold_if_needed(session.reload),
        "capacity is already spoken for — the floor is for a starved queue, not a busy one"
    end
  end

  test "a hold is cleared once the session is allowed through" do
    session = build_session(SessionGenesis::GITHUB_ISSUE)
    SpotGateService.stub(:evaluate, held_decision) { SpotSessionHold.hold_if_needed(session) }
    assert session.reload.metadata[SpotSessionHold::HELD_DETAIL].present?

    SpotGateService.stub(:evaluate, allowed_decision) do
      refute SpotSessionHold.hold_if_needed(session.reload)
    end

    session.reload
    SpotSessionHold::METADATA_KEYS.each do |key|
      refute session.metadata.key?(key), "#{key} should be cleared once the session starts"
    end
  end

  test "clearing a session that was never held is a no-op" do
    session = build_session(SessionGenesis::WEB_UI)
    assert_nothing_raised { SpotSessionHold.clear(session) }
  end

  private

  # Backdate the first-hold stamp so the starvation clock reads `age`.
  def age_the_hold(session, age)
    session.reload
    session.update_columns(
      metadata: session.metadata.merge(SpotSessionHold::HELD_SINCE => (Time.current - age).iso8601)
    )
  end

  def held_decision
    SpotGateService::Decision.new(
      allowed: false, reason: "at_capacity",
      detail: "Holding spot sessions: the fleet is at the 3 concurrent sessions quota can carry.",
      forecast_5h: nil, forecast_7d: nil, rate: nil,
      active_sessions: 3, forecast_sessions: 4, capacity: 3, fleet_cap: 10,
      accounts_considered: 1, account_email: "pool@example.com"
    )
  end

  def allowed_decision
    SpotGateService::Decision.new(
      allowed: true, reason: "within_capacity",
      detail: "Room for 10 concurrent spot sessions and 1 running.",
      forecast_5h: nil, forecast_7d: nil, rate: nil,
      active_sessions: 1, forecast_sessions: 2, capacity: 10, fleet_cap: 10,
      accounts_considered: 1, account_email: "pool@example.com"
    )
  end
end
