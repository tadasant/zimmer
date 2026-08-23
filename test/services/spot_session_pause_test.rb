# frozen_string_literal: true

require "test_helper"

# The ceiling half of the spot policy: a target stops the spot sessions that are
# already RUNNING, not just the ones trying to start. These tests pin down the
# two properties that make that safe — priority work is never touched, and a
# paused session is deferred rather than cancelled.
class SpotSessionPauseTest < ActiveSupport::TestCase
  # Not included globally by test_helper — the resume enqueue is the whole point
  # of a deferral, so these tests have to be able to see it.
  include ActiveJob::TestHelper

  setup do
    # Same isolation as SpotGateServiceTest: the gate averages every account's
    # latest snapshot and counts every running session, so a fixture reading or a
    # fixture session in `running` silently changes what these tests assert on.
    ClaudeAccountQuotaSnapshot.delete_all
    ClaudeAccount.update_all(is_current: false)
    Session.where(status: :running).update_all(status: Session.statuses[:needs_input])
    @account = ClaudeAccount.create!(
      email: "ceiling-test@example.com", runtime: "claude_code",
      oauth_config: { "x" => 1 }, is_current: true
    )
    @setting = AppSetting.editable
    @setting.update!(spot_gating_enabled: true,
                     spot_reserve_five_hour_pct: 20,
                     spot_reserve_weekly_pct: 20,
                     spot_max_concurrent_sessions: 10)
  end

  # Both windows are seeded near their rollover on purpose. This suite is about
  # the CEILING — which running sessions get paused and when they come back — and
  # a window early in its cycle would be refused by the pacing curve instead, so
  # every case would read "held" for a reason these tests are not asking about.
  # QuotaCapacityModel and SpotGateServiceTest cover the curve itself.
  def seed(current_5h:, current_7d: 0.10)
    ClaudeAccountQuotaSnapshot.create!(
      claude_account: @account,
      utilization_5h: current_5h, utilization_7d: current_7d,
      reset_5h: 5.minutes.from_now, reset_7d: 1.hour.from_now,
      active_session_count: 1, trigger: "usage_sample"
    )
  end

  def running_session(genesis: SessionGenesis::GITHUB_ISSUE, runtime: "claude_code", metadata: {})
    Session.create!(git_root: "https://github.com/t/r.git", prompt: "work", genesis: genesis,
                    status: :running, agent_runtime: runtime, session_id: "cli-#{SecureRandom.hex(4)}",
                    metadata: metadata)
  end

  def paused_session(paused_at: 1.hour.ago, genesis: SessionGenesis::GITHUB_ISSUE)
    Session.create!(
      git_root: "https://github.com/t/r.git", prompt: "work", genesis: genesis,
      status: :waiting, session_id: "cli-#{SecureRandom.hex(4)}",
      metadata: {
        SpotSessionPause::PAUSED_AT => paused_at.utc.iso8601,
        SpotSessionPause::PAUSED_REASON => "at_utilization_limit",
        SpotSessionPause::PAUSED_DETAIL => "Holding spot sessions: 5-hour window at 89% of its 80% target.",
        SpotSessionPause::PAUSED_COUNT => 1,
        "paused_by" => SpotSessionPause::PAUSED_BY
      }
    )
  end

  # --- pausing -----------------------------------------------------------------

  test "a running spot session is paused when a window reaches its target" do
    seed(current_5h: 0.89)
    session = running_session

    result = SpotSessionPause.sweep!

    assert_equal 1, result.paused
    session.reload
    assert session.waiting?, "a quota pause must go dormant, not sit in the homepage action queue"
    assert_equal "at_utilization_limit", session.metadata[SpotSessionPause::PAUSED_REASON]
    assert_equal SpotSessionPause::PAUSED_BY, session.metadata["paused_by"]
    assert_equal 1, session.metadata[SpotSessionPause::PAUSED_COUNT]
    assert session.metadata[SpotSessionPause::PAUSED_DETAIL].include?("80% spot budget"),
      "the gate's own sentence is what tells a reader why the turn stopped"
    assert session.logs.where(level: "warning").any? { |log| log.content.include?("paused mid-run") }
  end

  test "a running priority session is never paused" do
    seed(current_5h: 0.99)
    session = running_session(genesis: SessionGenesis::WEB_UI)

    assert_equal 0, SpotSessionPause.sweep!.paused
    assert session.reload.running?
  end

  # The batch is selected once and then walked, spending SIGTERM grace on each
  # session in turn — long enough for somebody to press "Make this session
  # priority" on one still queued behind the others. The class is therefore
  # re-read under the row lock, not just when the batch was chosen.
  test "a session promoted after the batch was selected is not paused" do
    seed(current_5h: 0.89)
    session = running_session
    session.update!(scheduling_class: SessionGenesis::PRIORITY)

    # Stands in for the stale batch: the relation still names a session that no
    # longer classifies spot.
    SpotSessionPause.stub(:pausable_sessions, Session.where(id: session.id)) do
      assert_equal 0, SpotSessionPause.sweep!.paused
    end

    assert session.reload.running?
  end

  test "a session on another runtime is not paused by a Claude Code window" do
    seed(current_5h: 0.99)
    session = running_session(runtime: "codex")

    assert_equal 0, SpotSessionPause.sweep!.paused
    assert session.reload.running?
  end

  test "a status summary fork is not paused" do
    seed(current_5h: 0.99)
    session = running_session(metadata: { SessionStatusSummaryGenerator::FORK_MARKER => 123 })

    assert_equal 0, SpotSessionPause.sweep!.paused
    assert session.reload.running?
  end

  test "nothing is paused while the pool is under both targets" do
    seed(current_5h: 0.50)
    session = running_session

    assert_equal 0, SpotSessionPause.sweep!.paused
    assert session.reload.running?
  end

  # A full fleet holds new spot sessions, but pausing a running one to free its
  # own slot would be work for nothing — the slot is only wanted by another spot
  # session, which the same cap would then hold.
  test "a fleet-cap hold pauses nobody" do
    seed(current_5h: 0.50)
    @setting.update!(spot_max_concurrent_sessions: 1)
    session = running_session

    decision = SpotGateService.evaluate
    assert decision.held?
    assert_equal "fleet_at_cap", decision.reason
    assert_equal 0, SpotSessionPause.sweep!.paused
    assert session.reload.running?
  end

  test "the process is terminated before the session is flipped" do
    seed(current_5h: 0.89)
    session = running_session(metadata: { "process_pid" => 4242 })

    manager = FakeLifecycleManager.new

    ProcessLifecycleManager.stub(:new, manager) do
      assert_equal 1, SpotSessionPause.sweep!.paused
    end

    assert_equal 4242, manager.monitored_pid
    assert_equal :spot_ceiling, manager.terminated_reason
    assert manager.terminated_before_flip, "flipping the status first costs the session its final transcript poll"
    assert session.reload.waiting?
  end

  # --- resuming ----------------------------------------------------------------

  test "a paused session resumes once utilization clears the resume margin" do
    seed(current_5h: 0.70)
    session = paused_session

    result = nil
    assert_enqueued_with(job: AgentSessionJob) do
      result = SpotSessionPause.sweep!
    end

    assert_equal 1, result.resumed
    session.reload
    assert session.running?
    assert_nil session.metadata[SpotSessionPause::PAUSED_REASON], "the pause record goes with the pause"
    assert_nil session.metadata["paused_by"]
    assert session.logs.any? { |log| log.content.include?("The window has room again") }
  end

  # The hysteresis. Admission resumes at the target; a session that was
  # interrupted mid-turn waits for real headroom, or it goes straight back over
  # and the next sweep pauses it again.
  test "a paused session stays asleep inside the resume margin" do
    seed(current_5h: 0.78)
    session = paused_session

    assert SpotGateService.evaluate.allowed?, "a session STARTING now would be admitted at 78%"

    result = SpotSessionPause.sweep!

    assert_equal 0, result.resumed
    assert_equal 1, result.held
    assert session.reload.waiting?
  end

  test "resuming never overshoots the fleet cap" do
    seed(current_5h: 0.70)
    @setting.update!(spot_max_concurrent_sessions: 2)
    running_session(genesis: SessionGenesis::WEB_UI)
    3.times { |i| paused_session(paused_at: (10 - i).hours.ago) }

    result = SpotSessionPause.sweep!

    assert_equal 1, result.resumed, "one running session against a cap of 2 leaves one slot"
    assert_equal 2, result.held
  end

  test "a sweep resumes at most MAX_RESUMES_PER_SWEEP sessions" do
    seed(current_5h: 0.70)
    @setting.update!(spot_max_concurrent_sessions: 50)
    (SpotSessionPause::MAX_RESUMES_PER_SWEEP + 2).times { |i| paused_session(paused_at: (30 - i).hours.ago) }

    result = SpotSessionPause.sweep!

    assert_equal SpotSessionPause::MAX_RESUMES_PER_SWEEP, result.resumed
    assert_equal 2, result.held
  end

  # --- the queue a human can join on purpose ------------------------------------

  def queued_session(prompt: nil, paused_at: 1.hour.ago, precedence: 0)
    session = Session.create!(
      git_root: "https://github.com/t/r.git", prompt: "work", genesis: SessionGenesis::WEB_UI,
      status: :needs_input, session_id: "cli-#{SecureRandom.hex(4)}", precedence: precedence
    )
    Sessions::PauseIntoSpotQueue.call(session: session, prompt: prompt)
    session.reload.update_columns(
      metadata: session.metadata.merge(SpotSessionPause::PAUSED_AT => paused_at.utc.iso8601)
    )
    session.reload
  end

  # The failure this feature could plausibly ship with is "parked forever with
  # nothing to wake it". This is the end-to-end refutation: a session a human put
  # in the queue from "Pause Until" is picked up by the same sweep that resumes a
  # ceiling pause, with no trigger anywhere in the picture.
  test "a session parked in the queue from Pause Until is resumed by the sweep" do
    seed(current_5h: 0.10)
    session = queued_session

    assert_not session.awaiting_scheduled_wake?, "nothing is armed — the sweep is the only way back"

    result = SpotSessionPause.sweep!

    assert_equal 1, result.resumed
    session.reload
    assert session.running?
    assert_nil session.metadata[SpotSessionPause::PAUSED_REASON], "the queue record goes with the resume"
    assert_equal 1, enqueued_jobs.count { |job| job[:job] == AgentSessionJob }
  end

  test "the queue holds a parked session while a window is at its target" do
    seed(current_5h: 0.95)
    session = queued_session

    result = SpotSessionPause.sweep!

    assert_equal 0, result.resumed
    assert_equal 1, result.held
    assert session.reload.waiting?
  end

  test "a resumed queue session comes back on the prompt its human left" do
    seed(current_5h: 0.10)
    session = queued_session(prompt: "Re-check the deploy")

    assert_enqueued_with(job: AgentSessionJob, args: [ session.id, "Re-check the deploy" ]) do
      SpotSessionPause.sweep!
    end
  end

  test "a resumed queue session with no prompt is told why it is awake" do
    seed(current_5h: 0.10)
    session = queued_session

    SpotSessionPause.sweep!

    job = enqueued_jobs.find { |j| j[:job] == AgentSessionJob.name || j[:job] == AgentSessionJob }
    prompt = job[:args][1]
    assert AutomatedPrompts.system_recovery?(prompt)
    assert_match(/spot queue/, prompt)
    assert_equal session.id, job[:args][0]
  end

  # The panel promises "sleeps when this turn ends". A ceiling sweep landing in
  # that window would terminate the turn instead, and rewrite the session's story
  # as a casualty of the ceiling.
  test "the ceiling leaves a running session already on its way to the queue alone" do
    seed(current_5h: 0.95)
    session = running_session
    Sessions::PauseIntoSpotQueue.call(session: session)

    result = SpotSessionPause.sweep!

    assert_equal 0, result.paused
    session.reload
    assert session.running?, "its own turn end is what parks it, not a SIGTERM"
    assert_equal SpotSessionPause::QUEUED_REASON, session.metadata[SpotSessionPause::PAUSED_REASON]
  end

  # The wording branches now, so the ceiling's own story has to be pinned too.
  test "a ceiling-paused session is still told the window has room again" do
    seed(current_5h: 0.10)
    session = paused_session

    SpotSessionPause.sweep!

    job = enqueued_jobs.find { |j| j[:job] == AgentSessionJob }
    assert_match(/spent the part of itself that spot work may use, and it has room again/, job[:args][1])
    assert_equal session.id, job[:args][0]
    assert session.reload.logs.any? { |log| log.content.include?("The window has room again") }
  end

  # The count /quotas and get_spot_policy report is about what the CEILING cost,
  # so a session nobody interrupted must not inflate it.
  test "a queued session is not counted as paused by the ceiling" do
    seed(current_5h: 0.95)
    queued_session
    paused_session

    assert_equal 1, SpotSessionPause.paused_count
  end

  # Precedence is what the rest of the queue is ordered by, so the batch has to
  # spend itself on the session that matters most rather than the oldest sleeper.
  test "the highest precedence in the queue is resumed first" do
    seed(current_5h: 0.70)
    @setting.update!(spot_max_concurrent_sessions: 1)
    older_but_lower = paused_session(paused_at: 9.hours.ago)
    ranked = queued_session(paused_at: 1.minute.ago, precedence: 500)

    SpotSessionPause.sweep!

    assert ranked.reload.running?, "precedence 500 goes before an unranked sleeper"
    assert older_but_lower.reload.waiting?
  end

  # The budget is smaller than the population this usually holds, so the order
  # decides which spot work gets the recovered headroom — the same question the
  # ranked queue answers.
  test "the highest precedence is resumed first" do
    seed(current_5h: 0.70)
    # One free slot, two sleepers: the batch has room for exactly one, which is
    # what makes the ordering observable.
    @setting.update!(spot_max_concurrent_sessions: 1)
    ranked = paused_session(paused_at: 1.minute.ago)
    ranked.update!(precedence: 900)
    older_but_lower = paused_session(paused_at: 9.hours.ago)

    SpotSessionPause.sweep!

    assert ranked.reload.running?, "the operator's ordering decides, not how long a session has been asleep"
    assert older_but_lower.reload.waiting?
  end

  test "the oldest pause is resumed first within a tie" do
    seed(current_5h: 0.70)
    @setting.update!(spot_max_concurrent_sessions: 1)
    newest = paused_session(paused_at: 1.minute.ago)
    oldest = paused_session(paused_at: 9.hours.ago)

    SpotSessionPause.sweep!

    assert oldest.reload.running?, "equal-ranked sessions still take turns"
    assert newest.reload.waiting?
  end

  # The escape hatch the pause banner offers: promotion is not gated on quota, so
  # it must not wait for the window it was paused on.
  test "a paused session made priority resumes even while a window is at its target" do
    seed(current_5h: 0.95)
    session = paused_session
    session.update!(scheduling_class: SessionGenesis::PRIORITY)

    result = SpotSessionPause.sweep!

    assert_equal 1, result.resumed
    assert session.reload.running?
  end

  # The same button, pressed at the moment it matters most: while the ceiling is
  # actively pausing everything else. A sweep that only resumed on its "gate is
  # open" branch would leave this session asleep for hours.
  test "a sweep that pauses running sessions still resumes one promoted to priority" do
    seed(current_5h: 0.95)
    running = running_session
    promoted = paused_session
    promoted.update!(scheduling_class: SessionGenesis::PRIORITY)

    result = SpotSessionPause.sweep!

    assert_equal 1, result.paused
    assert_equal 1, result.resumed
    assert running.reload.waiting?, "the running spot session is paused by the same sweep"
    assert promoted.reload.running?
  end

  # The two halves of the policy have to agree. The sweep resumes a paused session
  # by enqueueing a recovery PROMPT, and the admission gate now refuses prompts —
  # so a resume decided at 70% must still survive the gate the job re-reads a
  # moment later, or the ceiling could never put anything back.
  #
  # It does because the margin makes resumption the STRICTER test: RESUME_MARGIN_PCT
  # is subtracted from both targets, so anything the resume decision allows the
  # admission decision allows too.
  test "a session the ceiling resumes is not then held by the admission gate" do
    seed(current_5h: 0.70)
    session = paused_session

    assert_equal 1, SpotSessionPause.sweep!.resumed
    assert session.reload.running?

    refute SpotSessionHold.hold_if_needed(
      session,
      follow_up_prompt: AutomatedPrompts.system_recovery(reason: "the ceiling resumed it")
    ), "the gate must not undo the resume the ceiling just decided on"
    assert session.reload.running?
  end

  # A stand-in for the real manager, which would go looking for a live process.
  # Records the order the two calls arrived in, because the ORDER is the property
  # under test: SessionsController#pause kills the process before flipping the
  # status so AgentSessionJob sees the exit and polls the transcript one last
  # time, and this path has to do the same.
  class FakeLifecycleManager
    attr_reader :monitored_pid, :terminated_reason, :terminated_before_flip

    def resume_monitoring(pid:, stderr_log_path: nil)
      @monitored_pid = pid
      ProcessLifecycleManager::SpawnResult.new(success: true, pid: pid, stderr_log_path: stderr_log_path)
    end

    def terminate(reason:)
      @terminated_reason = reason
      @terminated_before_flip = Session.where(status: :running).exists?
      ProcessLifecycleManager::TerminateResult.new(success: true, reason: reason)
    end
  end

  test "a sweep that blows up neither raises nor touches a session" do
    seed(current_5h: 0.89)
    session = running_session

    SpotGateService.stub(:fleet_decision, ->(*) { raise ActiveRecord::ConnectionNotEstablished }) do
      result = SpotSessionPause.sweep!
      assert_equal 0, result.paused
    end

    assert session.reload.running?
  end
end
