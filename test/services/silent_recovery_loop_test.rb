require "test_helper"
require "minitest/mock"
require "mocha/minitest"

# zimmer#988, end to end: the recovery loop that never exits.
#
# Production sessions 14313, 14391, 14474 and 14501 all ran this sequence — one of
# them for three hours. `CleanupOrphanedSessionsJob` calls a silent `running` session
# hung, `SessionRecoveryService` terminates a pid that is already gone and restarts
# the session, the restart stamps a fresh `job_started_at` and writes not one
# transcript line, and the restart's own `resume` moves `last_timeline_entry_at` to
# now — so fifteen minutes later the sweep reaches an identical verdict about an
# identical session. The status reads `running` throughout, so nothing surfaces it.
#
# These tests drive that loop for real, one cycle per iteration, and assert where it
# now stops. The two at the bottom are the ones that keep the fix honest: a session
# that is slow, and a session the platform denied compute, must survive the same
# number of cycles untouched.
class SilentRecoveryLoopTest < ActiveJob::TestCase
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
      last_timeline_entry_at: 20.minutes.ago,
      metadata: {
        "process_pid" => 65662,
        "clone_path" => Rails.root.to_s,
        "working_directory" => Rails.root.to_s,
        "job_started_at" => "2026-09-05T11:23:16Z"
      }
    )

    # The pid recorded on the session does not exist — `ps -p 65662` was empty in the
    # report. Termination is therefore a no-op that reports success, exactly as
    # ProcessTerminationService does against a pid that has already gone.
    @process_manager = Object.new
    @process_manager.define_singleton_method(:running?) { |_pid| false }
    @process_manager.define_singleton_method(:kill) { |_signal, _pid| nil }
    @process_manager.define_singleton_method(:wait) { |_pid, _flags| nil }
  end

  # One turn of the loop the sweep runs: the session is `running`, orphaned and silent,
  # so recovery terminates and restarts it — and the restarted job then stamps
  # `job_started_at` and produces nothing, which is the whole defect.
  #
  # @param produces_output [Boolean] let the restarted turn write a transcript line
  # @param starts_turn [Boolean] let the restarted job get as far as stamping
  #   `job_started_at` (false models a spot hold, which returns above that stamp)
  def recovery_cycle!(index, produces_output: false, starts_turn: true)
    @session.reload
    @session.update!(status: :running, running_job_id: nil, last_timeline_entry_at: 20.minutes.ago)

    service = SessionRecoveryService.new(
      @session, process_manager: @process_manager, force_terminate_hung_process: true
    )
    poller = Object.new
    poller.define_singleton_method(:poll_and_broadcast) { nil }
    TranscriptPollerService.stub(:new, poller) { service.recover }

    @session.reload
    return @session unless @session.running?

    # What the restarted AgentSessionJob does before it wedges.
    @session.merge_metadata!("job_started_at" => "2026-09-05T1#{index}:00:00Z") if starts_turn
    if produces_output
      @session.update!(transcript: Array.new(index + 1) { { "type" => "assistant" }.to_json }.join("\n"))
    end
    @session
  end

  # BUDGET.max + 2 cycles: the first records the baseline (there is no earlier restart
  # to judge), the next BUDGET.max are judged silent and spend the budget, and the last
  # one is the give-up.
  def run_silent_loop!
    (BUDGET.max + 2).times { |i| recovery_cycle!(i) }
  end

  test "a session whose recovery restarts all produce nothing ends in failed, not running forever" do
    run_silent_loop!

    @session.reload
    assert_equal "failed", @session.status,
      "before this bound, this exact sequence reported `running` indefinitely (#988)"
    assert_equal Sessions::SilentRecoveryGuard::FAILURE_REASON, @session.metadata["failure_reason"]
    assert_equal BUDGET.max, @session.metadata[BUDGET.key]
  end

  test "the loop is bounded rather than merely slowed - further sweeps do not restart it again" do
    run_silent_loop!
    assert_equal "failed", @session.reload.status

    # A `failed` session is not selected by recover_running_orphans, but the sweep's
    # failed-session branch selects `paused_by = 'recovery'`. Dropping the marker is
    # what keeps this terminal.
    assert_nil @session.metadata["paused_by"]

    assert_no_enqueued_jobs only: AgentSessionJob do
      RecoveryContinuationJob.perform_now(@session.id)
      CleanupOrphanedSessionsJob.perform_now
    end
    assert_equal "failed", @session.reload.status
  end

  test "the give-up is visible on the session's own timeline, not only in the status" do
    run_silent_loop!

    content = @session.reload.logs.order(created_at: :asc).map(&:content).join("\n")
    assert_includes content, "not one of those turns produced a single transcript event"
    assert_includes content, "Restart it to try once more"
  end

  test "recovery names an absent process as absent rather than calling it hung" do
    AgentProcessLiveness.stubs(:status).returns(:dead)

    recovery_cycle!(0)

    content = @session.reload.logs.order(created_at: :asc).map(&:content).join("\n")
    assert_includes content, "is already gone (liveness: dead)"
    assert_includes content, "the silence is an absent process, not a hung one"
  end

  # The other chokepoint. `SessionContinuation#continue_recovered_session` is shared by
  # CleanupOrphanedSessionsJob, DeploymentRecoveryJob and RecoveryContinuationJob, and
  # its own MAX_CONTINUE_ATTEMPTS budget cannot reach this: that one counts continues
  # that never start, and every continue here SUCCEEDS — which clears
  # STALE_RETRY_METADATA_KEYS, and the attempt counter with it.
  test "the auto-continue path is bounded too, not just the hung-process path" do
    (BUDGET.max + 2).times do |i|
      @session.reload
      @session.update!(status: :needs_input, running_job_id: nil)
      @session.merge_metadata!("paused_by" => "recovery")

      RecoveryContinuationJob.perform_now(@session.id)

      @session.reload
      next unless @session.running?

      @session.merge_metadata!("job_started_at" => "2026-09-05T1#{i}:00:00Z")
    end

    @session.reload
    assert_equal "failed", @session.status
    assert_equal Sessions::SilentRecoveryGuard::FAILURE_REASON, @session.metadata["failure_reason"]
  end

  # ---- The false-positive direction -------------------------------------------------

  test "a session whose restarts DO produce output is restarted indefinitely, as before" do
    (BUDGET.max + 3).times { |i| recovery_cycle!(i, produces_output: true) }

    @session.reload
    assert_equal "running", @session.status,
      "a session that answers every restart must never be failed by this bound"
    assert_nil @session.metadata[BUDGET.key]
    assert_nil @session.metadata["failure_reason"]
  end

  # Production invariant 6: an interval in which the platform denied compute is not
  # charged against any bound. A spot hold returns above AgentSessionJob's
  # `job_started_at` stamp, so a held turn is invisible to the budget by construction.
  test "restarts that never start a turn - a spot or quota hold - are not charged" do
    (BUDGET.max + 3).times { |i| recovery_cycle!(i, starts_turn: false) }

    @session.reload
    assert_equal "running", @session.status
    assert_nil @session.metadata[BUDGET.key],
      "quota depletion is budget pacing, not a failure signal (production invariant 6)"
  end

  # The mixed case, and the safety property the whole design turns on: reaching the cap
  # is not what fails a session — a FRESH silent restart while the cap is spent is. A
  # session that answers, by a human's restart or by anything else, is read as recovered
  # and starts again from zero.
  test "output after the budget is fully spent still hands it back, and nothing is failed" do
    # Three silent restarts take the counter all the way to its maximum.
    (BUDGET.max + 1).times { |i| recovery_cycle!(i) }
    assert_equal BUDGET.max, @session.reload.metadata[BUDGET.key]
    assert_equal "running", @session.status

    # Then the session answers — one transcript event is enough.
    @session.update!(transcript: { "type" => "assistant" }.to_json)

    recovery_cycle!(BUDGET.max + 1)

    @session.reload
    assert_equal "running", @session.status,
      "a session that is producing output again must never be failed by a spent counter"
    assert_nil @session.metadata[BUDGET.key], "output since the last restart ends the incident"
    assert_nil @session.metadata["failure_reason"]

    # And the count starts again from the restart that followed the recovery, rather
    # than resuming where it left off.
    recovery_cycle!(BUDGET.max + 2)
    assert_equal 1, @session.reload.metadata[BUDGET.key]
    assert_equal "running", @session.status
  end
end
