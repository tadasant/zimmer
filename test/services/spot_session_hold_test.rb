# frozen_string_literal: true

require "test_helper"

# The hold is a DEFERRAL, not a refusal. These tests exist mostly to pin that
# down: nothing here may ever start failing a session or dropping its work.
class SpotSessionHoldTest < ActiveSupport::TestCase
  # Not included globally by test_helper — the retry enqueue is the whole point of
  # a deferral, so this test has to be able to see it.
  include ActiveJob::TestHelper

  setup do
    # Same isolation as SpotGateServiceTest: the gate reads every usable account's
    # latest snapshot and counts every running session.
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
  # decision. When hold_if_needed called a different reading from the one
  # allow_start? consulted, a session allow_start? refused was never actually
  # held, and the gate did nothing.
  test "the hold path makes the same decision as allow_start?" do
    account = ClaudeAccount.create!(email: "hold-parity@example.com", runtime: "claude_code",
                                    oauth_config: { "x" => 1 }, is_current: true)
    ClaudeAccountQuotaSnapshot.create!(claude_account: account, utilization_5h: 0.85, utilization_7d: 0.10,
      reset_5h: 2.hours.from_now, reset_7d: 2.days.from_now, active_session_count: 1,
      trigger: "usage_sample")
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
    assert_equal "at_utilization_limit", session.metadata[SpotSessionHold::HELD_REASON]
    assert_equal 1, session.metadata[SpotSessionHold::HELD_COUNT]
    assert session.metadata[SpotSessionHold::HELD_RETRY_AT].present?
  end

  test "repeated holds increment the counter" do
    session = build_session(SessionGenesis::GITHUB_ISSUE)

    SpotGateService.stub(:evaluate, held_decision) do
      SpotSessionHold.hold_if_needed(session)
      SpotSessionHold.hold_if_needed(session.reload)
    end

    assert_equal 2, session.reload.metadata[SpotSessionHold::HELD_COUNT]
  end

  # Held sessions re-check within a jittered spread rather than all at once: a
  # backlog held in the same minute would otherwise re-evaluate in lockstep, every
  # one of them reading the same fleet size before any of them had started.
  test "the retry is delayed by the re-check interval plus jitter" do
    floor = SpotGateService::RETRY_DELAY
    ceiling = floor + SpotSessionHold::RETRY_JITTER

    5.times do
      session = build_session(SessionGenesis::GITHUB_ISSUE)
      SpotGateService.stub(:evaluate, held_decision) { SpotSessionHold.hold_if_needed(session) }

      retry_at = Time.zone.parse(session.reload.metadata[SpotSessionHold::HELD_RETRY_AT])
      assert_operator retry_at, :>=, Time.current + floor - 5.seconds
      assert_operator retry_at, :<=, Time.current + ceiling + 5.seconds
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

  def held_decision
    SpotGateService::Decision.new(
      allowed: false, reason: "at_utilization_limit",
      detail: "Holding spot sessions: the 5-hour window at 85% of its 80% target on pool@example.com.",
      five_hour: nil, weekly: nil, active_sessions: 3, fleet_cap: 10,
      accounts_considered: 1, account_email: "pool@example.com"
    )
  end

  def allowed_decision
    SpotGateService::Decision.new(
      allowed: true, reason: "within_limits",
      detail: "1 of 10 session slots taken, and 5-hour at 12% of its 80% target.",
      five_hour: nil, weekly: nil, active_sessions: 1, fleet_cap: 10,
      accounts_considered: 1, account_email: "pool@example.com"
    )
  end
end
