# frozen_string_literal: true

require "test_helper"
require "minitest/mock"
require "mocha/minitest"

# An automated recovery sweep must not start a turn on a session that has been
# archived out from under it.
#
# THE BUG THESE PIN (#554). Every recovery sweep decides from a session object it
# read earlier: CleanupOrphanedSessionsJob and DeploymentRecoveryJob `find_each`
# over `paused_by = 'recovery'`, and SessionRecoveryService has been carrying its
# `session` since before it started killing a hung pid. `may_resume?` answers from
# THAT in-memory status, so a session archived in the meantime still looked
# resumable — and `resume!` wrote `status: running` straight over the archived row.
# Session 6335 was archived at 2026-08-19T07:35:34Z and had a fresh agent process,
# injected OAuth credentials and five connected MCP servers two seconds later.
#
# The cost: a wasted process, clone and credential injection; writes into a clone
# whose DeferredCloneCleanupJob deletion clock had already started; and
# `archived_at` overwritten by the re-archive, so the trash UI and the cleanup job
# both dated the session from the second archive rather than the first.
#
# This is the SELECTION-time half of the guard. AgentSessionJob's delivery-time
# guard (#630 / PR #697) cannot substitute for it: by the time that job runs the
# row genuinely says `running`, because the resume above is what made it say so.
#
# Every enqueuer here also used to ignore the `false` that `resume_for_system_recovery!`
# returns when it DOES read the state correctly, and enqueued a job regardless —
# so a session already `running` got a second agent process pointed at it.
#
# THE REST OF THE FAMILY (#753). `HealthMonitorService#retry_failed_sessions` and
# `AgentSessionJob#auto_continue_after_interrupt` had the identical shape and are
# covered below. Both windows are narrow rather than minutes wide, and neither is
# zero: the retry loop reads its relation once and then works from those objects,
# so every session past the first waits out a `Dir.exist?` stat on the clone
# volume and a full resume-and-enqueue for each session ahead of it, while the
# auto-continue spans that same `Dir.exist?` during SIGTERM shutdown — a deploy,
# which is when somebody is most likely to be emptying the trash.
#
# The assertion that matters throughout is `assert_no_enqueued_jobs only:
# AgentSessionJob`: the job is the agent process, the clone and the quota spend.
#
# One thing this harness cannot prove, which is why the guard is built not to need
# it: transactional fixtures wrap each test in a `joinable: false` transaction, so
# every `ActiveRecord::Base.transaction` here becomes a savepoint rather than the
# real outermost transaction it is in production. Nothing below therefore depends
# on rollback semantics — `claim_system_recovery_turn!` decides both refusals
# BEFORE it runs the caller's block, so a refused claim writes nothing in the
# first place. `a refused claim with no surrounding transaction leaves the row
# untouched` is the test that pins that.
class ArchivedSessionRecoveryTurnTest < ActiveJob::TestCase
  setup do
    @working_directory = Dir.mktmpdir("archived-recovery-turn")
    @session = Session.create!(
      prompt: "Test prompt",
      agent_runtime: "claude_code",
      git_root: "https://github.com/test/repo.git",
      branch: "main",
      execution_provider: "local_filesystem",
      session_id: SecureRandom.uuid,
      status: :needs_input,
      running_job_id: nil,
      metadata: {
        "clone_path" => @working_directory,
        "working_directory" => @working_directory,
        "paused_by" => "recovery"
      }
    )
  end

  teardown do
    FileUtils.remove_entry(@working_directory) if @working_directory && Dir.exist?(@working_directory)
  end

  # ---------------------------------------------------------------------------
  # SessionContinuation — the sweep enqueuer
  # ---------------------------------------------------------------------------

  # The race itself, reproduced exactly as the sweeps hit it: the object the sweep
  # is holding says `needs_input`, and the row says `archived`. `update_all` is the
  # archive landing without the in-memory object hearing about it, which is what a
  # second process (a human clicking Trash) does.
  test "a session archived after the sweep read it is not resumed and enqueues nothing" do
    stale = stale_session_archived_underneath

    assert_no_enqueued_jobs only: AgentSessionJob do
      assert_equal false, continue(stale),
        "continue_recovered_session must report that it did not continue an archived session"
    end

    @session.reload
    assert_equal "archived", @session.status,
      "the sweep must not write `running` over an archived row"
    assert_equal @archived_at.to_i, @session.archived_at.to_i,
      "archived_at must not be restamped by a resume the session never took"
  end

  test "refusing an archived session says so on the session's own timeline" do
    stale = stale_session_archived_underneath

    continue(stale)

    refusal = @session.logs.reload.find { |log| log.content.include?("it is in the trash") }
    assert_not_nil refusal, "expected a session log explaining why nothing happened"
    assert_includes refusal.content, "takes no turn"
  end

  # `paused_by` is deliberately left alone: it is what both sweeps select on, and
  # an archived session is already invisible to them (they select `needs_input` /
  # `waiting` / `failed`). Dropping it would sabotage the recovery still owed to
  # the session if a human later restores it from the trash.
  test "refusing an archived session leaves the recovery marker and the attempt budget alone" do
    stale = stale_session_archived_underneath

    continue(stale)

    @session.reload
    assert_equal "recovery", @session.metadata["paused_by"],
      "an archived refusal must not drop the marker the sweeps select on"
    assert_nil @session.metadata[SessionContinuation::CONTINUE_ATTEMPTS_KEY],
      "an archived refusal is terminal, not a failed attempt to be counted"
    assert_nil @session.metadata[SessionContinuation::CONTINUE_ABANDONED_KEY]
  end

  # The second half of the same defect: `resume_for_system_recovery!` returns false
  # for a session that is already `running`, and both enqueuers used to enqueue a
  # job anyway — a second agent process on one session.
  test "a session already running when the sweep gets to it enqueues nothing" do
    stale = Session.find(@session.id)
    Session.where(id: @session.id).update_all(
      status: Session.statuses[:running], running_job_id: "held-by-the-live-turn"
    )

    assert_no_enqueued_jobs only: AgentSessionJob do
      assert_equal false, continue(stale)
    end

    @session.reload
    assert_equal "running", @session.status
    assert_equal "held-by-the-live-turn", @session.running_job_id,
      "the refused claim must be rolled back, not left half-applied over the live turn"
    assert @session.logs.any? { |log| log.content.include?("cannot be resumed") },
      "expected a session log explaining the refusal"
  end

  # The guard reads the ROW, not the session's history. A session that was in the
  # trash and has been restored is a live session, and the recovery it is still
  # owed has to happen.
  test "a session that has been unarchived is continued normally" do
    Session.where(id: @session.id).update_all(
      status: Session.statuses[:archived], archived_at: 1.hour.ago
    )
    stale = Session.find(@session.id)
    # Restored from the trash — exactly what UnarchiveSessionService leaves behind.
    Session.where(id: @session.id).update_all(
      status: Session.statuses[:needs_input], archived_at: nil
    )

    assert_enqueued_jobs 1, only: AgentSessionJob do
      assert_equal true, continue(stale)
    end

    @session.reload
    assert_equal "running", @session.status
  end

  # The ordinary path, end to end through the cron sweep, so the guard cannot pass
  # the tests above by refusing everything.
  test "the orphan sweep still continues a live recovery-paused session" do
    assert_enqueued_jobs 1, only: AgentSessionJob do
      CleanupOrphanedSessionsJob.perform_now
    end

    @session.reload
    assert_equal "running", @session.status
    assert @session.logs.any? { |log| log.content.include?("automatically continued") }
  end

  # Both sweeps share SessionContinuation, but only one of them is exercised
  # above — and the deployment sweep is the one that runs on every deploy, which
  # is exactly when a human is most likely to be tidying the trash.
  test "the deployment sweep refuses a session archived after it read it" do
    stale = stale_session_archived_underneath

    assert_no_enqueued_jobs only: AgentSessionJob do
      assert_equal false, DeploymentRecoveryJob.new.send(:continue_recovered_session, stale)
    end

    @session.reload
    assert_equal "archived", @session.status
    assert @session.logs.any? { |log| log.content.include?("it is in the trash") }
  end

  # ---------------------------------------------------------------------------
  # SessionRecoveryService#auto_restart_session — the hung-process enqueuer
  # ---------------------------------------------------------------------------

  test "auto-restart after a hung process refuses a session archived underneath it" do
    stale = stale_session_archived_underneath
    service = SessionRecoveryService.new(stale)

    assert_no_enqueued_jobs only: AgentSessionJob do
      service.send(:auto_restart_session, 12_345)
    end

    @session.reload
    assert_equal "archived", @session.status
    assert_equal @archived_at.to_i, @session.archived_at.to_i
    assert @session.logs.any? { |log| log.content.include?("this session is in the trash") },
      "expected a session log explaining why the auto-restart did not happen"
  end

  test "auto-restart refuses a session that is already running" do
    stale = Session.find(@session.id)
    Session.where(id: @session.id).update_all(
      status: Session.statuses[:running], running_job_id: "held-by-the-live-turn"
    )

    assert_no_enqueued_jobs only: AgentSessionJob do
      SessionRecoveryService.new(stale).send(:auto_restart_session, 12_345)
    end

    @session.reload
    assert_equal "running", @session.status
    assert_equal "held-by-the-live-turn", @session.running_job_id
  end

  # The whole hung-process recovery, with the archive landing mid-flight — while
  # the service is draining the enqueued-message queue, which is the last thing it
  # does before deciding to auto-restart. This is the real shape of the race: a
  # human clicks Trash while Zimmer is killing a hung pid.
  test "a hung-process recovery archived mid-flight starts no agent" do
    @session.update!(status: :running, metadata: @session.metadata.merge("process_pid" => 12_345))
    service = SessionRecoveryService.new(
      @session,
      process_manager: terminating_process_manager,
      force_terminate_hung_process: true
    )

    archived_at = Time.current
    EnqueuedMessageProcessorService.any_instance.stubs(:process_next_message).with do
      Session.where(id: @session.id).update_all(
        status: Session.statuses[:archived], archived_at: archived_at
      )
      true
    end.returns(false)

    mock_poller = Minitest::Mock.new
    mock_poller.expect :poll_and_broadcast, nil

    assert_no_enqueued_jobs only: AgentSessionJob do
      TranscriptPollerService.stub :new, mock_poller do
        service.recover
      end
    end

    @session.reload
    assert_equal "archived", @session.status,
      "recovery must not resurrect a session a human trashed mid-recovery"
    assert_equal archived_at.to_i, @session.archived_at.to_i
    mock_poller.verify
  end

  # ---------------------------------------------------------------------------
  # HealthMonitorService#retry_failed_sessions — the operator-facing enqueuer
  # ---------------------------------------------------------------------------
  #
  # The relation is read once and the loop then works from those objects, so the
  # archive can land anywhere between the read and this iteration.
  # `can_retry_session?` is the hook the tests below archive through because it is
  # where the real gap is: it stats the clone directory, once per session, after
  # the relation has already been loaded.

  test "the failed-session retry refuses a session archived after the relation was read" do
    @session.update!(status: :failed)
    service = HealthMonitorService.new
    archived_at = 1.hour.ago
    service.stubs(:can_retry_session?).with do |_session|
      Session.where(id: @session.id).update_all(
        status: Session.statuses[:archived], archived_at: archived_at
      )
      true
    end.returns(true)

    results = nil
    assert_no_enqueued_jobs only: AgentSessionJob do
      results = service.retry_failed_sessions(session_ids: [ @session.id ])
    end

    @session.reload
    assert_equal "archived", @session.status,
      "the retry must not write `running` over an archived row"
    assert_equal archived_at.to_i, @session.archived_at.to_i,
      "archived_at must not be restamped by a resume the session never took"
    assert_empty results[:retried]
  end

  # The refusal has to reach the operator who asked for the retry. A silent no-op
  # on the `session_ids:` branch is indistinguishable from a bug, so the reason
  # goes back in `results[:skipped]` — what the JSON surfaces and the action_health
  # MCP tool return, and what HealthController now flashes — and onto the session's
  # own timeline.
  test "a refused retry is reported to the operator and on the session's timeline" do
    @session.update!(status: :failed)
    service = HealthMonitorService.new
    service.stubs(:can_retry_session?).with do |_session|
      Session.where(id: @session.id).update_all(status: Session.statuses[:archived])
      true
    end.returns(true)

    results = service.retry_failed_sessions(session_ids: [ @session.id ])

    skipped = results[:skipped].find { |entry| entry[:session_id] == @session.id }
    assert_not_nil skipped, "a refused retry must be reported, not dropped"
    assert_includes skipped[:reason], "it is in the trash"
    assert_empty results[:failed], "a refusal is not a failed retry"

    refusal = @session.logs.reload.find { |log| log.content.include?("Not retrying this session") }
    assert_not_nil refusal, "expected a session log explaining why nothing happened"
    assert_includes refusal.content, "takes no turn"
  end

  test "the failed-session retry refuses a session that went running underneath it" do
    @session.update!(status: :failed)
    service = HealthMonitorService.new
    service.stubs(:can_retry_session?).with do |_session|
      Session.where(id: @session.id).update_all(
        status: Session.statuses[:running], running_job_id: "held-by-the-live-turn"
      )
      true
    end.returns(true)

    results = nil
    assert_no_enqueued_jobs only: AgentSessionJob do
      results = service.retry_failed_sessions(session_ids: [ @session.id ])
    end

    @session.reload
    assert_equal "running", @session.status
    assert_equal "held-by-the-live-turn", @session.running_job_id,
      "the refused claim must leave the live turn's ownership alone"
    assert_includes results[:skipped].first[:reason], "cannot be resumed"
  end

  # The ordinary path, so the guard cannot pass the tests above by refusing
  # everything. The stale retry metadata still has to be cleared on the way.
  test "the failed-session retry still retries a live failed session" do
    @session.update!(
      status: :failed,
      running_job_id: "dead-job",
      metadata: @session.metadata.merge("paused_by" => "recovery")
    )

    results = nil
    assert_enqueued_jobs 1, only: AgentSessionJob do
      results = HealthMonitorService.new.retry_failed_sessions(session_ids: [ @session.id ])
    end

    @session.reload
    assert_equal "running", @session.status
    assert_equal [ @session.id ], results[:retried]
    assert_empty results[:skipped]
    assert_nil @session.metadata["paused_by"], "the stale retry metadata must still be cleared"
  end

  # ---------------------------------------------------------------------------
  # AgentSessionJob#auto_continue_after_interrupt — the SIGTERM enqueuer
  # ---------------------------------------------------------------------------
  #
  # The narrowest window of the family, and not zero: the three checks at the top
  # of the method read the in-memory object, and the last of them stats the clone
  # volume during SIGTERM shutdown — which is a deploy, which is exactly when
  # somebody is emptying the trash.
  #
  # These pin the window where the archive lands BEFORE the claim, which is the
  # only one a lock taken at claim time can close. The other side of it — the
  # archive that lands AFTER the claim, while the job it enqueued is still setting
  # up the clone (#884) — is pinned in
  # test/jobs/agent_session_job_archived_session_test.rb, which owns the harness
  # that drives AgentSessionJob#perform all the way to the spawn.

  test "auto-continue after a job interruption refuses a session archived underneath it" do
    stale = stale_session_archived_underneath

    assert_no_enqueued_jobs only: AgentSessionJob do
      AgentSessionJob.new.send(:auto_continue_after_interrupt, stale)
    end

    @session.reload
    assert_equal "archived", @session.status,
      "an interrupted job must not resurrect a session a human trashed on the way out"
    assert_equal @archived_at.to_i, @session.archived_at.to_i
    assert @session.logs.any? { |log| log.content.include?("it is in the trash") },
      "expected a session log explaining why nothing happened"
  end

  test "auto-continue after a job interruption refuses a session that is already running" do
    stale = Session.find(@session.id)
    Session.where(id: @session.id).update_all(
      status: Session.statuses[:running], running_job_id: "held-by-the-live-turn"
    )

    assert_no_enqueued_jobs only: AgentSessionJob do
      AgentSessionJob.new.send(:auto_continue_after_interrupt, stale)
    end

    @session.reload
    assert_equal "running", @session.status
    assert_equal "held-by-the-live-turn", @session.running_job_id,
      "the refused claim must leave the live turn's ownership alone"
    assert @session.logs.any? { |log| log.content.include?("cannot be resumed") }
  end

  test "auto-continue after a job interruption still continues a live session" do
    @session.update!(running_job_id: "the-interrupted-job")

    assert_enqueued_jobs 1, only: AgentSessionJob do
      AgentSessionJob.new.send(:auto_continue_after_interrupt, @session)
    end

    @session.reload
    assert_equal "running", @session.status
    assert_nil @session.metadata["paused_by"], "the stale retry metadata must still be cleared"
    assert @session.logs.any? { |log| log.content.include?("automatically continued after job interruption") }
  end

  # ---------------------------------------------------------------------------
  # The shared admission predicate
  # ---------------------------------------------------------------------------

  test "claim_system_recovery_turn! decides from the row, not from the loaded object" do
    stale = stale_session_archived_underneath

    assert_equal "needs_input", stale.status,
      "the object under test must still believe it is resumable"
    assert stale.may_resume?, "may_resume? answering from stale state is the defect"

    assert_equal :archived, stale.claim_system_recovery_turn!
    assert_equal "archived", @session.reload.status
  end

  test "claim_system_recovery_turn! does not run its block for a refused claim" do
    stale = stale_session_archived_underneath
    ran = false

    assert_equal :archived, stale.claim_system_recovery_turn! { ran = true }
    assert_equal false, ran,
      "the stale-metadata clear must not touch a row the claim is about to refuse"
  end

  test "claim_system_recovery_turn! does not run its block for an unresumable session either" do
    stale = Session.find(@session.id)
    Session.where(id: @session.id).update_all(status: Session.statuses[:running])
    ran = false

    assert_equal :not_resumable, stale.claim_system_recovery_turn! { ran = true }
    assert_equal false, ran,
      "both refusals must be decided before the block, not only the archived one"
  end

  # The contract that lets both callers get away with a bare `next` instead of a
  # rollback: a refused claim writes NOTHING, so there is nothing to undo. Called
  # with no surrounding transaction on purpose — that is the shape in which a
  # caller who forgot to roll back would silently commit the block's writes over a
  # live turn, and the reason the refusal checks sit above the block rather than
  # below it.
  test "a refused claim with no surrounding transaction leaves the row untouched" do
    Session.where(id: @session.id).update_all(running_job_id: "held-by-the-live-turn")
    archived = Session.find(@session.id)
    running = Session.find(@session.id)
    Session.where(id: @session.id).update_all(status: Session.statuses[:archived])

    assert_equal :archived, archived.claim_system_recovery_turn! { archived.update!(running_job_id: nil) }
    assert_equal "held-by-the-live-turn", @session.reload.running_job_id

    Session.where(id: @session.id).update_all(status: Session.statuses[:running])

    assert_equal :not_resumable, running.claim_system_recovery_turn! { running.update!(running_job_id: nil) }
    assert_equal "held-by-the-live-turn", @session.reload.running_job_id,
      "a refusal must not commit the caller's stale-metadata clear over a live turn"
  end

  test "claim_system_recovery_turn! resumes a live session and reports the claim" do
    assert_equal :claimed, @session.claim_system_recovery_turn!
    assert_equal "running", @session.reload.status
  end

  private

  # A session object read while it was resumable, whose row has since been
  # archived by somebody else. `update_all` skips callbacks and dirty tracking on
  # purpose: that is a second process winning the race, not this one archiving
  # itself.
  def stale_session_archived_underneath
    stale = Session.find(@session.id)
    @archived_at = 1.hour.ago
    Session.where(id: @session.id).update_all(
      status: Session.statuses[:archived], archived_at: @archived_at
    )
    stale
  end

  def continue(session)
    CleanupOrphanedSessionsJob.new.send(:continue_recovered_session, session)
  end

  def terminating_process_manager
    terminated = false
    pm = Object.new
    pm.define_singleton_method(:running?) { |_pid| !terminated }
    pm.define_singleton_method(:kill) { |_signal, _pid| terminated = true }
    pm.define_singleton_method(:wait) { |_pid, _flags| nil }
    pm
  end
end
