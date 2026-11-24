# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"

class SessionStateEventJobTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    @session = Session.create!(agent_runtime: "claude_code", prompt: "work", git_root: "https://github.com/test/repo.git", branch: "main", title: "worker")
  end

  def states = SessionEvent.where(session: @session, name: SessionEvents::STATE_CHANGED).map { |event| event.data["state"] }

  test "failing and archiving are each published once" do
    @session.update_column(:status, Session.statuses["running"])
    perform_enqueued_jobs(only: SessionStateEventJob) { @session.reload.fail! }
    assert_equal [ "failed" ], states
    perform_enqueued_jobs(only: SessionStateEventJob) { @session.reload.archive! }
    assert_equal %w[failed archived], states
  end

  test "a retried job publishes its transition once" do
    2.times { SessionStateEventJob.perform_now("session_archived", @session.id, "key", 1.minute.ago.iso8601(3)) }
    assert_equal [ "archived" ], states
  end

  test "needs_input is announced after the settle window, and published only if it is still at rest" do
    @session.update_column(:status, Session.statuses["running"])
    assert_enqueued_with(job: SessionStateEventJob) { @session.reload.pause! }
    job = enqueued_jobs.find { |entry| entry["job_class"] == "SessionStateEventJob" }
    assert_in_delta SessionStateMachine::NEEDS_INPUT_SETTLE_WINDOW.from_now.to_f, job[:at], 5
    event_name, id, key, occurred_at, marker = job["arguments"]

    @session.update_column(:status, Session.statuses["running"])
    SessionStateEventJob.perform_now(event_name, id, key, occurred_at, marker)
    assert_empty states

    @session.update_column(:status, Session.statuses["needs_input"])
    SessionStateEventJob.perform_now(event_name, id, key, occurred_at, marker)
    assert_equal [ "needs_input" ], states
    assert_in_delta Time.iso8601(occurred_at).to_f, SessionEvent.last.occurred_at.to_f, 0.01, "when it happened, not when the job ran"
  end

  test "a status-summary fork publishes nothing" do
    Session.any_instance.stubs(:status_summary_fork?).returns(true)
    SessionStateEventJob.perform_now("session_archived", @session.id, "key", Time.current.iso8601(3))
    assert_empty states
  end

  test "a session that is gone publishes nothing" do
    assert_nil SessionStateEventJob.perform_now("session_archived", 0, "key", Time.current.iso8601(3))
  end
end
