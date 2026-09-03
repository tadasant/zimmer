# frozen_string_literal: true

require "test_helper"

# Stopping a running session's turn on the spot, which is what makes a park
# mean something on a session that is not idle. The cases that matter are the ones
# where the turn does NOT end tidily: no process to kill, a turn that finished on
# its own while SIGTERM grace ran out, a pause callback that swallowed its sleep.
class Sessions::HaltRunningTurnTest < ActiveSupport::TestCase
  def session_in(status, **attrs)
    Session.create!({
      git_root: "https://github.com/t/r.git",
      prompt: "work",
      status: status,
      session_id: "cli-#{SecureRandom.hex(4)}",
      genesis: SessionGenesis::WEB_UI
    }.merge(attrs))
  end

  # The shape the callers set up: the wake (or the queue record) is armed first,
  # which is what writes pending_sleep on a running session.
  def running_with_pending_sleep(**attrs)
    session = session_in(:running, **attrs)
    session.update!(metadata: (session.metadata || {}).merge("pending_sleep" => true))
    session
  end

  test "lands the session in waiting, not in the operator's action queue" do
    session = running_with_pending_sleep

    result = Sessions::HaltRunningTurn.call(session: session)

    assert result.halted
    assert_equal :halted, result.reason
    assert session.reload.waiting?
    assert_nil session.metadata["pending_sleep"], "the intent was consumed, not left to fire later"
  end

  test "sleeps the session even when the pause callback's own sleep did not happen" do
    # execute_pending_sleep alerts rather than raises, so a session can come out
    # of `pause!` sitting in needs_input holding an armed wake. The belt-and-braces
    # sleep is what stops that from parking on the homepage as if it wanted a human.
    session = session_in(:running)

    result = Sessions::HaltRunningTurn.call(session: session)

    assert result.halted
    assert session.reload.waiting?
  end

  test "never writes the user-pause marker that would strand the wake it was armed with" do
    session = running_with_pending_sleep

    Sessions::HaltRunningTurn.call(session: session)

    # Trigger#reusable_session? refuses to deliver into a session carrying this.
    assert_not_equal "user", session.reload.metadata["paused_by"]
  end

  test "releases the job row so the orphan sweep does not read the session as owned" do
    session = running_with_pending_sleep(running_job_id: SecureRandom.uuid)

    Sessions::HaltRunningTurn.call(session: session)

    assert_nil session.reload.running_job_id
  end

  test "is a no-op on a session that is not running" do
    session = session_in(:needs_input)

    result = Sessions::HaltRunningTurn.call(session: session)

    assert_not result.halted
    assert_equal :not_running, result.reason
    assert session.reload.needs_input?
  end

  test "still pauses a session whose process is already gone" do
    session = running_with_pending_sleep(metadata: { "process_pid" => 999_999_999 })

    result = Sessions::HaltRunningTurn.call(session: session)

    assert result.halted, "a dead process is the state we were trying to reach anyway"
    assert session.reload.waiting?
  end

  test "reports the failure rather than raising when the session cannot be paused" do
    session = running_with_pending_sleep
    session.stub(:may_pause?, false) do
      result = Sessions::HaltRunningTurn.call(session: session)

      assert_not result.halted
      assert_equal :could_not_pause, result.reason
    end

    # Left running, holding the pending_sleep the caller armed — so the turn's own
    # end still sleeps it. Degraded, not stranded.
    assert session.reload.running?
    assert_equal true, session.metadata["pending_sleep"]
  end

  test "terminating a live process does not stop the pause from landing" do
    session = running_with_pending_sleep(metadata: { "process_pid" => 4242 })

    ProcessLifecycleManager.stub(:new, ->(**) { raise "no such process" }) do
      result = Sessions::HaltRunningTurn.call(session: session)

      assert result.halted, "termination is best effort; the state change is not"
    end

    assert session.reload.waiting?
  end
end
