# frozen_string_literal: true

require "test_helper"

# The hold is a DEFERRAL, not a refusal. These tests exist mostly to pin that
# down: nothing here may ever start failing a session or dropping its work.
class SpotSessionHoldTest < ActiveSupport::TestCase
  # Not included globally by test_helper — the retry enqueue is the whole point of
  # a deferral, so this test has to be able to see it.
  include ActiveJob::TestHelper

  setup do
    # Same isolation as SpotGateServiceTest: the gate reads the serving account's
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

  # The backoff is a queue-stability property, not politeness. A flat interval
  # means N held sessions put a FIXED N/interval jobs per minute onto `agents`
  # forever — an arrival rate that cannot fall when the system is struggling,
  # which is what produced the 2026-08-20 backlog page.
  test "consecutive utilization holds double the re-check interval" do
    session = build_session(SessionGenesis::GITHUB_ISSUE)
    base = SpotGateService::RETRY_DELAY

    delays = SpotGateService.stub(:evaluate, held_decision) do
      Array.new(3) { hold_and_measure(session) }
    end

    assert_delay_band base, delays[0], "the first hold takes the plain interval"
    assert_delay_band base * 2, delays[1], "the second hold doubles it"
    assert_delay_band base * 4, delays[2], "the third hold doubles again"
  end

  # A utilization hold waits on a quota window coming back down, which takes
  # hours — so it may back off a long way, but not without bound.
  test "a utilization hold stops doubling at its ceiling" do
    session = build_session(SessionGenesis::GITHUB_ISSUE)

    delay = SpotGateService.stub(:evaluate, held_decision) do
      # Four prior rungs would put an unclamped delay at 10m * 2**4 = 160m.
      4.times { SpotSessionHold.hold_if_needed(session.reload) }
      hold_and_measure(session)
    end

    assert_delay_band SpotSessionHold::UTILIZATION_MAX_RETRY_DELAY, delay
  end

  # A fleet-cap hold waits on any running session finishing, which can happen at
  # any moment, so it gets a much shorter ceiling: the backoff exists to stop a
  # STUCK population spinning, not to make a session that could start in five
  # minutes wait an hour.
  test "a fleet-cap hold caps well below the utilization ceiling" do
    session = build_session(SessionGenesis::GITHUB_ISSUE)

    delay = SpotGateService.stub(:evaluate, fleet_cap_decision) do
      4.times { SpotSessionHold.hold_if_needed(session.reload) }
      hold_and_measure(session)
    end

    assert_delay_band SpotSessionHold::FLEET_CAP_MAX_RETRY_DELAY, delay
    assert_operator SpotSessionHold::FLEET_CAP_MAX_RETRY_DELAY, :<,
                    SpotSessionHold::UTILIZATION_MAX_RETRY_DELAY
  end

  # The delay must reach the job as well as the metadata: a HELD_RETRY_AT that
  # says "in an hour" over a job GoodJob will run in ten minutes is a lie the
  # session page would tell, and the re-check load would never actually fall.
  test "the backed-off delay is what the re-check job is scheduled with" do
    session = build_session(SessionGenesis::GITHUB_ISSUE)

    SpotGateService.stub(:evaluate, held_decision) do
      4.times { SpotSessionHold.hold_if_needed(session.reload) }

      assert_enqueued_with(job: AgentSessionJob) do
        SpotSessionHold.hold_if_needed(session.reload)
      end
    end

    enqueued = enqueued_jobs.last
    scheduled_at = Time.zone.at(enqueued["at"] || enqueued[:at])
    retry_at = Time.zone.parse(session.reload.metadata[SpotSessionHold::HELD_RETRY_AT])

    assert_in_delta retry_at.to_f, scheduled_at.to_f, 5
    assert_operator scheduled_at - Time.current, :>, SpotGateService::RETRY_DELAY
  end

  # The whole design rests on jitter being applied AFTER the ceiling. Applied
  # before it, `min(base + jitter, ceiling)` pins every session at exactly the
  # ceiling — a co-held population re-checking in lockstep, which is the failure
  # the jitter existed for. A band assertion cannot see that, because the pinned
  # value sits inside the band; only variance can.
  test "delays still vary once the ladder is pinned at its ceiling" do
    delays = SpotGateService.stub(:evaluate, held_decision) do
      Array.new(12) do
        session = build_session(SessionGenesis::GITHUB_ISSUE)
        4.times { SpotSessionHold.hold_if_needed(session.reload) }
        hold_and_measure(session)
      end
    end

    assert_operator delays.map(&:to_i).uniq.size, :>, 1,
                    "every hold pinned at the ceiling took the same delay — jitter is being " \
                    "applied before the ceiling instead of after it"
  end

  # The three "restart from scratch" paths re-enter the gate looking exactly like a
  # scheduled re-check — no prompt, no resume flag — so the ladder can only know a
  # person asked for this session if they say so. They say so by dropping the hold
  # metadata, which is what this asserts; the callers are covered where they live.
  # Without it, clicking Restart on a session sitting at 40 minutes would push it
  # to an hour, the opposite of what was asked for.
  test "clearing the hold metadata, as a restart does, starts the ladder over" do
    session = build_session(SessionGenesis::GITHUB_ISSUE)

    delay = SpotGateService.stub(:evaluate, held_decision) do
      3.times { SpotSessionHold.hold_if_needed(session.reload) }

      session.update!(metadata: session.metadata.except(*SpotSessionHold::METADATA_KEYS))
      hold_and_measure(session)
    end

    assert_delay_band SpotGateService::RETRY_DELAY, delay
    assert_equal 1, session.reload.metadata[SpotSessionHold::HELD_COUNT]
  end

  # Getting through resets the ladder: the next time this session is held it must
  # start at the plain interval, not resume from wherever the last outage left it.
  test "starting resets the backoff for the next hold" do
    session = build_session(SessionGenesis::GITHUB_ISSUE)

    SpotGateService.stub(:evaluate, held_decision) do
      3.times { SpotSessionHold.hold_if_needed(session.reload) }
    end
    SpotGateService.stub(:evaluate, allowed_decision) { SpotSessionHold.hold_if_needed(session.reload) }

    delay = SpotGateService.stub(:evaluate, held_decision) { hold_and_measure(session) }
    assert_delay_band SpotGateService::RETRY_DELAY, delay
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

  # A delay is correct when it sits in [expected, expected + RETRY_JITTER]: the
  # ladder sets the floor and the jitter is added on top of it. Asserted as a
  # one-sided band rather than a symmetric tolerance, so a rung that came out too
  # SHORT — the failure that would put the arrival rate back where it was — cannot
  # pass by landing inside a delta wide enough to swallow the jitter.
  def assert_delay_band(expected, actual, message = nil)
    drift = 5.seconds
    assert_operator actual, :>=, expected - drift, message
    assert_operator actual, :<=, expected + SpotSessionHold::RETRY_JITTER + drift, message
  end

  # Record one hold and return how far out it scheduled the re-check. Measured
  # from HELD_RETRY_AT because that is the value both the session page and the
  # enqueue are built from.
  def hold_and_measure(session)
    SpotSessionHold.hold_if_needed(session.reload)
    Time.zone.parse(session.reload.metadata[SpotSessionHold::HELD_RETRY_AT]) - Time.current
  end

  def fleet_cap_decision
    SpotGateService::Decision.new(
      allowed: false, reason: "fleet_at_cap",
      detail: "Holding spot sessions: 10 of 10 session slots taken.",
      five_hour: nil, weekly: nil, active_sessions: 10, fleet_cap: 10,
      accounts_read: 2, pool_size: 2
    )
  end

  def held_decision
    SpotGateService::Decision.new(
      allowed: false, reason: "at_utilization_limit",
      detail: "Holding spot sessions: the 5-hour window at 85% of its 80% target, averaged across all 2 accounts.",
      five_hour: nil, weekly: nil, active_sessions: 3, fleet_cap: 10,
      accounts_read: 2, pool_size: 2
    )
  end

  def allowed_decision
    SpotGateService::Decision.new(
      allowed: true, reason: "within_limits",
      detail: "1 of 10 session slots taken, and 5-hour at 12% of its 80% target, averaged across all 2 accounts.",
      five_hour: nil, weekly: nil, active_sessions: 1, fleet_cap: 10,
      accounts_read: 2, pool_size: 2
    )
  end
end
