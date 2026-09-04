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

  # ---------------------------------------------------------------------------
  # The archive that lands mid-turn and takes the clone with it (#886)
  # ---------------------------------------------------------------------------
  #
  # The guard above stands the turn down AT the spawn. The minutes of setup ahead
  # of it are the rest of the window: AirPrepareService#prepare! shells out with
  # the clone as cwd and rescues only its two domain errors, and the credential
  # injection writes into the clone. When archiving has already deleted that clone,
  # an Errno::ENOENT from either lands in #perform's catch-all rescue — which had
  # no `archived?` check, so it logged two ERROR lines to the session, stamped
  # `failure_reason: "exception"`, and re-raised into the exception reporter. That
  # is the same unactionable double page as #884, for a session that had already
  # finished.
  #
  # These pin both halves: the quiet path for a session the row says is archived,
  # and — the property that matters more, because the failure mode of getting it
  # wrong is SILENT — the loud path, untouched, for one that is not.

  test "a turn that dies after its session was archived is not stamped as a failure" do
    live = live_recovery_session

    run_job_dying_mid_flight(live)

    live.reload
    assert_nil live.metadata["failure_reason"],
               "an archived session cannot act on a failure_reason, and did not fail"
    assert_nil live.metadata["exception_class"]
    assert_nil live.metadata["exception_message"]
    assert_equal "archived", live.status, "the session stays in the trash it was put in"
    assert_nil live.running_job_id, "a job that ended without spawning must leave no owner on the row"
  end

  test "the archived turn's exception reaches no ERROR log and does not re-raise" do
    live = live_recovery_session

    # No assert_raises: run_job returning at all is the assertion. The `raise e` is
    # the reporting path (sentry-rails captures terminal ActiveJob failures) and
    # ActiveJob logs the terminal failure at ERROR, which is what the
    # zimmer_backend_log_errors rule reads — so swallowing it is what removes both
    # pages, and a quiet path that still raised would remove neither.
    run_job_dying_mid_flight(live)

    logs = live.logs.reload
    assert_empty logs.select { |entry| entry.level == "error" },
                 "the ERROR that paged #alerts twice is the thing being fixed"
    refute logs.any? { |entry| entry.content.include?("Error in agent execution") },
           "the loud path must not have run"
  end

  test "the swallowed exception is still legible on the session's own timeline" do
    live = live_recovery_session

    run_job_dying_mid_flight(live)

    record = live.logs.reload.find { |entry| entry.content.include?("after the session was archived") }
    assert_not_nil record, "the history has to stay readable — quiet is not the same as silent"
    assert_equal "warning", record.level, "non-paging, but not an FYI either"
    assert_includes record.content, "Errno::ENOENT", "the exception that ended the turn is named"
    assert_includes record.content, "claude_stderr.log", "and so is what it could not find"
    assert_includes record.content, "nothing is retried"
  end

  test "a long exception message is truncated on the archived session's timeline" do
    live = live_recovery_session

    run_job_dying_mid_flight(live, error: RuntimeError.new("x" * 20_000))

    record = live.logs.reload.find { |entry| entry.content.include?("after the session was archived") }
    assert_not_nil record
    assert record.content.length < 1_500,
           "a trashed session's timeline must not gain a wall of text (was #{record.content.length})"
    # Bounded on both sides: a message chopped to nothing, or dropped entirely,
    # would satisfy the cap above and lose the only description of what happened.
    assert_includes record.content, "RuntimeError"
    assert_includes record.content, "x" * 500, "the head of the message must survive the cap"
  end

  # The `return` on the quiet path is not an early exit past the teardown — Ruby runs
  # the `ensure`, and the `ensure` is what kills the process for an archived session.
  # Every other test here stages the race before the spawn, so this is the only one
  # that holds a pid at the moment the exception fires: without it, a regression that
  # skipped the kill would leave a live agent on a trashed session and go unnoticed.
  test "a process already spawned is still terminated when the quiet path returns" do
    live = live_recovery_session

    job, cli = run_job_dying_after_spawn(live)

    assert_equal 1, cli.resumed_sessions.length, "the turn must have got as far as a real spawn"
    # The leader or its whole group — ProcessTerminationService chooses, and either
    # one is the kill this test is about.
    assert job.process_manager.killed_processes.any? { |kill| kill[:pid].abs == 12_346 && kill[:signal] == "TERM" },
           "the ensure must still kill the process it spawned (killed: #{job.process_manager.killed_processes.inspect})"

    live.reload
    assert_nil live.metadata["failure_reason"], "and the outcome is still recorded quietly"
    assert_empty live.logs.reload.select { |entry| entry.level == "error" }
  end

  # Decision 2 of the fix: the dropped `raise e` is also the dropped GoodJob retry.
  # Driven through `perform_now` rather than `#perform`, because `retry_on` is a
  # rescue handler around the latter — call `#perform` directly and the assertion is
  # vacuous. Timeout::Error rather than ENOENT: it is one of the three classes this
  # job actually declares a retry for, so it is the case where the decision bites.
  test "an archived session's turn enqueues no retry, even for a retryable exception" do
    live = live_recovery_session

    assert_no_enqueued_jobs do
      run_job_dying_mid_flight(live, error: Timeout::Error.new("boom"), via: :perform_now)
    end

    assert_nil live.reload.metadata["failure_reason"]
  end

  test "a live session's turn still enqueues the retry a retryable exception earns" do
    live = live_recovery_session

    assert_enqueued_with(job: AgentSessionJob) do
      run_job_dying_mid_flight(live, archive: false, error: Timeout::Error.new("boom"), via: :perform_now)
    end
  end

  # THE NEGATIVE, and the reason the guard re-reads the row rather than trusting
  # the session object #perform has been carrying since before the clone: a live
  # session raising the very same exception must be completely unaffected. A lost
  # clone on a session that SHOULD run is #817's case — re-clone and retry — and
  # the quiet path must never reach it.
  test "a live session raising the same exception keeps the whole loud path" do
    live = live_recovery_session

    assert_raises(Errno::ENOENT) do
      run_job_dying_mid_flight(live, archive: false)
    end

    live.reload
    assert_equal "exception", live.metadata["failure_reason"],
                 "a genuine fault must still be recorded as one"
    assert_equal "Errno::ENOENT", live.metadata["exception_class"]
    assert_includes live.metadata["exception_message"], "claude_stderr.log"
    assert_equal "failed", live.status, "a live session that raised is failed, not left running"
    assert_nil live.running_job_id

    errors = live.logs.reload.select { |entry| entry.level == "error" }
    assert errors.any? { |entry| entry.content.include?("Error in agent execution") },
           "the operator-facing error line is part of the loud path"
    assert errors.any? { |entry| entry.content.include?("Backtrace:") }
    refute live.logs.any? { |entry| entry.content.include?("after the session was archived") },
           "nothing about the quiet path may touch a session that is not archived"
  end

  # The guard fails LOUD. A row it cannot read is the one case where both mistakes
  # are available, and silencing a fault that may be real is the worse of them —
  # the loud path's cost is a page, this path's cost is a session that failed with
  # no failure_reason and no alert. Driven directly, because a session whose
  # `reload` raises cannot get through the job's `ensure`, which reloads too; the
  # `false` is the whole answer, since #perform's rescue does the rest of the loud
  # path unchanged (pinned by the live-session test above).
  test "a row that cannot be re-read answers false, so the loud path runs" do
    live = live_recovery_session
    live.stubs(:reload).raises(ActiveRecord::RecordNotFound, "row is unreadable")
    job = build_job(MockClaudeCliAdapter.new)

    refute job.send(:swallow_exception_after_archive, live, clone_gone_error, nil),
           "an unreadable row must not buy an exception a quiet exit"
  end

  # The other half of the running_job_id bookkeeping, and the dangerous half: the
  # setup this rescue sits at the end of is long enough for another job to have
  # claimed the session meanwhile, and wiping THAT claim would tell the concurrency
  # guard and the orphan sweep that nobody is driving a session somebody is.
  test "a claim belonging to another job is left alone" do
    live = live_recovery_session
    live.update_columns(
      running_job_id: "some-other-job", status: Session.statuses[:archived], archived_at: Time.current
    )
    job = build_job(MockClaudeCliAdapter.new)

    assert job.send(:swallow_exception_after_archive, live, clone_gone_error, nil)
    assert_equal "some-other-job", live.reload.running_job_id,
                 "only this job's own claim may be released"
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

  # Stage the #886 race: partway through the setup that precedes the spawn — after
  # every early guard has read the row and passed it — archive the row the way a
  # user emptying the trash does (in the database only, so the session object
  # #perform is carrying stays stale, which is the whole point), delete the clone
  # the way the cleanup archiving enqueues does, and then raise the ENOENT that a
  # step touching that clone would raise.
  #
  # `archive: false` stages the same exception, and the same missing clone, on a
  # session that is still live — #817's case, which must reach the untouched loud
  # path. The clone is deleted either way, so the two differ in exactly one thing:
  # what the row says.
  def run_job_dying_mid_flight(session, archive: true, error: nil, via: :perform)
    error ||= clone_gone_error

    run_job(session, AutomatedPrompts.system_recovery(reason: "the job monitoring this session was interrupted"),
            decision: allowed_decision, via: via) do |job|
      if archive
        Session.where(id: session.id).update_all(
          status: Session.statuses[:archived], archived_at: Time.current
        )
      end
      job.file_system.rm_rf(CLONE_PATH)
      raise error
    end
  end

  # The same race, staged one step later: after the spawn, so the job is holding a
  # live pid when the exception fires. Returns the job as well as the CLI, because
  # what this proves is about the job's process manager rather than the runtime.
  def run_job_dying_after_spawn(session)
    cli = run_job(session, AutomatedPrompts.system_recovery(reason: "the job monitoring this session was interrupted"),
                  decision: allowed_decision, at: :after_spawn) do |job|
      Session.where(id: session.id).update_all(
        status: Session.statuses[:archived], archived_at: Time.current
      )
      job.file_system.rm_rf(CLONE_PATH)
      # The spawned pid is the CLI mock's, so the process manager has never heard of
      # it and would report it already dead. Make it answer the way a live agent
      # does — alive until something signals it — or the kill under test is skipped.
      job.process_manager.running_hook = lambda do |pid|
        pid == 12_346 && job.process_manager.killed_processes.none? { |kill| kill[:pid] == pid && kill[:signal] != 0 }
      end
      raise clone_gone_error
    end

    [ @job, cli ]
  end

  # What File.open on the stderr log raises once the clone is gone.
  def clone_gone_error
    Errno::ENOENT.new("No such file or directory @ rb_sysopen - #{CLONE_PATH}/claude_stderr.log")
  end

  # Drive the real job for one turn against a stubbed gate decision, with the
  # runtime, the filesystem and the process manager mocked out. Mirrors
  # AgentSessionJobSpotGateTest#run_job so the two read the same way.
  #
  # A block, when given, runs partway through the setup that precedes the spawn —
  # after every early guard has read the row and passed it — and is handed the job
  # so it can reach the mock filesystem. That is the only way to stage a race that
  # lands DURING the setup rather than before it.
  def run_job(session, prompt, decision:, via: :perform, at: :setup, &mid_flight)
    cli = MockClaudeCliAdapter.new
    cli.resume_hook = ->(_opts) { { pid: 12_346, stderr_log_path: "#{CLONE_PATH}/claude_stderr.log" } }
    cli.execute_hook = ->(_opts) { { pid: 12_347, stderr_log_path: "#{CLONE_PATH}/claude_stderr.log" } }

    # Exposed for the assertions that are about the JOB rather than the runtime —
    # what its process manager killed, chiefly.
    job = @job = build_job(cli, session.id, prompt)
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
              # perform_now for the tests that are about `retry_on`, which is a rescue
              # handler wrapped AROUND #perform — calling #perform directly would make
              # a retry assertion vacuous.
              via == :perform_now ? job.perform_now : job.perform(session.id, prompt)
            end
          end
        end
      end
    end

    if mid_flight
      raced = 0
      race = lambda do |*_args, **_kwargs|
        raced += 1
        mid_flight.call(job)
        "orchestrator system prompt"
      end

      if at == :after_spawn
        # SessionMemoryWatch is constructed between the spawn and the first turn of
        # the monitoring loop, so it is the narrowest stand-in for "after the process
        # exists" — the only staging in which the job is holding a live pid.
        SessionMemoryWatch.stub(:new, race) { perform.call }
      else
        # The orchestrator system prompt is built on the spawn path, after the clone,
        # the AIR prepare and the MCP setup and before the runtime is handed the
        # turn — so it stands in for "somewhere in the setup" without the test having
        # to know which step the race actually lands on.
        OrchestratorSystemPromptBuilder.stub(:build, race) { perform.call }
      end
      assert_equal 1, raced, "the mid-flight hook must actually have run, or the test proves nothing"
    else
      perform.call
    end

    cli
  end

  def build_job(cli, *arguments)
    job = AgentSessionJob.new(*arguments)
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
