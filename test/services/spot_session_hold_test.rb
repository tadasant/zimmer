# frozen_string_literal: true

require "test_helper"

# The hold is a DEFERRAL, not a refusal. These tests exist mostly to pin that
# down: nothing here may ever start failing a session or dropping its work.
class SpotSessionHoldTest < ActiveSupport::TestCase
  # Not included globally by test_helper — the retry enqueue is the whole point of
  # a deferral, so this test has to be able to see it.
  include ActiveJob::TestHelper
  # A re-armed resume confirms an attachment's bytes are still on the volume
  # before it replays the descriptor, so the end-to-end case needs a real one.
  include AttachmentFixtures

  setup do
    # Same isolation as SpotGateServiceTest: the gate reads the serving account's
    # latest snapshot and counts every running session.
    ClaudeAccountQuotaSnapshot.delete_all
    ClaudeAccount.update_all(is_current: false)
    Session.where(status: :running).update_all(status: Session.statuses[:needs_input])
    @setting = AppSetting.editable
    @setting.update!(spot_gating_enabled: false)
  end

  teardown { cleanup_stored_attachments! }

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

  # The third carrier of one turn's attachments. `queue_behind_scheduled_turn`
  # writes into a jsonb column that EnqueuedMessageProcessorService reads back
  # and hands to AgentSessionJob, so it has to be the same round trip as the
  # hold record — the record and the queue must not disagree about the shape.
  test "a turn queued behind a deferred one carries its attachments in the record shape" do
    session = build_session(SessionGenesis::GITHUB_ISSUE)
    session.update!(status: :running)

    SpotGateService.stub(:evaluate, held_decision) do
      SpotSessionHold.hold_if_needed(session, follow_up_prompt: "First wake")

      session.reload.update!(status: :running)
      SpotSessionHold.hold_if_needed(
        session.reload, follow_up_prompt: "Second wake",
        images: [ { path: "/data/1/second.png", media_type: "image/png" } ],
        files: [ { path: "/data/1/second.txt", original_filename: "second.txt", size: 4 } ]
      )
    end

    queued = session.reload.enqueued_messages.pending.order(:position).last
    assert_equal [ { "path" => "/data/1/second.png", "media_type" => "image/png" } ], queued.images
    assert_equal [ { "path" => "/data/1/second.txt", "original_filename" => "second.txt", "size" => 4 } ],
      queued.files
  end

  # The record has to survive the LADDER, not just one hold. A re-check that the
  # gate refuses again arrives back here carrying the turn as job arguments, and
  # re-records it — otherwise the durable copy would only ever be as good as the
  # first rung.
  test "a second hold of the same turn re-records its attachments" do
    session = build_session(SessionGenesis::GITHUB_ISSUE)
    session.update!(status: :running)
    turn = {
      follow_up_prompt: "here is the screenshot, fix this",
      images: [ { path: "/data/1/shot.png", media_type: "image/png" } ]
    }

    SpotGateService.stub(:evaluate, held_decision) do
      assert SpotSessionHold.hold_if_needed(session, **turn)
      # The re-check fires, the gate refuses again, and the turn comes back
      # through this door as the deferred job's arguments.
      session.reload.merge_metadata!(SpotSessionHold::HELD_RETRY_AT => 1.minute.ago.utc.iso8601)
      assert SpotSessionHold.hold_if_needed(session.reload, **turn)
    end

    metadata = session.reload.metadata
    assert_equal 2, metadata[SpotSessionHold::HELD_COUNT]
    assert_equal [ { "path" => "/data/1/shot.png", "media_type" => "image/png" } ],
      metadata[SpotSessionHold::HELD_IMAGES]
  end

  # Normalized at the door, so what rides the JOB is the same shape as what goes
  # on the record. Two copies of one turn built from different values is how they
  # come to disagree — and a string-keyed descriptor reads as empty to the
  # adapters, which index `image[:path]`.
  test "a deferred resume's job carries the same normalized descriptors as its record" do
    session = build_session(SessionGenesis::GITHUB_ISSUE)
    session.update!(status: :running)

    SpotGateService.stub(:evaluate, held_decision) do
      assert_enqueued_with(job: AgentSessionJob) do
        assert SpotSessionHold.hold_if_needed(
          session, follow_up_prompt: "look at this",
          images: [ { "path" => "/data/1/shot.png", "media_type" => "image/png",
                      "unknown" => "dropped" } ]
        )
      end
    end

    job = enqueued_jobs.find { |j| j["job_class"] == "AgentSessionJob" }
    args = ActiveJob::Arguments.deserialize(job["arguments"])
    assert_equal [ { path: "/data/1/shot.png", media_type: "image/png" } ], args.dig(2, :images)
    assert_equal [ { "path" => "/data/1/shot.png", "media_type" => "image/png" } ],
      session.reload.metadata[SpotSessionHold::HELD_IMAGES]
  end

  # Production session 8810, 2026-08-31. The spot-hold sweep re-armed a stalled
  # hold with its own recovery nudge, the gate refused that turn too, and the
  # nudge landed here — in the durable queue, stamped `caller`, indistinguishable
  # from a message a human had sent. The fork was then archived by the cleanup
  # that owns it and Zimmer paged about losing a message it had written itself.
  # This method is the only place a refused prompt becomes a durable row, so it
  # is the only place that can name what it is writing.
  test "a queued recovery nudge is stamped as Zimmer's own, not as a caller's" do
    session = build_session(SessionGenesis::GITHUB_ISSUE)
    session.update!(status: :running)
    nudge = AutomatedPrompts.system_recovery(
      reason: "Zimmer's spot-hold sweep found this session's re-check had stopped firing"
    )

    SpotGateService.stub(:evaluate, held_decision) do
      SpotSessionHold.hold_if_needed(session, follow_up_prompt: "First wake")
      session.reload.update!(status: :running)
      SpotSessionHold.hold_if_needed(session.reload, follow_up_prompt: nudge)
    end

    queued = session.reload.enqueued_messages.pending.order(:position).last
    assert_equal nudge, queued.content
    assert_equal "automated_recovery_nudge", queued.origin
    assert queued.self_addressed?
  end

  # A conflict notice that reached a spot-class session parked in `needs_input`
  # was SENT rather than queued, and lands back in the queue here when the gate
  # refuses the turn carrying it — where it can wait hours at the quota wall
  # rather than the minutes a turn boundary takes. That makes it the longest-gap
  # version of the staleness the delivery-time re-read exists to catch, so it
  # has to carry the origin that re-read keys on (tadasant/zimmer#835).
  test "a queued merge-conflict notice keeps the origin the delivery-time re-read keys on" do
    session = build_session(SessionGenesis::GITHUB_ISSUE)
    session.update!(status: :running)
    notice = AutomatedPrompts.merge_conflict_message("https://github.com/tadasant/zimmer/pull/834")

    SpotGateService.stub(:evaluate, held_decision) do
      SpotSessionHold.hold_if_needed(session, follow_up_prompt: "First wake")
      session.reload.update!(status: :running)
      SpotSessionHold.hold_if_needed(session.reload, follow_up_prompt: notice)
    end

    queued = session.reload.enqueued_messages.pending.order(:position).last
    assert_equal notice, queued.content
    assert_equal "automated_merge_conflict", queued.origin
    assert_includes EnqueuedMessage::STALENESS_CHECKED_ORIGINS, queued.origin
  end

  # The funnel sees a human's follow-up and Zimmer's nudge as the same opaque
  # string, so the stamp has to discriminate rather than blanket-exempt: `caller`
  # is the default and the wider bucket, and a message somebody is waiting on
  # must keep it.
  test "a queued caller prompt stays a caller's message" do
    session = build_session(SessionGenesis::GITHUB_ISSUE)
    session.update!(status: :running)

    SpotGateService.stub(:evaluate, held_decision) do
      SpotSessionHold.hold_if_needed(session, follow_up_prompt: "First wake")
      session.reload.update!(status: :running)
      SpotSessionHold.hold_if_needed(session.reload, follow_up_prompt: "add the onion back")
    end

    queued = session.reload.enqueued_messages.pending.order(:position).last
    assert_equal "caller", queued.origin
    refute queued.self_addressed?
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
      five_hour: nil, weekly: nil, active_sessions: 10, queued_sessions: 0, fleet_cap: 10,
      accounts_read: 2, pool_size: 2,
      fleet_burn_usd_per_minute: 0.0, candidate_burn_usd_per_minute: 0.0,
      pool_capacity: nil
    )
  end

  # The turn is DEFERRED, never dropped — and until the prompt was recorded on the
  # SESSION the only copy of it was the delayed job's argument list. A worker
  # killed between the hold record committing and the enqueue below therefore
  # lost the turn outright, which is exactly what stranded session 7507
  # (tadasant/zimmer#648). The row is the durable copy.
  test "a deferred resume records its prompt on the session, and clearing drops it" do
    session = build_session(SessionGenesis::GITHUB_ISSUE)
    session.update!(status: :running)

    SpotGateService.stub(:evaluate, held_decision) do
      assert SpotSessionHold.hold_if_needed(session, follow_up_prompt: "please continue")
    end

    session.reload
    assert_equal "please continue", session.metadata[SpotSessionHold::HELD_PROMPT]

    SpotSessionHold.clear(session)
    assert_nil session.reload.metadata[SpotSessionHold::HELD_PROMPT]
  end

  # #overdue_sessions compares `spot_hold_retry_at` as a STRING in SQL, and
  # #held_sessions orders on `spot_hold_at` the same way. Both are only correct
  # while the stamps are UTC ISO-8601 — an offset rendering ("+02:00") sorts into
  # the wrong place and a stalled ladder goes unfound.
  test "hold stamps are written in UTC so they sort lexicographically" do
    session = build_session(SessionGenesis::GITHUB_ISSUE)

    Time.use_zone("America/New_York") do
      SpotGateService.stub(:evaluate, held_decision) do
        assert SpotSessionHold.hold_if_needed(session)
      end
    end

    metadata = session.reload.metadata
    assert_match(/Z\z/, metadata[SpotSessionHold::HELD_AT])
    assert_match(/Z\z/, metadata[SpotSessionHold::HELD_RETRY_AT])
  end

  test "a hold at the starting line records no prompt" do
    session = build_session(SessionGenesis::GITHUB_ISSUE)

    SpotGateService.stub(:evaluate, held_decision) do
      assert SpotSessionHold.hold_if_needed(session)
    end

    assert_nil session.reload.metadata[SpotSessionHold::HELD_PROMPT]
  end

  # The same argument, for what came WITH the prompt. `hold!` is handed the
  # turn's attachments and puts them on the delayed job, and AgentSessionJob
  # reads attachments from nowhere else — so the job dying took the screenshot
  # with it exactly as surely as it took the prompt (#890).
  test "a deferred resume records its attachments on the session too" do
    session = build_session(SessionGenesis::GITHUB_ISSUE)
    session.update!(status: :running)

    SpotGateService.stub(:evaluate, held_decision) do
      assert SpotSessionHold.hold_if_needed(
        session,
        follow_up_prompt: "here is the screenshot, fix this",
        images: [ { path: "/data/1/shot.png", media_type: "image/png" } ],
        files: [ { path: "/data/1/notes.txt", original_filename: "notes.txt", size: 7 } ]
      )
    end

    metadata = session.reload.metadata
    # String keys, because that is what comes back out of jsonb — pinned here so
    # the replay's conversion is tested against the real stored shape.
    assert_equal [ { "path" => "/data/1/shot.png", "media_type" => "image/png" } ],
      metadata[SpotSessionHold::HELD_IMAGES]
    assert_equal [ { "path" => "/data/1/notes.txt", "original_filename" => "notes.txt", "size" => 7 } ],
      metadata[SpotSessionHold::HELD_FILES]

    SpotSessionHold.clear(session)
    metadata = session.reload.metadata
    assert_nil metadata[SpotSessionHold::HELD_IMAGES]
    assert_nil metadata[SpotSessionHold::HELD_FILES]
  end

  test "a deferred resume with no attachments records none" do
    session = build_session(SessionGenesis::GITHUB_ISSUE)
    session.update!(status: :running)

    SpotGateService.stub(:evaluate, held_decision) do
      assert SpotSessionHold.hold_if_needed(session, follow_up_prompt: "please continue")
    end

    metadata = session.reload.metadata
    assert_nil metadata[SpotSessionHold::HELD_IMAGES]
    assert_nil metadata[SpotSessionHold::HELD_FILES]
  end

  # The three HELD_TURN_KEYS are ONE turn. A hold that carries no attachment has
  # to drop an earlier hold's rather than leave it beside a prompt it never
  # belonged to — replaying the wrong attachment is worse than replaying none.
  test "a later hold does not inherit an earlier turn's attachments" do
    session = build_session(SessionGenesis::GITHUB_ISSUE)
    session.update!(status: :running)
    session.merge_metadata!(
      SpotSessionHold::HELD_IMAGES => [ { "path" => "/data/1/old.png", "media_type" => "image/png" } ],
      SpotSessionHold::HELD_FILES => [ { "path" => "/data/1/old.txt", "original_filename" => "old.txt" } ]
    )

    SpotGateService.stub(:evaluate, held_decision) do
      assert SpotSessionHold.hold_if_needed(session, follow_up_prompt: "a different turn")
    end

    metadata = session.reload.metadata
    assert_equal "a different turn", metadata[SpotSessionHold::HELD_PROMPT]
    assert_nil metadata[SpotSessionHold::HELD_IMAGES]
    assert_nil metadata[SpotSessionHold::HELD_FILES]
  end

  test "a hold at the starting line drops any recorded turn" do
    session = build_session(SessionGenesis::GITHUB_ISSUE)
    session.merge_metadata!(
      SpotSessionHold::HELD_PROMPT => "an earlier resume",
      SpotSessionHold::HELD_IMAGES => [ { "path" => "/data/1/old.png", "media_type" => "image/png" } ]
    )

    SpotGateService.stub(:evaluate, held_decision) do
      assert SpotSessionHold.hold_if_needed(session)
    end

    metadata = session.reload.metadata
    assert_nil metadata[SpotSessionHold::HELD_PROMPT]
    assert_nil metadata[SpotSessionHold::HELD_IMAGES]
  end

  # The whole defect, end to end and through the real doors: a resume carrying an
  # attachment is held, the delayed job that was its only carrier is lost, and
  # the sweep re-arms it. Before #890 the re-armed turn arrived with the prompt
  # and without the screenshot, and nothing anywhere said so.
  test "a held resume whose job is lost is re-armed with the attachments it came with" do
    session = build_session(SessionGenesis::GITHUB_ISSUE)
    session.update!(status: :running)
    image = store_image_for(session)
    file = store_file_for(session, filename: "notes.txt", content: "read me")

    SpotGateService.stub(:evaluate, held_decision) do
      assert SpotSessionHold.hold_if_needed(
        session,
        follow_up_prompt: "here is the screenshot, fix this",
        images: [ { path: image[:path], media_type: "image/png" } ],
        files: [ { path: file[:path], original_filename: "notes.txt", size: 7 } ]
      )
    end

    # The worker died between the hold record committing and the enqueue: the
    # record is on the row, the job is gone, and the re-check time has passed.
    clear_enqueued_jobs
    GoodJob::Job.delete_all
    session.merge_metadata!(SpotSessionHold::HELD_RETRY_AT => 11.hours.ago.utc.iso8601)

    assert_equal 1, SpotSessionHold.sweep!.rearmed

    rearmed = enqueued_jobs.select { |job| job["job_class"] == "AgentSessionJob" }
    assert_equal 1, rearmed.length
    args = ActiveJob::Arguments.deserialize(rearmed.first["arguments"])
    assert_equal [ session.id, "here is the screenshot, fix this" ], args.first(2)
    assert_equal [ { path: image[:path], media_type: "image/png" } ], args.dig(2, :images)
    assert_equal [ { path: file[:path], original_filename: "notes.txt", size: 7 } ],
      args.dig(2, :files)
    assert_match(/carried with it, carrying 1 image and 1 file\./,
      session.logs.order(:id).last.content)
  end

  def held_decision
    SpotGateService::Decision.new(
      allowed: false, reason: "at_utilization_limit",
      detail: "Holding spot sessions: the 5-hour window is at 85% of the 80% spot budget, averaged across all 2 accounts.",
      five_hour: nil, weekly: nil, active_sessions: 3, queued_sessions: 0, fleet_cap: 10,
      accounts_read: 2, pool_size: 2,
      fleet_burn_usd_per_minute: 0.0, candidate_burn_usd_per_minute: 0.0,
      pool_capacity: nil
    )
  end

  def allowed_decision
    SpotGateService::Decision.new(
      allowed: true, reason: "within_limits",
      detail: "1 of 10 session slots taken, and 5-hour at 12% of its 80% target, averaged across all 2 accounts.",
      five_hour: nil, weekly: nil, active_sessions: 1, queued_sessions: 0, fleet_cap: 10,
      accounts_read: 2, pool_size: 2,
      fleet_burn_usd_per_minute: 0.0, candidate_burn_usd_per_minute: 0.0,
      pool_capacity: nil
    )
  end
end
