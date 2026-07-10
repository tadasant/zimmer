# frozen_string_literal: true

require "test_helper"

class HeartbeatSweepJobTest < ActiveJob::TestCase
  def make_session(status:, **attrs)
    Session.create!(
      git_root: "https://github.com/test/repo.git",
      prompt: "Test prompt",
      status: status,
      **attrs
    )
  end

  test "nudges a needs_input session that is due for a beat" do
    session = make_session(status: 2, heartbeat_enabled: true, heartbeat_last_beat_at: nil)

    assert_enqueued_with(job: AgentSessionJob) do
      HeartbeatSweepJob.perform_now
    end

    session.reload
    assert session.running?, "needs_input session should be resumed to running"
    assert_equal AutomatedPrompts::HEARTBEAT, session.prompt
    assert_not_nil session.heartbeat_last_beat_at
    assert session.logs.where("content LIKE ?", "%Heartbeat nudged%").exists?
  end

  test "does not nudge a running session but records the beat" do
    session = make_session(status: 0, heartbeat_enabled: true, heartbeat_last_beat_at: nil)

    assert_no_enqueued_jobs only: AgentSessionJob do
      HeartbeatSweepJob.perform_now
    end

    session.reload
    assert session.running?
    assert_not_nil session.heartbeat_last_beat_at
  end

  test "does not nudge a waiting session but records the beat" do
    session = make_session(status: 1, heartbeat_enabled: true, heartbeat_last_beat_at: nil)

    assert_no_enqueued_jobs only: AgentSessionJob do
      HeartbeatSweepJob.perform_now
    end

    session.reload
    assert session.waiting?
    assert_not_nil session.heartbeat_last_beat_at
  end

  test "does not disable heartbeat for a failed session (restartable) but records the beat" do
    session = make_session(status: 4, heartbeat_enabled: true, heartbeat_last_beat_at: nil)

    assert_no_enqueued_jobs only: AgentSessionJob do
      HeartbeatSweepJob.perform_now
    end

    session.reload
    assert session.heartbeat_enabled, "failed sessions can be restarted, so the heartbeat stays enabled"
    assert_not_nil session.heartbeat_last_beat_at
  end

  test "auto-disables heartbeat for an archived session" do
    session = make_session(status: 3, heartbeat_enabled: true, heartbeat_last_beat_at: nil)

    HeartbeatSweepJob.perform_now

    session.reload
    assert_not session.heartbeat_enabled
  end

  test "skips sessions that are not yet due for a beat" do
    session = make_session(
      status: 2,
      heartbeat_enabled: true,
      heartbeat_interval_seconds: 60,
      heartbeat_last_beat_at: 10.seconds.ago
    )

    assert_no_enqueued_jobs only: AgentSessionJob do
      HeartbeatSweepJob.perform_now
    end

    session.reload
    assert session.needs_input?, "session should be untouched when not due"
  end

  test "beats a session whose interval has elapsed" do
    session = make_session(
      status: 2,
      heartbeat_enabled: true,
      heartbeat_interval_seconds: 60,
      heartbeat_last_beat_at: 90.seconds.ago
    )

    assert_enqueued_with(job: AgentSessionJob) do
      HeartbeatSweepJob.perform_now
    end

    assert session.reload.running?
  end

  test "ignores sessions with heartbeat disabled" do
    session = make_session(status: 2, heartbeat_enabled: false, heartbeat_last_beat_at: nil)

    assert_no_enqueued_jobs only: AgentSessionJob do
      HeartbeatSweepJob.perform_now
    end

    assert session.reload.needs_input?
  end

  test "does not nudge a needs_input session blocked on an elicitation" do
    # An elicitation-blocked session sits in needs_input WITH its agent process
    # still alive — nudging would spawn a second process and orphan the elicitation.
    session = make_session(status: 2, heartbeat_enabled: true, heartbeat_last_beat_at: nil)
    session.update_column(:metadata, session.metadata.merge("blocked_on_elicitation" => true))

    assert_no_enqueued_jobs only: AgentSessionJob do
      HeartbeatSweepJob.perform_now
    end

    session.reload
    assert session.needs_input?, "elicitation-blocked session must not be resumed"
    assert_not_nil session.heartbeat_last_beat_at, "the beat is still anchored"
  end

  test "does not nudge a needs_input session with a pending enqueued message" do
    session = make_session(status: 2, heartbeat_enabled: true, heartbeat_last_beat_at: nil)
    session.enqueued_messages.create!(content: "queued work", position: 1, status: "pending")

    assert_no_enqueued_jobs only: AgentSessionJob do
      HeartbeatSweepJob.perform_now
    end

    assert session.reload.needs_input?, "session with queued work must not be nudged"
  end

  test "is idempotent: a second immediate sweep does not stack a second nudge" do
    make_session(status: 2, heartbeat_enabled: true, heartbeat_last_beat_at: nil)

    HeartbeatSweepJob.perform_now # first beat: nudges -> running
    # Second sweep runs immediately: the session is now running and its
    # last_beat_at is fresh, so no second nudge is enqueued.
    assert_no_enqueued_jobs only: AgentSessionJob do
      HeartbeatSweepJob.perform_now
    end
  end
end
