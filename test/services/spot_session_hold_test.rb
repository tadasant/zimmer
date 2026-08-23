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
                     spot_reserve_five_hour_pct: 20, spot_reserve_weekly_pct: 20)

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

  # ---------------------------------------------------------------------------
  # A resume is a turn, and a turn is what the gate holds
  # ---------------------------------------------------------------------------

  # THE BYPASS. Until 2026-08-22 a prompt exempted the turn entirely, so a spot
  # session woken by its own backstop trigger ran while the gate held 141 others.
  test "a resume is held when a window is at its target" do
    session = build_session(SessionGenesis::GITHUB_ISSUE)
    session.update!(status: :running)

    held = SpotGateService.stub(:evaluate, held_decision) do
      SpotSessionHold.hold_if_needed(session, follow_up_prompt: "Backstop wake (round 2).")
    end

    assert held, "a wake delivered as a prompt is still a turn, and a turn is gated"
    session.reload
    assert_equal "waiting", session.status, "a deferred resume goes back to the spot queue"
    assert_equal SpotSessionHold::TURN_RESUME, session.metadata[SpotSessionHold::HELD_TURN]
    assert_equal "at_utilization_limit", session.metadata[SpotSessionHold::HELD_REASON]
  end

  # The pending prompt is the work. Dropping it would be a worse bug than the one
  # the gate closes, so the retry has to be a complete replacement for the turn.
  test "a deferred resume re-enqueues its prompt, images and files" do
    session = build_session(SessionGenesis::GITHUB_ISSUE)
    session.update!(status: :running)
    images = [ { "path" => "/tmp/a.png", "media_type" => "image/png" } ]
    files = [ { "path" => "/tmp/a.txt", "original_filename" => "a.txt", "size" => 3 } ]

    SpotGateService.stub(:evaluate, held_decision) do
      assert_enqueued_with(job: AgentSessionJob) do
        SpotSessionHold.hold_if_needed(session, follow_up_prompt: "Please continue",
                                      images: images, files: files)
      end
    end

    args = enqueued_jobs.last["args"] || enqueued_jobs.last[:args]
    assert_equal session.id, args[0]
    assert_equal "Please continue", args[1]
    assert_equal images, args[2]["images"].map { |image| image.except("_aj_symbol_keys") }
    assert_equal files, args[2]["files"].map { |file| file.except("_aj_symbol_keys") }
  end

  # A deferral must not look like a finished turn. `pause!` fires the
  # session_needs_input triggers (waking a watching parent), enqueues a push
  # notification and queues a status-summary refresh — announcements about a turn
  # that never ran.
  test "a deferred resume does not announce itself as needing input" do
    session = build_session(SessionGenesis::GITHUB_ISSUE)
    session.update!(status: :running)

    SpotGateService.stub(:evaluate, held_decision) do
      SpotSessionHold.hold_if_needed(session, follow_up_prompt: "Please continue")
    end

    assert_equal "waiting", session.reload.status
    assert_no_enqueued_jobs only: SendPushNotificationJob
    assert_no_enqueued_jobs only: AoEventTriggerJob
  end

  # A session sitting in `needs_input` when its turn is refused is put to sleep
  # rather than left on the human action queue: nobody has to do anything about a
  # deferred spot turn.
  test "a resume refused while the session is idle sleeps it out of the action queue" do
    session = build_session(SessionGenesis::GITHUB_ISSUE)
    session.update!(status: :needs_input)

    SpotGateService.stub(:evaluate, held_decision) do
      SpotSessionHold.hold_if_needed(session, follow_up_prompt: "Please continue")
    end

    assert_equal "waiting", session.reload.status
  end

  # A session that is ALREADY `running` when the gate runs has been flipped there
  # by whoever delivered the turn, so it is counted in the fleet itself. Refusing
  # it for `fleet_at_cap` would refuse it on the strength of its own slot — and
  # would refuse every session SpotSessionPause resumes, since those are flipped
  # to `running` before their jobs run, which would break the ceiling's resume
  # path outright.
  test "a resume is not held for a full fleet" do
    session = build_session(SessionGenesis::GITHUB_ISSUE)
    session.update!(status: :running)

    held = SpotGateService.stub(:evaluate, fleet_cap_decision) do
      SpotSessionHold.hold_if_needed(session, follow_up_prompt: "Please continue")
    end

    refute held
    assert_equal "running", session.reload.status
  end

  # The other half of the carve-out, and the one that would have been a hole. A
  # turn already deferred once comes back as a re-check on a session sitting in
  # `waiting` — it holds no slot, so the cap has to apply to it like any
  # admission. Keying the exemption on "this turn carries a prompt" would have
  # exempted exactly the population the gate itself creates.
  test "a deferred turn's re-check is held for a full fleet" do
    session = build_session(SessionGenesis::GITHUB_ISSUE)

    held = SpotGateService.stub(:evaluate, fleet_cap_decision) do
      SpotSessionHold.hold_if_needed(session, follow_up_prompt: "Please continue")
    end

    assert held, "a dormant session's turn holds no slot, so the fleet cap refuses it"
    assert_equal "waiting", session.reload.status
  end

  test "a first start is still held for a full fleet" do
    session = build_session(SessionGenesis::GITHUB_ISSUE)

    held = SpotGateService.stub(:evaluate, fleet_cap_decision) do
      SpotSessionHold.hold_if_needed(session)
    end

    assert held
    assert_equal SpotSessionHold::TURN_START, session.reload.metadata[SpotSessionHold::HELD_TURN]
  end

  # Issue #589. Every "restart from scratch" path — the Restart button,
  # `action_session`, `POST /api/v1/sessions/:id/restart` — calls `resume!` and
  # THEN enqueues a promptless job. A hold that left the session in `running`
  # with no job handed it straight to CleanupOrphanedSessionsJob, which reads
  # exactly that as orphaned and reaps it within five minutes — well before the
  # ten-minute re-check the hold just scheduled.
  test "a held restart lands in waiting, not running with no job" do
    session = build_session(SessionGenesis::GITHUB_ISSUE)
    session.update!(status: :running, running_job_id: "job-abc")

    held = SpotGateService.stub(:evaluate, held_decision) do
      SpotSessionHold.hold_if_needed(session)
    end

    assert held
    session.reload
    assert_equal "waiting", session.status,
                 "a held session must sit in the spot queue, not look like an orphaned run"
    assert_nil session.running_job_id, "nothing is monitoring it, so nothing may claim to be"
  end

  test "a priority session's resume is never held" do
    session = build_session(SessionGenesis::WEB_UI)
    session.update!(status: :running)

    SpotGateService.stub(:evaluate, held_decision) do
      refute SpotSessionHold.hold_if_needed(session, follow_up_prompt: "Please continue")
    end

    assert_equal "running", session.reload.status
  end

  # A second delivery arriving during a hold must not race the turn already
  # deferred. Two jobs against one session means AgentSessionJob's concurrency
  # guard drops whichever loses, so the later prompt goes to the durable queue —
  # and the marker the first job would otherwise prefer over its own argument is
  # dropped, so the first prompt is still the first prompt.
  test "a second refused turn is queued behind the one already deferred" do
    session = build_session(SessionGenesis::GITHUB_ISSUE)
    session.update!(status: :running)

    SpotGateService.stub(:evaluate, held_decision) do
      SpotSessionHold.hold_if_needed(session, follow_up_prompt: "First wake")

      session.reload.update!(status: :running)
      session.merge_metadata!("pending_follow_up_prompt" => "Second wake")

      assert_no_enqueued_jobs only: AgentSessionJob do
        SpotSessionHold.hold_if_needed(session.reload, follow_up_prompt: "Second wake")
      end
    end

    session.reload
    assert_equal "waiting", session.status
    assert_equal [ "Second wake" ], session.enqueued_messages.pending.order(:position).pluck(:content)
    refute session.metadata.key?("pending_follow_up_prompt"),
           "the gate has custody of the turn, so the marker must not hijack the deferred job"
    assert_equal 1, session.metadata[SpotSessionHold::HELD_COUNT],
                 "queueing behind a scheduled turn is not another rung on the backoff ladder"
  end

  test "a queued second turn keeps its images and files" do
    session = build_session(SessionGenesis::GITHUB_ISSUE)
    session.update!(status: :running)
    images = [ { "path" => "/tmp/b.png", "media_type" => "image/png" } ]
    files = [ { "path" => "/tmp/b.txt", "original_filename" => "b.txt", "size" => 3 } ]

    SpotGateService.stub(:evaluate, held_decision) do
      SpotSessionHold.hold_if_needed(session, follow_up_prompt: "First wake")
      session.reload.update!(status: :running)
      SpotSessionHold.hold_if_needed(session.reload, follow_up_prompt: "Second wake",
                                    images: images, files: files)
    end

    queued = session.reload.enqueued_messages.pending.order(:position).last
    assert_equal images, queued.images
    assert_equal files, queued.files
  end

  # Promotion is the sanctioned escape valve, and the hold banner's button is what
  # presses it. The re-check job the deferral left behind is what carries the turn
  # through once the session is no longer spot.
  test "promotion to priority releases a deferred resume" do
    session = build_session(SessionGenesis::GITHUB_ISSUE)
    session.update!(status: :running)

    SpotGateService.stub(:evaluate, held_decision) do
      assert SpotSessionHold.hold_if_needed(session, follow_up_prompt: "Please continue")

      session.reload.update!(scheduling_class: SessionGenesis::PRIORITY)
      refute SpotSessionHold.hold_if_needed(session, follow_up_prompt: "Please continue"),
             "promotion must let the turn through even while a window is at its target"
    end
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
      accounts_read: 2, pool_size: 2,
      fleet_burn_usd_per_minute: 0.0, candidate_burn_usd_per_minute: 0.0
    )
  end

  def held_decision
    SpotGateService::Decision.new(
      allowed: false, reason: "at_utilization_limit",
      detail: "Holding spot sessions: the 5-hour window is at 85% of the 80% spot budget, averaged across all 2 accounts.",
      five_hour: nil, weekly: nil, active_sessions: 3, fleet_cap: 10,
      accounts_read: 2, pool_size: 2,
      fleet_burn_usd_per_minute: 0.0, candidate_burn_usd_per_minute: 0.0
    )
  end

  def allowed_decision
    SpotGateService::Decision.new(
      allowed: true, reason: "within_limits",
      detail: "1 of 10 session slots taken, and 5-hour at 12% of its 80% target, averaged across all 2 accounts.",
      five_hour: nil, weekly: nil, active_sessions: 1, fleet_cap: 10,
      accounts_read: 2, pool_size: 2,
      fleet_burn_usd_per_minute: 0.0, candidate_burn_usd_per_minute: 0.0
    )
  end
end
