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
# Both enqueuers also used to ignore the `false` that `resume_for_system_recovery!`
# returns when it DOES read the state correctly, and enqueued a job regardless —
# so a session already `running` got a second agent process pointed at it.
#
# The assertion that matters throughout is `assert_no_enqueued_jobs only:
# AgentSessionJob`: the job is the agent process, the clone and the quota spend.
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
