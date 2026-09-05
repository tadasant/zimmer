# frozen_string_literal: true

require "test_helper"

# The decision in isolation: what gets queued, what deliberately does not, and the
# fact that every path leaves a record. The job-level reproduction of #983 — a
# prompt destroyed by EnqueuedMessageProcessorService and then dropped by the
# concurrency guard — lives in test/jobs/agent_session_job_test.rb.
class Sessions::RequeueSkippedPromptTest < ActiveSupport::TestCase
  setup do
    @session = Session.create!(
      prompt: "Original prompt",
      agent_runtime: "claude_code",
      git_root: "https://github.com/test/repo.git",
      branch: "main",
      execution_provider: "local_filesystem",
      session_id: SecureRandom.uuid,
      status: :running
    )
  end

  test "queues the prompt a skipped job was carrying" do
    assert_equal :queued, requeue("Wake up and report on the deploy")

    message = @session.enqueued_messages.pending.sole
    assert_equal "Wake up and report on the deploy", message.content
    assert_equal 1, message.position
    assert_equal "caller", message.origin
  end

  test "queues behind whatever is already in the queue" do
    @session.enqueued_messages.create!(content: "Earlier message", position: 1, status: "pending")

    assert_equal :queued, requeue("The wake that lost the race")

    assert_equal [ 1, 2 ], @session.enqueued_messages.pending.ordered.map(&:position)
    assert_equal "The wake that lost the race", @session.enqueued_messages.pending.ordered.last.content
  end

  test "carries the skipped job's attachments into the queued row" do
    images = [ { "path" => "/tmp/shot.png", "media_type" => "image/png" } ]
    files = [ { "path" => "/tmp/log.txt", "original_filename" => "log.txt", "size" => 12 } ]

    assert_equal :queued, requeue("Look at this", images: images, files: files)

    message = @session.enqueued_messages.pending.sole
    assert_equal "/tmp/shot.png", message.images.first["path"]
    assert_equal "log.txt", message.files.first["original_filename"]
  end

  test "stamps a merge-conflict notice so the delivery-time staleness re-read finds it" do
    prompt = AutomatedPrompts.merge_conflict_message("https://github.com/tadasant/zimmer/pull/1")

    assert_equal :queued, requeue(prompt)
    assert_equal "automated_merge_conflict", @session.enqueued_messages.pending.sole.origin
  end

  test "records on the session's own timeline that the prompt survived" do
    requeue("A prompt somebody is waiting on")

    log = @session.logs.reload.find { |l| l.content.include?("was NOT lost") }
    assert_not_nil log, "the loss being invisible is the bug; the save has to be visible too"
    assert_equal "warning", log.level
    assert_includes log.content, "A prompt somebody is waiting on"
  end

  # --- The four carve-outs, one test each ---

  test "drops a recovery nudge rather than queuing it behind the live turn" do
    assert_equal :nudge, requeue(AutomatedPrompts.system_recovery(reason: "deploy sweep"))

    assert_empty @session.enqueued_messages.pending
    assert_not_nil @session.logs.reload.find { |l| l.content.include?("automated nudge") },
      "a dropped nudge is still written down"
  end

  test "drops a heartbeat nudge for the same reason" do
    assert_equal :nudge, requeue(AutomatedPrompts::HEARTBEAT)
    assert_empty @session.enqueued_messages.pending
  end

  test "does not queue onto an archived session, where nothing would deliver the row" do
    @session.update!(status: :archived)

    assert_equal :archived, requeue("A prompt for a session in the trash")

    assert_empty @session.enqueued_messages.pending
    log = @session.logs.reload.find { |l| l.content.include?("in the trash") }
    assert_not_nil log
    assert_equal "warning", log.level
    assert_includes log.content, "A prompt for a session in the trash"
  end

  test "does not queue onto a status-summary fork, which takes exactly one turn" do
    @session.merge_metadata!(SessionStatusSummaryGenerator::FORK_MARKER => 12345)

    assert_equal :summary_fork, requeue("Not the summary request")
    assert_empty @session.enqueued_messages.pending
  end

  test "does not queue a second copy of a prompt already in the queue" do
    @session.enqueued_messages.create!(content: "The same wake", position: 1, status: "pending")

    assert_equal :already_queued, requeue("The same wake")

    assert_equal 1, @session.enqueued_messages.pending.count
    assert_not_nil @session.logs.reload.find { |l| l.content.include?("already queued") }
  end

  test "a promptless job has nothing to save and writes nothing" do
    assert_equal :no_prompt, requeue(nil)

    assert_empty @session.enqueued_messages.pending
    assert_empty @session.logs.reload
  end

  test "a queue write that fails is reported rather than swallowed" do
    EnqueuedMessage.any_instance.stubs(:save!).raises(ActiveRecord::StatementInvalid, "boom")

    assert_equal :failed, requeue("A prompt that could not be saved")

    log = @session.logs.reload.find { |l| l.content.include?("could NOT be queued") }
    assert_not_nil log, "a prompt lost to a database error must not be lost silently too"
    assert_equal "error", log.level
  end

  test "decides from the row as it is now, not the stale object the job carried" do
    stale = Session.find(@session.id)
    @session.update!(status: :archived)

    assert_equal :archived, Sessions::RequeueSkippedPrompt.call(stale, prompt: "Too late")
    assert_empty @session.enqueued_messages.pending
  end

  private

  def requeue(prompt, images: nil, files: nil)
    Sessions::RequeueSkippedPrompt.call(
      @session, prompt: prompt, holder_job_id: SecureRandom.uuid, images: images, files: files
    )
  end
end
