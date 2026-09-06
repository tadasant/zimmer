# frozen_string_literal: true

require "test_helper"
require "tmpdir"

# An accepted follow-up survives the resume that races it (tadasant/zimmer#1023).
#
# The reported failure was silent from both ends. A `follow_up` was accepted,
# acknowledged to its sender and moved the target to `running` — and then a
# recovery path resumed the target first, carrying the generic `SYSTEM_RECOVERY`
# nudge, and no turn for the prompt ever appeared in the target's transcript. The
# sender saw a success result; the recipient saw an ordinary interruption notice.
#
# `pending_follow_up_prompt` is the marker every resume path reads to prefer a
# real prompt over the nudge, and the defect had two halves:
#
# 1. Two of the three routes that accept a follow-up into an idle session —
#    `Mcp::Tools::ActionSession#direct_follow_up` and
#    `Api::V1::SessionsController#follow_up` — never stamped it, so the prompt
#    lived only as the argument of the job they enqueued.
# 2. `AgentSessionJob#handle_interrupt_error` throws that job away and resumes the
#    session on a nudge, without preserving the argument. One copy, destroyed.
#
# These tests cover the producers, the interrupt path, the two sweep-driven
# continuation paths, and the opposite failure — a prompt the session already
# acted on being replayed.
class FollowUpSurvivesRecoveryResumeTest < ActiveJob::TestCase
  PROMPT = "Rebase the branch onto main and finish the PR"

  setup do
    @working_directory = Dir.mktmpdir
    @session = Session.create!(
      prompt: "Open a PR",
      status: :needs_input,
      git_root: "https://github.com/test/repo.git",
      branch: "main",
      execution_provider: "local_filesystem",
      session_id: SecureRandom.uuid,
      metadata: { "working_directory" => @working_directory }
    )
  end

  teardown { FileUtils.remove_entry(@working_directory) if File.directory?(@working_directory) }

  # The prompt each AgentSessionJob this test enqueued was told to deliver.
  def enqueued_prompts
    enqueued_jobs.select { |job| job["job_class"] == "AgentSessionJob" }
                 .map { |job| job["arguments"][1] }
  end

  def interrupt!(job)
    @session.update!(running_job_id: job.job_id)
    job.send(
      :handle_interrupt_error,
      GoodJob::InterruptError.new("Interrupted after starting perform at '2026-09-05 17:40:00 UTC'")
    )
    @session.reload
  end

  # ---------------------------------------------------------------------------
  # The producers: an accepted follow-up is on the row, not only in a job argument
  # ---------------------------------------------------------------------------

  test "an MCP follow-up to an idle session stamps the prompt on the row" do
    tool = Mcp::Tools::ActionSession.new(context: Mcp::Context.new(tool_groups: "sessions"))

    perform_enqueued_jobs(only: ->(_job) { false }) do
      tool.call("action" => "follow_up", "session_id" => @session.id, "prompt" => PROMPT)
    end

    assert_equal PROMPT, @session.reload.metadata["pending_follow_up_prompt"],
      "the prompt must exist somewhere a resume path can read it, not only as a job argument"
    assert_equal "running", @session.status,
      "a reader who sees the marker must be guaranteed to also see running"
  end

  # ---------------------------------------------------------------------------
  # Resume path 1: the interrupt handler's own auto-continue
  # ---------------------------------------------------------------------------

  # THE REPRODUCTION. On main this enqueues the SYSTEM_RECOVERY nudge and the
  # prompt is nowhere: not on the row, not in the queue, not in any job argument.
  test "an interrupted follow-up job's prompt is delivered by the recovery turn it triggers" do
    @session.update!(status: :running)
    interrupt!(AgentSessionJob.new(@session.id, PROMPT))

    assert_equal PROMPT, @session.metadata["pending_follow_up_prompt"],
      "the interrupted job's prompt must be handed back to the session before it is paused"
    assert_includes enqueued_prompts, PROMPT,
      "the turn recovery starts must carry the follow-up, not only the nudge"
    assert_not_includes enqueued_prompts, nil
    assert @session.logs.any? { |log| log.content.include?("was NOT lost") && log.content.include?(PROMPT) },
      "the hand-back has to be visible on the session's own timeline"
  end

  # The other half of #1023's "done": where the prompt cannot be preserved, the
  # loss must be written down rather than silent.
  test "a prompt that cannot be stamped is recorded on the timeline instead" do
    @session.update!(
      status: :running,
      metadata: @session.metadata.merge("pending_follow_up_prompt" => "An earlier undelivered prompt")
    )

    interrupt!(AgentSessionJob.new(@session.id, PROMPT))

    assert_equal "An earlier undelivered prompt", @session.metadata["pending_follow_up_prompt"],
      "an earlier undelivered prompt must not be overwritten to save a later one"
    assert @session.logs.any? { |log| log.content.include?("already holding an earlier undelivered prompt") },
      "the refusal has to name itself where 'why did nothing happen' is asked"
    assert @session.logs.any? { |log| log.content.include?(PROMPT) },
      "the refused prompt has to be recoverable from the log line"
  end

  # THE OPPOSITE FAILURE (#1009's direction). `active_follow_up_prompt` is where
  # the follow-up arm puts this turn's prompt just before it spawns, so a prompt
  # found there has reached the agent. Re-stamping it would replay a message the
  # session already acted on — just as silent, and worse.
  test "a prompt already handed to the runtime is not replayed" do
    @session.update!(
      status: :running,
      metadata: @session.metadata.merge(
        # What build_prompt_with_goal stores: the raw prompt with the goal block appended.
        "active_follow_up_prompt" => "#{PROMPT}\n\nThe user has indicated the goal for this task is: Ship it."
      )
    )

    interrupt!(AgentSessionJob.new(@session.id, PROMPT))

    assert_nil @session.metadata["pending_follow_up_prompt"],
      "a prompt the agent already has must not be stamped for redelivery"
    assert_equal [], @session.enqueued_messages.pending.to_a
  end

  # A leftover from an earlier turn names some other prompt, and must not be read
  # as this one having been delivered.
  test "an active prompt left over from an earlier turn does not refuse this one" do
    @session.update!(
      status: :running,
      metadata: @session.metadata.merge("active_follow_up_prompt" => "A prompt from two turns ago")
    )

    interrupt!(AgentSessionJob.new(@session.id, PROMPT))

    assert_equal PROMPT, @session.metadata["pending_follow_up_prompt"]
  end

  test "an interrupted job carrying only a nudge stamps nothing" do
    @session.update!(status: :running)
    interrupt!(AgentSessionJob.new(@session.id, AutomatedPrompts::SYSTEM_RECOVERY))

    assert_nil @session.metadata["pending_follow_up_prompt"],
      "stamping a nudge so the next nudge can deliver it is a no-op with extra steps"
  end

  test "an interrupted monitoring job has no prompt to preserve" do
    @session.update!(status: :running)
    interrupt!(AgentSessionJob.new(@session.id, nil, { "resume_monitoring" => true }))

    assert_nil @session.metadata["pending_follow_up_prompt"]
  end

  test "a prompt already in the durable queue is not stamped a second time" do
    @session.update!(status: :running)
    @session.enqueued_messages.create!(content: PROMPT, position: 1, status: "pending")

    interrupt!(AgentSessionJob.new(@session.id, PROMPT))

    assert_nil @session.metadata["pending_follow_up_prompt"],
      "two live copies of one prompt is two turns"
    assert_equal 1, @session.enqueued_messages.pending.count
    assert @session.logs.any? { |log| log.content.include?("already queued on this session") }
  end

  # ---------------------------------------------------------------------------
  # Resume paths 2 and 3: the orphan-cleanup and deployment-recovery sweeps
  # ---------------------------------------------------------------------------

  test "orphan cleanup delivers a stamped follow-up instead of the recovery nudge" do
    recovery_pause!(PROMPT)

    CleanupOrphanedSessionsJob.perform_now

    assert_equal [ PROMPT ], enqueued_prompts,
      "the sweep must resume the session on the prompt it is holding, not on a nudge"
    assert @session.reload.logs.any? { |log|
      log.content.include?("delivering the follow-up prompt it was still holding")
    }, "the timeline has to say which prompt the recovery turn carries"
  end

  test "deployment recovery delivers a stamped follow-up instead of the recovery nudge" do
    recovery_pause!(PROMPT)

    DeploymentRecoveryJob.perform_now

    assert_equal [ PROMPT ], enqueued_prompts
  end

  test "a recovery sweep with nothing stamped still sends the nudge" do
    recovery_pause!(nil)

    CleanupOrphanedSessionsJob.perform_now

    assert_equal 1, enqueued_prompts.length
    assert AutomatedPrompts.system_recovery?(enqueued_prompts.first),
      "the nudge is still the right answer when the session is holding nothing"
  end

  # A queued message keeps its precedence — and the stamped prompt is not the
  # casualty. The follow-up arm reads `pending_follow_up_prompt || follow_up_prompt`,
  # so a marker left standing would be delivered *instead* of the message the
  # processor just claimed, whose queue row is destroyed inside the same
  # transaction. Both survive: the message takes this turn and the held prompt
  # goes to the tail of the queue.
  test "a queued message still outranks a stamped prompt, and neither is lost" do
    recovery_pause!(PROMPT)
    @session.enqueued_messages.create!(content: "Actually, do this first", position: 1, status: "pending")

    CleanupOrphanedSessionsJob.perform_now
    @session.reload

    assert @session.logs.any? { |log| log.content.include?("delivering queued user message") },
      "the queued-message branch must still win"
    assert_equal [ "Actually, do this first" ], enqueued_prompts,
      "the turn must carry the claimed message, not the prompt the row was holding"
    assert_nil @session.metadata["pending_follow_up_prompt"],
      "the queue owns the held prompt now, so the row must stop holding it too"
    assert_equal [ PROMPT ], @session.enqueued_messages.pending.map(&:content),
      "the held prompt must be delivered after the message that displaced it"
  end

  # The marker holding the very prompt that was just claimed is the ordinary
  # requeue-then-drain path, and must not put a second copy back in the queue.
  test "a stamped prompt identical to the claimed message is released, not requeued" do
    recovery_pause!(PROMPT)
    @session.enqueued_messages.create!(content: PROMPT, position: 1, status: "pending")

    CleanupOrphanedSessionsJob.perform_now
    @session.reload

    assert_equal [ PROMPT ], enqueued_prompts
    assert_nil @session.metadata["pending_follow_up_prompt"]
    assert_equal [], @session.enqueued_messages.pending.to_a,
      "one prompt must not become two turns"
  end

  # The marker survives the sweep's own metadata clearing. If it did not, the
  # branch above would hand the prompt to a job and then delete the only copy.
  test "the recovery sweep does not clear the stamped prompt when it claims the turn" do
    assert_not_includes Session::STALE_RETRY_METADATA_KEYS, "pending_follow_up_prompt",
      "an undelivered prompt is not retry state and must not be cleared on resume"
  end

  private

  # Put the session where both sweeps look: recovery-paused, optionally holding an
  # undelivered prompt.
  def recovery_pause!(pending_prompt)
    metadata = @session.metadata.merge("paused_by" => "recovery")
    metadata["pending_follow_up_prompt"] = pending_prompt if pending_prompt
    @session.update!(status: :needs_input, running_job_id: nil, metadata: metadata)
  end
end
