# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"
require_relative "../support/mock_process_manager"
require_relative "../support/mock_file_system_adapter"
require_relative "../support/mock_claude_cli_adapter"
require "automated_prompts"

# A session in the trash takes no turn.
#
# THE BUG THESE PIN (#630). A `spot` session held at the spot gate rides its
# refused turn on a delayed AgentSessionJob. Archiving the session cancelled
# nothing, and #perform had no `archived?` check anywhere before the gate: the
# concurrency guard passed (a held session carries no `running_job_id`), the
# pause guard was scoped to `waiting?`, and SpotSessionHold.hold_if_needed gates
# only on `session.spot?`. So the delayed job held the archived session AGAIN,
# bumped `spot_hold_count`, rewrote the hold metadata and enqueued the next
# delayed job — forever. Session 7456 was archived on 2026-08-22 and was still
# re-holding itself, at hold #26, a day later.
#
# The corollary, never observed but on the same path: when the gate ALLOWS,
# `hold_if_needed` returns false and #perform carries on into the normal start
# path with an archived session, spawning an agent against a clone the trash
# cleanup may already have deleted.
#
# The assertions that matter are `resumed_sessions` / `executed_commands` on the
# CLI adapter (a turn that actually spent quota), and `enqueued_jobs` (the next
# link in the re-check chain).
class AgentSessionJobArchivedSessionTest < ActiveJob::TestCase
  CLONE_PATH = "/tmp/archived-session-test-clone"

  setup do
    @held_retry_at = 1.minute.ago.iso8601
    @session = Session.create!(
      prompt: "Test prompt",
      agent_runtime: "claude_code",
      git_root: "https://github.com/test/repo.git",
      branch: "main",
      execution_provider: "local_filesystem",
      scheduling_class: SessionGenesis::SPOT,
      session_id: SecureRandom.uuid,
      status: :archived,
      archived_at: 1.hour.ago,
      metadata: {
        "clone_path" => CLONE_PATH,
        "working_directory" => CLONE_PATH,
        "runtime_started" => true,
        SpotSessionHold::HELD_AT => 1.hour.ago.iso8601,
        SpotSessionHold::HELD_REASON => "at_utilization_limit",
        SpotSessionHold::HELD_DETAIL => "Holding spot sessions: 5-hour window is at 87% of the 65% spot budget.",
        SpotSessionHold::HELD_RETRY_AT => @held_retry_at,
        SpotSessionHold::HELD_COUNT => 26,
        SpotSessionHold::HELD_TURN => SpotSessionHold::TURN_START
      },
      transcript: { "type" => "user", "message" => { "content" => "Test prompt" } }.to_json
    )
  end

  # ---------------------------------------------------------------------------
  # The loop itself
  # ---------------------------------------------------------------------------

  test "an archived spot session is not held again, and queues no further re-check" do
    cli = nil

    assert_no_enqueued_jobs do
      cli = run_job(@session, nil, decision: held_decision)
    end

    assert_empty cli.executed_commands, "an archived session must not reach the runtime"
    assert_empty cli.resumed_sessions, "an archived session must not reach the runtime"

    @session.reload
    assert_equal "archived", @session.status, "the refusal must not move a session out of the trash"
    assert_equal 26, @session.metadata[SpotSessionHold::HELD_COUNT],
                 "the hold ladder must not climb for a session nobody will ever start"
    assert_equal @held_retry_at, @session.metadata[SpotSessionHold::HELD_RETRY_AT],
                 "the hold record is left exactly as the last live hold wrote it"
    assert_nil @session.metadata["job_started_at"],
               "the turn is refused before the job records itself as started"
  end

  test "the re-check chain ends: a refused archived session enqueues nothing on a second pass either" do
    run_job(@session, nil, decision: held_decision)

    assert_no_enqueued_jobs do
      run_job(@session, nil, decision: held_decision)
    end
    assert_equal 26, @session.reload.metadata[SpotSessionHold::HELD_COUNT]
  end

  test "an archived spot session does not start when the gate allows" do
    cli = run_job(@session, nil, decision: allowed_decision)

    assert_empty cli.executed_commands,
                 "an open gate must not let an archived session spawn an agent"
    assert_empty cli.resumed_sessions
    @session.reload
    assert_equal "archived", @session.status
    assert_nil @session.metadata["job_started_at"]
    assert_nil @session.running_job_id, "a refused turn claims no job"
  end

  test "a priority archived session is refused too — the guard is not spot-only" do
    @session.update!(scheduling_class: SessionGenesis::PRIORITY)

    cli = run_job(@session, nil, decision: allowed_decision)

    assert_empty cli.executed_commands
    assert_equal "archived", @session.reload.status
  end

  # ---------------------------------------------------------------------------
  # A prompt-carrying turn (the recovery-nudge shape, #554's family)
  # ---------------------------------------------------------------------------

  test "a follow-up prompt delivered to an archived session starts no turn" do
    cli = run_job(@session, "[AUTOMATED SYSTEM MESSAGE - NOT USER INPUT] This session may have been interrupted",
                  decision: allowed_decision)

    assert_empty cli.resumed_sessions, "an archived session must not be resumed by a nudge"
    assert_empty cli.executed_commands
    @session.reload
    assert_equal "archived", @session.status,
                 "a nudge must not flip an archived session back to running"
    assert_nil @session.metadata["job_started_at"]
  end

  test "the refusal, and the prompt it dropped, are legible in the session's own log" do
    run_job(@session, "Please continue where you left off", decision: held_decision)

    log = @session.logs.find { |entry| entry.content.include?("it is in the trash") }
    assert_not_nil log, "a refused turn must say so in the session's own timeline"
    assert_equal "warning", log.level, "a dropped prompt is a loss, not an FYI"
    assert_includes log.content, "Please continue where you left off",
                    "the prompt that was discarded must be named rather than swallowed"
    assert_includes log.content, "rather than queueing another re-check"
  end

  test "a promptless refusal is logged at info and names no prompt" do
    run_job(@session, nil, decision: held_decision)

    log = @session.logs.find { |entry| entry.content.include?("it is in the trash") }
    assert_not_nil log
    assert_equal "info", log.level, "nothing was lost, so nothing is warned about"
    refute_includes log.content, "was not delivered"
  end

  test "a long dropped prompt is truncated in the log" do
    run_job(@session, "x" * 5_000, decision: held_decision)

    log = @session.logs.find { |entry| entry.content.include?("it is in the trash") }
    assert_not_nil log
    assert log.content.length < 600,
           "a trashed session's timeline must not gain a wall of text (was #{log.content.length})"
  end

  # ---------------------------------------------------------------------------
  # What must keep working
  # ---------------------------------------------------------------------------

  test "unarchive plus follow-up still runs a turn" do
    # The real flow: restore the session from the trash, then send it a prompt.
    # UnarchiveSessionService leaves `archived` inside its own lock BEFORE
    # anything is enqueued, so the job that arrives here sees a live session.
    AirPrepareService.any_instance.stubs(:prepare!)
    mock_fs = MockFileSystemAdapter.new
    mock_fs.mkdir_p(CLONE_PATH)

    result = UnarchiveSessionService.call(session: @session, file_system: mock_fs)
    assert result.success?, "unarchive must succeed: #{result.error}"

    @session.reload
    assert_equal "needs_input", @session.status
    refute @session.archived?, "the guard's whole premise: unarchive leaves `archived` before the job runs"

    cli = run_job(@session, "Please continue", decision: allowed_decision)

    assert_equal 1, cli.resumed_sessions.length,
                 "an unarchived session's follow-up must still reach the runtime"
    assert_includes cli.resumed_sessions.first[:prompt], "Please continue"
    refute @session.reload.archived?, "the turn ran, so the session is out of the trash for good"
  end

  test "a session unarchived straight back to waiting still starts" do
    # The Undo path (SessionsController#undo_archive) restores to `waiting`
    # rather than needs_input, and a first start follows.
    @session.update!(session_id: nil, metadata: @session.metadata.except("runtime_started"))
    @session.update!(archived_at: nil)
    @session.unarchive_to_waiting!

    cli = run_job(@session, nil, decision: allowed_decision)

    assert_equal 1, cli.executed_commands.length,
                 "an unarchived session's first start must still reach the runtime"
    refute @session.reload.archived?, "the turn ran, so the session is out of the trash for good"
  end

  test "a monitoring resume is NOT refused, so an archived session's process still gets cleaned up" do
    # resume_monitoring re-attaches to a process that is already running, and the
    # monitoring loop's own `archived?` check is what terminates it. Standing this
    # job down would leave a live agent nobody is watching.
    @session.merge_metadata!("process_pid" => 4242)

    job = build_job(MockClaudeCliAdapter.new)
    job.file_system.mkdir_p(CLONE_PATH)

    SpotGateService.stub(:evaluate, held_decision) do
      job.perform(@session.id, nil, resume_monitoring: true)
    end

    refusal = @session.logs.find { |entry| entry.content.include?("it is in the trash") }
    assert_nil refusal, "a monitoring resume must get past the guard to do its cleanup"
  end

  # ---------------------------------------------------------------------------
  # The archive that lands AFTER the turn was claimed (#884)
  # ---------------------------------------------------------------------------
  #
  # Every guard above this point decides EARLY — refuse_archived_session reads the
  # row at the top of #perform, and the FOR UPDATE claim in
  # Session#claim_system_recovery_turn! (#554, pinned from the enqueuer side in
  # test/jobs/archived_session_recovery_turn_test.rb) decides at claim time. Both
  # close the window where the archive lands BEFORE them and neither closes the one
  # where it lands after, which is minutes wide: the clone, the AIR prepare, the MCP
  # setup, the boot-tasks wait and credential injection all sit between the last
  # read and the spawn.
  #
  # Session 13221 archived one second after its recovery turn was claimed and
  # reached the spawn 94 seconds later, by which point the clone cleanup archiving
  # enqueued had already deleted the clone. File.open on the stderr log raised
  # ENOENT, the adapter re-raised it as ClaudeCliError, and it surfaced as a
  # `spawn_failed` ERROR that paged #alerts twice for a session that had already
  # finished.

  test "a session archived while its turn was being set up never reaches the runtime" do
    live = live_recovery_session

    cli = run_job_archiving_mid_flight(live)

    assert_empty cli.executed_commands, "an archive during setup must still stop the turn"
    assert_empty cli.resumed_sessions, "an archive during setup must still stop the turn"

    live.reload
    assert_equal "archived", live.status, "the refusal must not move a session out of the trash"
    assert_nil live.running_job_id, "a job that started nothing must leave no owner on the row"
  end

  test "the late refusal is an ordinary outcome, not a spawn failure" do
    live = live_recovery_session

    run_job_archiving_mid_flight(live)

    live.reload
    assert_nil live.metadata["failure_reason"],
               "an archived session taking no turn is the correct outcome, not a runtime fault"

    logs = live.logs.reload
    assert_empty logs.select { |entry| entry.level == "error" },
                 "the ERROR that paged #alerts twice is the thing being fixed"

    refusal = logs.find { |entry| entry.content.include?("archived after the turn was claimed") }
    assert_not_nil refusal, "expected a session log explaining why nothing happened"
    assert_equal "info", refusal.level
    assert_includes refusal.content, "its clone has already been cleaned up",
                    "the timeline should say the clone was already gone — that is what made this raise"
  end

  # The archive is the refusal; a clone that happens to still be on disk only
  # changes what the timeline says about it. Worth pinning both readings, because
  # "the clone was already gone" is the sentence that explains the ENOENT to
  # whoever reads this session next.
  test "an archive with the clone still on disk is refused too, and says so" do
    live = live_recovery_session

    cli = run_job_archiving_mid_flight(live, delete_clone: false)

    assert_empty cli.executed_commands
    assert_empty cli.resumed_sessions

    refusal = live.logs.reload.find { |entry| entry.content.include?("archived after the turn was claimed") }
    assert_not_nil refusal
    refute_includes refusal.content, "cleaned up",
                    "the clone was still there, so the timeline must not claim it was collected"
  end

  # The guard fails OPEN. Refusing on a row it could not read would drop a turn
  # that may be perfectly live, which is the worse of the two mistakes: the one
  # this guard prevents costs a wasted process on a session that is already over.
  # Driven directly rather than through #perform, because a session whose `reload`
  # raises cannot get through the job's `ensure`, which reloads too.
  test "a row that cannot be re-read is spawned rather than refused" do
    live = live_recovery_session
    live.stubs(:reload).raises(ActiveRecord::RecordNotFound, "row is unreadable")
    job = build_job(MockClaudeCliAdapter.new)

    refute job.send(:refuse_spawn_after_archive, live, CLONE_PATH, nil),
           "an unreadable row must not cost a live session its turn"
  end

  private

  # A session in exactly the state auto_continue_after_interrupt leaves behind: the
  # recovery turn is claimed (`running`), the clone and runtime session id are from
  # the interrupted turn, and a SYSTEM_RECOVERY prompt is on its way to #perform.
  def live_recovery_session
    Session.create!(
      prompt: "Test prompt",
      agent_runtime: "claude_code",
      git_root: "https://github.com/test/repo.git",
      branch: "main",
      execution_provider: "local_filesystem",
      session_id: SecureRandom.uuid,
      status: :running,
      metadata: {
        "clone_path" => CLONE_PATH,
        "working_directory" => CLONE_PATH,
        "runtime_started" => true
      },
      transcript: { "type" => "user", "message" => { "content" => "Test prompt" } }.to_json
    )
  end

  # Drive a live session's turn, archiving the row — and, by default, deleting its
  # clone the way the cleanup archiving enqueues does — partway through the setup
  # that precedes the spawn, after every early guard has already read the row and
  # passed it.
  def run_job_archiving_mid_flight(session, delete_clone: true)
    run_job(session, AutomatedPrompts.system_recovery(reason: "the job monitoring this session was interrupted"),
            decision: allowed_decision) do |job|
      Session.where(id: session.id).update_all(
        status: Session.statuses[:archived], archived_at: Time.current
      )
      job.file_system.rm_rf(CLONE_PATH) if delete_clone
    end
  end

  # Drive the real job for one turn against a stubbed gate decision, with the
  # runtime, the filesystem and the process manager mocked out. Mirrors
  # AgentSessionJobSpotGateTest#run_job so the two read the same way.
  #
  # A block, when given, runs partway through the setup that precedes the spawn —
  # after every early guard has read the row and passed it — and is handed the job
  # so it can reach the mock filesystem. That is the only way to stage a race that
  # lands DURING the setup rather than before it.
  def run_job(session, prompt, decision:, &mid_flight)
    cli = MockClaudeCliAdapter.new
    cli.resume_hook = ->(_opts) { { pid: 12_346, stderr_log_path: "#{CLONE_PATH}/claude_stderr.log" } }
    cli.execute_hook = ->(_opts) { { pid: 12_347, stderr_log_path: "#{CLONE_PATH}/claude_stderr.log" } }

    job = build_job(cli)
    job.file_system.mkdir_p(CLONE_PATH)
    job.file_system.write("#{CLONE_PATH}/claude_stderr.log", "")
    job.process_manager.wait_hook = ->(pid, _flags) { [ pid, MockProcessManager::MockStatus.new(0) ] }

    perform = lambda do
      SpotGateService.stub(:evaluate, decision) do
        GitCloneService.stub(:create_clone, { clone_path: CLONE_PATH, working_directory: CLONE_PATH }) do
          TranscriptPollerService.stub(:new, ->(_session, file_system: nil, broadcast_service: nil) {
            poller = Object.new
            def poller.poll_and_broadcast; end
            poller
          }) do
            Thread.stub(:new, ->(&_block) {
              thread = Object.new
              def thread.alive? = false
              def thread.kill; end
              def thread.join(*); end
              thread
            }) do
              job.perform(session.id, prompt)
            end
          end
        end
      end
    end

    if mid_flight
      # The orchestrator system prompt is built on the spawn path, after the clone,
      # the AIR prepare and the MCP setup and before the runtime is handed the
      # turn — so it stands in for "somewhere in the setup" without the test having
      # to know which step the race actually lands on.
      built = 0
      build_and_race = lambda do |**_kwargs|
        built += 1
        mid_flight.call(job)
        "orchestrator system prompt"
      end
      OrchestratorSystemPromptBuilder.stub(:build, build_and_race) { perform.call }
      assert_equal 1, built, "the mid-flight hook must actually have run, or the test proves nothing"
    else
      perform.call
    end

    cli
  end

  def build_job(cli)
    job = AgentSessionJob.new
    job.process_manager = MockProcessManager.new
    job.file_system = MockFileSystemAdapter.new
    job.cli_adapter = cli
    job
  end

  def held_decision
    SpotGateService::Decision.new(
      allowed: false, reason: "at_utilization_limit",
      detail: "Holding spot sessions: 5-hour window is at 87% of the 65% spot budget, averaged across all 4 accounts.",
      five_hour: nil, weekly: nil, active_sessions: 10, fleet_cap: 10,
      accounts_read: 4, pool_size: 4,
      fleet_burn_usd_per_minute: 1.2, candidate_burn_usd_per_minute: 0.4,
      pool_capacity: nil
    )
  end

  def allowed_decision
    SpotGateService::Decision.new(
      allowed: true, reason: "within_limits",
      detail: "1 of 10 session slots taken, and 5-hour has $412.00 of spot budget left.",
      five_hour: nil, weekly: nil, active_sessions: 1, fleet_cap: 10,
      accounts_read: 4, pool_size: 4,
      fleet_burn_usd_per_minute: 0.4, candidate_burn_usd_per_minute: 0.4,
      pool_capacity: nil
    )
  end
end
