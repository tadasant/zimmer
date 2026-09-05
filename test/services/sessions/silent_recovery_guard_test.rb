require "test_helper"
require "mocha/minitest"

# The loop zimmer#988 reports, reproduced as a sequence rather than as a state:
# recovery restarts the session, the restart stamps a fresh `job_started_at` and
# writes nothing, and fifteen minutes later the sweep reaches the same verdict. The
# tests below drive that sequence, and the two that matter most are the ones asserting
# it does NOT fire — a session that is merely slow, and one the platform denied
# compute, must never be failed by this.
class Sessions::SilentRecoveryGuardTest < ActiveJob::TestCase
  BUDGET = RetryBudget::SILENT_RECOVERY

  setup do
    @session = Session.create!(
      prompt: "Ship the thing",
      agent_runtime: "claude_code",
      status: :running,
      git_root: "https://github.com/test/repo.git",
      branch: "main",
      execution_provider: "local_filesystem",
      session_id: SecureRandom.uuid,
      metadata: { "job_started_at" => "2026-09-05T11:23:16Z" }
    )
  end

  def guard(source: "orphan cleanup")
    Sessions::SilentRecoveryGuard.call(@session, source: source)
  end

  # One turn of the production loop: recovery restarts the session, the job starts and
  # produces nothing at all.
  def silent_restart!(at:)
    @session.reload
    @session.merge_metadata!("job_started_at" => at)
  end

  # The same turn, except the runtime writes. `transcript` is what
  # TranscriptPollerService writes and Session#transcript_line_count counts; unlike
  # `last_timeline_entry_at` no state transition can move it.
  def productive_restart!(at:, lines: 3)
    @session.reload
    @session.merge_metadata!("job_started_at" => at)
    @session.update!(transcript: Array.new(lines) { { "type" => "assistant" }.to_json }.join("\n"))
  end

  test "the first recovery restart is never judged - there is nothing to judge it against" do
    result = guard

    assert result.proceed?
    @session.reload
    assert_nil @session.metadata[BUDGET.key], "no attempt may be spent before a restart has been observed"
    assert_equal "2026-09-05T11:23:16Z",
      @session.metadata[Sessions::SilentRecoveryGuard::WATERMARK_KEY]["job_started_at"]
  end

  test "a restart that started a turn and wrote nothing spends one attempt" do
    assert guard.proceed?

    silent_restart!(at: "2026-09-05T11:56:47Z")
    result = guard

    assert result.proceed?, "one silent restart is not enough to give up on a session"
    @session.reload
    assert_equal 1, @session.metadata[BUDGET.key]
    assert_equal "2026-09-05T11:56:47Z",
      @session.metadata[Sessions::SilentRecoveryGuard::WATERMARK_KEY]["job_started_at"],
      "the watermark must advance, or the next restart is judged against a stale baseline"
  end

  # THE DEFECT. Before this guard, this sequence ran forever with the session
  # reporting `running` the whole way.
  test "the fourth silent restart fails the session instead of restarting it again" do
    assert guard.proceed?

    BUDGET.max.times do |i|
      silent_restart!(at: "2026-09-05T1#{i}:00:00Z")
      assert guard.proceed?, "restart #{i + 1} of #{BUDGET.max} must still be allowed"
    end

    silent_restart!(at: "2026-09-05T15:21:28Z")
    result = guard

    assert result.gave_up?, "a session whose restarts all produce nothing must stop being restarted"
    @session.reload
    assert_equal "failed", @session.status,
      "reporting `running` for a session nothing can restart is the bug (#988)"
    assert_equal Sessions::SilentRecoveryGuard::FAILURE_REASON, @session.metadata["failure_reason"]
    assert_nil @session.running_job_id
  end

  test "giving up drops paused_by so the sweeps that select on it stop re-queueing the session" do
    @session.merge_metadata!("paused_by" => "recovery", BUDGET.key => BUDGET.max)
    silent_restart!(at: "2026-09-05T12:00:00Z")
    @session.merge_metadata!(
      Sessions::SilentRecoveryGuard::WATERMARK_KEY => {
        "job_started_at" => "2026-09-05T11:00:00Z", "transcript_lines" => 0
      }
    )

    assert guard.gave_up?

    @session.reload
    assert_nil @session.metadata["paused_by"],
      "CleanupOrphanedSessionsJob selects paused_by = 'recovery' on failed sessions too — " \
      "leaving it behind hands the session straight back to the loop"
  end

  test "the failure names the loop rather than restating the symptom" do
    @session.merge_metadata!(BUDGET.key => BUDGET.max)
    silent_restart!(at: "2026-09-05T12:00:00Z")
    @session.merge_metadata!(
      Sessions::SilentRecoveryGuard::WATERMARK_KEY => {
        "job_started_at" => "2026-09-05T11:00:00Z", "transcript_lines" => 0
      }
    )

    assert guard.gave_up?

    summary = @session.reload.failure_summary
    assert_includes summary, "#{BUDGET.max} times"
    assert_includes summary, "restart it to try again"
  end

  # ---- The false-positive direction -------------------------------------------------

  test "a restart that produced transcript output hands the whole budget back" do
    assert guard.proceed?
    silent_restart!(at: "2026-09-05T11:56:47Z")
    assert guard.proceed?
    assert_equal 1, @session.reload.metadata[BUDGET.key]

    productive_restart!(at: "2026-09-05T12:20:00Z")
    result = guard

    assert result.proceed?
    @session.reload
    assert_nil @session.metadata[BUDGET.key], "output since the last restart ends the incident"
    assert_nil @session.metadata[BUDGET.stamp]
  end

  # The safety property the whole design turns on: reaching the cap is not what fails a
  # session. A session sitting at max that then produces output is read as recovered,
  # and starts from zero.
  test "a spent budget never fails a session that is producing output again" do
    @session.merge_metadata!(
      BUDGET.key => BUDGET.max,
      Sessions::SilentRecoveryGuard::WATERMARK_KEY => {
        "job_started_at" => "2026-09-05T11:00:00Z", "transcript_lines" => 0
      }
    )

    productive_restart!(at: "2026-09-05T12:00:00Z")
    result = guard

    assert result.proceed?, "a session that is working again must never be failed by a stale counter"
    assert_equal "running", @session.reload.status
    assert_nil @session.reload.metadata[BUDGET.key]
  end

  # A long tool call, a compaction, a subagent working for twenty minutes: no new
  # output, and no new turn either. Nothing to charge.
  test "a legitimately quiet session is not charged an attempt while no new turn has started" do
    assert guard.proceed?

    5.times { assert guard.proceed? }

    @session.reload
    assert_nil @session.metadata[BUDGET.key],
      "a session that is merely slow starts no new turn, so there is no silent restart to count"
    assert_equal "running", @session.status
  end

  # Production invariant 6: an interval in which the platform denied compute must not
  # be charged against any bound an agent or a sweep keeps. A spot hold cannot even
  # reach here — SpotSessionHold returns above the `job_started_at` stamp — and an
  # auth-outage park is checked explicitly because the job that parks has already
  # stamped it.
  test "a session parked for an auth or quota outage is never charged an attempt" do
    assert guard.proceed?
    silent_restart!(at: "2026-09-05T11:56:47Z")
    @session.pause!
    @session.sleep! if @session.may_sleep?
    @session.merge_metadata!("auth_outage_reason" => "quota_exhausted")
    assert AuthOutageParkService.parked?(@session), "test setup must reach a real parked state"

    assert guard.proceed?

    assert_nil @session.reload.metadata[BUDGET.key],
      "quota depletion is budget pacing, not a failure signal — it must never reach this budget"
  end

  test "a restart that never started a turn is not evidence, and is not counted" do
    assert guard.proceed?

    # `job_started_at` unchanged: something stood the restart down (a spot hold, a
    # supersession, a concurrent job) before AgentSessionJob stamped it.
    assert guard.proceed?
    assert guard.proceed?

    assert_nil @session.reload.metadata[BUDGET.key]
  end

  test "a failure inside the guard leaves the recovery path exactly as it was" do
    Session.any_instance.stubs(:transcript_line_count).raises(RuntimeError, "boom")

    result = guard

    assert result.proceed?, "a broken guard must never be the reason a recoverable session is not recovered"
    assert_equal "running", @session.reload.status
  end
end
