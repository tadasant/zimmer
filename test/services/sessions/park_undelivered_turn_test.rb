# frozen_string_literal: true

require "test_helper"

# The four conditions the park decides on, one test each, plus the two things it
# writes that other code reads. The job-level reproduction of #439 lives in
# test/jobs/agent_session_job_undelivered_turn_test.rb; this file is about the
# decision in isolation, where each condition can be falsified on its own.
class Sessions::ParkUndeliveredTurnTest < ActiveSupport::TestCase
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
    @error = AirPrepareService::AirPrepareError.new(
      "AIR prepare failed (exit status 1): Error: ENOENT: no such file or directory, open '/clone/.mcp.json'"
    )
  end

  test "parks a running session whose unspawned turn was carrying a prompt" do
    assert park, "the whole case of #439"

    @session.reload
    assert_equal "needs_input", @session.status
    assert_equal Sessions::ParkUndeliveredTurn::FAILURE_REASON, @session.metadata["failure_reason"]
    assert_equal "AirPrepareService::AirPrepareError", @session.metadata["exception_class"]
    assert_includes @session.metadata["exception_message"], ".mcp.json"
    assert_equal "Please continue", @session.metadata["pending_follow_up_prompt"]
    assert_nil @session.running_job_id
  end

  test "declines once a process existed — that turn is a runtime fault with a transcript to read" do
    refute park(spawned: true)
    assert_equal "running", @session.reload.status
    assert_nil @session.metadata["failure_reason"], "a declined park must write nothing at all"
  end

  test "declines a promptless turn — nothing was undelivered, so nobody is waiting" do
    refute park(prompt: nil)
    assert_equal "running", @session.reload.status
  end

  test "declines a session that is not running, since `pause` transitions from running only" do
    @session.update!(status: :waiting)
    refute park
    assert_equal "waiting", @session.reload.status
  end

  test "declines a status-summary fork, which must never take a slot in the action queue" do
    @session.merge_metadata!(SessionStatusSummaryGenerator::FORK_MARKER => 99)
    refute park
    assert_equal "running", @session.reload.status
  end

  # The marker is a promise that a sweep will continue the session. A boot that is
  # deterministically broken would just fail again on every one of those attempts
  # and end in the same silence #439 is about.
  test "leaves no recovery marker, so no sweep auto-continues the park" do
    park
    assert_nil @session.reload.metadata["paused_by"]
  end

  test "reads the row rather than the caller's stale copy of it" do
    # The setup this park sits at the end of runs for minutes; a session archived
    # in that window must not be pulled back out of the trash by the park.
    stale = Session.find(@session.id)
    Session.where(id: @session.id).update_all(
      status: Session.statuses[:archived], archived_at: Time.current
    )

    refute Sessions::ParkUndeliveredTurn.call(
      stale, error: @error, prompt: "Please continue", spawned: false
    )
    assert_equal "archived", @session.reload.status
  end

  # The park must never be the thing that breaks the failure path: the caller's
  # `fail!` has to run when it answers false.
  test "answers false when the park itself raises" do
    @session.stubs(:reload).raises(ActiveRecord::ConnectionNotEstablished, "database is gone")

    refute Sessions::ParkUndeliveredTurn.call(
      @session, error: @error, prompt: "Please continue", spawned: false
    )
  end

  test "a long exception message is capped rather than bloating the row" do
    park(error: AirPrepareService::AirPrepareError.new("x" * 50_000))

    message = @session.reload.metadata["exception_message"]
    assert_operator message.length, :<=, AgentSessionJob::EXCEPTION_MESSAGE_MAX_CHARS
    assert_includes message, "x" * 1_000, "the head of the message must survive the cap"
  end

  # ---------------------------------------------------------------------------
  # What the parked row means to the surfaces that read it
  # ---------------------------------------------------------------------------

  test "the parked session reports itself as holding a failure worth rendering" do
    park

    @session.reload
    assert @session.parked_undelivered_turn?
    assert @session.shows_failure_details?,
           "the failure block is gated on this — a park that hides its own reason is the bug again"
    assert @session.failed_before_initial_prompt?,
           "nothing ran, so a restart must re-send the original prompt rather than a recovery nudge"
  end

  test "the failure summary says what happened and what to do, not just the reason's name" do
    park

    summary = @session.reload.failure_summary
    assert_includes summary, "before the agent started"
    assert_includes summary, "AirPrepareService::AirPrepareError"
    assert_includes summary, "continue the session to send it again"
    refute_equal "Undelivered turn", summary
  end

  test "an ordinary needs_input session is not mistaken for a parked one" do
    @session.pause!
    refute @session.reload.parked_undelivered_turn?
    refute @session.shows_failure_details?
  end

  private

  def park(prompt: "Please continue", spawned: false, error: @error)
    Sessions::ParkUndeliveredTurn.call(@session, error: error, prompt: prompt, spawned: spawned)
  end
end
