# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"

# An automated recovery sweep must not resume a session whose work has been
# handed to a replacement (#801).
#
# THE INCIDENT THESE PIN. On 2026-09-02 session 11924 was created to implement
# zimmer#683 and failed before its first turn on an infrastructure error. Zimmer's
# recovery flow created session 11931 to replace it, stamping
# `custom_metadata.replaces_session: 11924` on the REPLACEMENT. 11931 did the
# work: PR #765 merged and closed #683 at 03:58, and 11931 archived at 08:35. At
# 15:02 — eleven hours later — the orphan sweep resumed 11924. It re-implemented
# the same seven files and opened a duplicate PR (#799), which it caught only
# because its `open-pr` flow happened to call `get_session` and noticed the
# sibling. It happened a second time the same day, to 11925/11933.
#
# Two things made it possible and both are fixed here:
#
#   1. the REPLACED session carried no back-reference — `replaces_session` was
#      written on the replacement only, so nothing reading 11924 was told the
#      work had moved;
#   2. no resume path asked whether the work had moved.
#
# THE SYMMETRIC FAILURE IS THE ONE TO FEAR. This adds a REFUSAL to paths whose
# whole job is to un-strand sessions, and a refusal that matches too broadly
# strands genuinely orphaned sessions silently. So the negative cases below carry
# as much weight as the positive ones: a session with no replacement, and a
# session whose only replacement failed, must resume exactly as they did before.
class SupersededSessionRecoveryTurnTest < ActiveJob::TestCase
  setup do
    @working_directory = Dir.mktmpdir("superseded-recovery-turn")
    @session = Session.create!(
      prompt: "Implement #683",
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
  # The reproduction
  # ---------------------------------------------------------------------------

  # #801 itself, end to end through the cron that caused it: a session left
  # recovery-paused, a replacement that finished the work and archived, and the
  # orphan sweep running over both.
  test "the orphan sweep does not resume a session whose replacement finished the work" do
    replacement = archived_replacement

    assert_no_enqueued_jobs only: AgentSessionJob do
      CleanupOrphanedSessionsJob.perform_now
    end

    @session.reload
    assert_equal "needs_input", @session.status,
      "the sweep must not resume a session another session has taken the work over from"
    assert_nil @session.running_job_id
    refusal = @session.logs.find { |log| log.content.include?("handed to session #{replacement.id}") }
    assert_not_nil refusal, "expected a session log naming the replacement that stopped the resume"
    assert_includes refusal.content, "re-do work"
  end

  # The negative half, and the one that matters most: nothing about an ordinary
  # orphan changes. Same session, same sweep, no replacement.
  test "a genuinely orphaned session with no replacement still resumes exactly as before" do
    assert_enqueued_jobs 1, only: AgentSessionJob do
      CleanupOrphanedSessionsJob.perform_now
    end

    @session.reload
    assert_equal "running", @session.status
    assert_nil @session.metadata["paused_by"], "the stale retry metadata must still be cleared"
    assert @session.logs.any? { |log| log.content.include?("automatically continued after orphan cleanup") }
  end

  # A replacement that failed is not carrying anything, and the session it
  # replaced may still be the best hope. Matching it would be the broad match
  # that strands sessions silently.
  test "a replacement that itself failed does not block the original's recovery" do
    replacement_for(@session, status: :failed)

    assert_enqueued_jobs 1, only: AgentSessionJob do
      CleanupOrphanedSessionsJob.perform_now
    end

    assert_equal "running", @session.reload.status
  end

  # The refusal repeats where the other two do not: a superseded session stays
  # selected by both sweeps every five minutes forever, so `paused_by` — the
  # marker they select on — is dropped once, and the timeline says so once.
  test "the refusal stops the sweep re-reading the session and records why" do
    replacement = archived_replacement

    CleanupOrphanedSessionsJob.perform_now
    CleanupOrphanedSessionsJob.perform_now
    CleanupOrphanedSessionsJob.perform_now

    @session.reload
    assert_nil @session.metadata["paused_by"],
      "a superseded session must stop being selected by the sweeps"
    assert_equal "superseded by session #{replacement.id}",
      @session.metadata[SessionContinuation::CONTINUE_ABANDONED_KEY]
    refusals = @session.logs.select { |log| log.content.include?("handed to session #{replacement.id}") }
    assert_equal 1, refusals.size,
      "the refusal must be written once, not on every five-minute pass"
    assert_equal "needs_input", @session.status
  end

  # Both sweeps share SessionContinuation, and the deployment one runs on every
  # deploy.
  test "the deployment sweep refuses a superseded session too" do
    archived_replacement

    assert_no_enqueued_jobs only: AgentSessionJob do
      assert_equal false, DeploymentRecoveryJob.new.send(:continue_recovered_session, @session)
    end

    assert_equal "needs_input", @session.reload.status
  end

  # A human typing into the session outranks the refusal, and that is the escape
  # hatch that makes a narrow refusal safe: `continue_recovered_session` prefers a
  # queued user message over the automated prompt, before the claim is ever asked
  # for. Session 11924 had a human's "continue" sitting in it.
  test "a queued human message is still delivered to a superseded session" do
    archived_replacement
    @session.enqueued_messages.create!(content: "continue", position: 1)

    assert_enqueued_jobs 1, only: AgentSessionJob do
      assert_equal true, CleanupOrphanedSessionsJob.new.send(:continue_recovered_session, @session)
    end

    assert_equal "running", @session.reload.status
  end

  # ---------------------------------------------------------------------------
  # The shared admission predicate
  # ---------------------------------------------------------------------------

  test "claim_system_recovery_turn! reports :superseded when a replacement carries the work" do
    archived_replacement

    assert_equal :superseded, @session.claim_system_recovery_turn!
    assert_equal "needs_input", @session.reload.status
  end

  test "claim_system_recovery_turn! does not run its block for a superseded session" do
    archived_replacement
    ran = false

    assert_equal :superseded, @session.claim_system_recovery_turn! { ran = true }
    assert_equal false, ran,
      "the stale-metadata clear must not touch a row the claim is about to refuse"
    assert_equal "recovery", @session.reload.metadata["paused_by"],
      "a refused claim writes nothing of its own"
  end

  test "claim_system_recovery_turn! still claims a session with no replacement" do
    assert_equal :claimed, @session.claim_system_recovery_turn!
    assert_equal "running", @session.reload.status
  end

  test "claim_system_recovery_turn! still claims when the only replacement failed" do
    replacement_for(@session, status: :failed)

    assert_equal :claimed, @session.claim_system_recovery_turn!
  end

  # A replacement still doing the work is the same duplication arriving earlier.
  test "a replacement that is still live supersedes as well" do
    %i[running waiting needs_input].each do |status|
      session = superseded_session(status: status)
      assert_equal :superseded, session.claim_system_recovery_turn!,
        "a #{status} replacement is carrying the work too"
    end
  end

  # The more specific answers about the same row still win: the trash and the
  # live turn are what a caller has to hear first.
  test "the archived answer outranks the supersession" do
    archived_replacement
    stale = Session.find(@session.id)
    Session.where(id: @session.id).update_all(
      status: Session.statuses[:archived], archived_at: 1.hour.ago
    )

    assert_equal :archived, stale.claim_system_recovery_turn!
  end

  test "the not-resumable answer outranks the supersession" do
    archived_replacement
    stale = Session.find(@session.id)
    Session.where(id: @session.id).update_all(status: Session.statuses[:running])

    assert_equal :not_resumable, stale.claim_system_recovery_turn!
  end

  # ---------------------------------------------------------------------------
  # The relation is read strictly
  # ---------------------------------------------------------------------------

  test "a replaces_session that names no session refuses nothing" do
    replacement_for(@session, custom: { "replaces_session" => "not-an-id" })

    assert_equal :claimed, @session.claim_system_recovery_turn!
  end

  test "a blank replaces_session refuses nothing" do
    replacement_for(@session, custom: { "replaces_session" => "" })

    assert_equal :claimed, @session.claim_system_recovery_turn!
  end

  test "a session naming itself is not its own replacement" do
    @session.update!(custom_metadata: { "replaces_session" => @session.id })

    assert_empty @session.replacement_sessions
    assert_equal :claimed, @session.claim_system_recovery_turn!
  end

  test "a replacement of some other session refuses nothing here" do
    other = Session.create!(
      prompt: "Unrelated",
      agent_runtime: "claude_code",
      git_root: "https://github.com/test/repo.git",
      branch: "main",
      execution_provider: "local_filesystem",
      session_id: SecureRandom.uuid,
      status: :needs_input
    )
    replacement_for(other)

    assert_equal :claimed, @session.claim_system_recovery_turn!
  end

  # ---------------------------------------------------------------------------
  # The back-reference
  # ---------------------------------------------------------------------------

  test "creating a replacement stamps the replaced session with a back-reference" do
    replacement = archived_replacement

    @session.reload
    assert_equal replacement.id, @session.custom_metadata["replaced_by_session"]
    assert @session.custom_metadata["replaced_at"].present?
    assert_includes @session.custom_metadata["replaced_by_reason"], "infrastructure, not the task"
    assert @session.logs.any? { |log|
      log.content.include?("Session #{replacement.id} was created to replace this one")
    }, "expected the handoff on the replaced session's own timeline"
  end

  test "the back-reference is stamped when the convention is added after creation" do
    replacement = replacement_for(@session, custom: { "replaces_session" => nil })
    assert_nil @session.reload.custom_metadata["replaced_by_session"]

    replacement.update!(custom_metadata: { "replaces_session" => @session.id })

    assert_equal replacement.id, @session.reload.custom_metadata["replaced_by_session"]
  end

  test "stamping the same handoff twice writes one notice" do
    replacement = archived_replacement
    replacement.update!(
      custom_metadata: replacement.custom_metadata.merge("something_else" => "changed")
    )

    notices = @session.reload.logs.select { |log| log.content.include?("was created to replace this one") }
    assert_equal 1, notices.size
  end

  test "a replacement naming a session that does not exist stamps nothing and raises nothing" do
    missing_id = Session.maximum(:id).to_i + 10_000

    assert_nothing_raised do
      replacement_for(@session, custom: { "replaces_session" => missing_id })
    end
  end

  # ---------------------------------------------------------------------------
  # The rest of the recovery family
  # ---------------------------------------------------------------------------

  test "auto-continue after a job interruption refuses a superseded session" do
    replacement = archived_replacement

    assert_no_enqueued_jobs only: AgentSessionJob do
      AgentSessionJob.new.send(:auto_continue_after_interrupt, @session)
    end

    @session.reload
    assert_equal "needs_input", @session.status
    assert @session.logs.any? { |log| log.content.include?("handed to session #{replacement.id}") }
  end

  test "auto-restart after a hung process refuses a superseded session" do
    replacement = archived_replacement

    assert_no_enqueued_jobs only: AgentSessionJob do
      SessionRecoveryService.new(@session).send(:auto_restart_session, 12_345)
    end

    @session.reload
    assert_equal "needs_input", @session.status
    assert @session.logs.any? { |log| log.content.include?("handed to session #{replacement.id}") }
  end

  # The operator-facing one. A superseded session looks exactly like what a retry
  # is for, so the reason has to reach whoever pressed the button rather than be
  # swallowed into an empty result.
  test "the failed-session retry reports the supersession instead of retrying" do
    replacement = archived_replacement
    @session.update!(status: :failed)

    results = nil
    assert_no_enqueued_jobs only: AgentSessionJob do
      results = HealthMonitorService.new.retry_failed_sessions(session_ids: [ @session.id ])
    end

    assert_empty results[:retried]
    assert_equal 1, results[:skipped].size
    assert_includes results[:skipped].first[:reason], "session #{replacement.id}"
    assert_equal "failed", @session.reload.status
  end

  test "the failed-session retry still retries a session with no replacement" do
    @session.update!(status: :failed)

    results = nil
    assert_enqueued_jobs 1, only: AgentSessionJob do
      results = HealthMonitorService.new.retry_failed_sessions(session_ids: [ @session.id ])
    end

    assert_equal [ @session.id ], results[:retried]
  end

  private

  # A session whose work moved to a replacement that finished and archived — the
  # #801 shape.
  def archived_replacement
    replacement_for(@session, status: :archived)
  end

  # A fresh replaced session with a replacement in `status`, for the cases that
  # need more than one.
  def superseded_session(status:)
    replaced = Session.create!(
      prompt: "Implement something",
      agent_runtime: "claude_code",
      git_root: "https://github.com/test/repo.git",
      branch: "main",
      execution_provider: "local_filesystem",
      session_id: SecureRandom.uuid,
      status: :needs_input,
      metadata: { "working_directory" => @working_directory, "paused_by" => "recovery" }
    )
    replacement_for(replaced, status: status)
    replaced
  end

  # The replacement, carrying the convention exactly as a router writes it.
  def replacement_for(session, status: :archived, custom: {})
    metadata = {
      "replaces_session" => session.id,
      "replaces_reason" => "session #{session.id} failed before its first turn with " \
                           "Invalid cross-device link @ rb_file_s_rename — infrastructure, not the task"
    }.merge(custom).compact

    replacement = Session.create!(
      prompt: "Implement #683",
      agent_runtime: "claude_code",
      git_root: "https://github.com/test/repo.git",
      branch: "main",
      execution_provider: "local_filesystem",
      session_id: SecureRandom.uuid,
      status: :needs_input,
      custom_metadata: metadata
    )

    unless status == :needs_input
      Session.where(id: replacement.id).update_all(
        status: Session.statuses[status],
        archived_at: status == :archived ? 1.hour.ago : nil
      )
    end

    replacement.reload
  end
end
