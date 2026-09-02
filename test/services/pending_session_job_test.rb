# frozen_string_literal: true

require "test_helper"

# The question the automatic title and summary enqueues ask before adding a
# job: is one already queued and unclaimed for this session? Both jobs read the
# session at run time, so a second copy behind the first does no extra work and
# costs an `inference` thread — the bill that stacked 190 of them on 2026-09-02.
class PendingSessionJobTest < ActiveSupport::TestCase
  setup do
    GoodJob::Job.delete_all
  end

  def a_session
    Session.create!(git_root: "https://github.com/t/r.git", prompt: "work", status: :waiting)
  end

  def queue_a_job_for(session_id, job_class: "SessionTitleJob", **attributes)
    GoodJob::Job.create!(
      job_class: job_class, queue_name: "inference", scheduled_at: 1.minute.from_now,
      serialized_params: { "job_class" => job_class, "arguments" => [ session_id ] },
      **attributes
    )
  end

  test "nothing queued means nothing pending" do
    refute PendingSessionJob.queued?(SessionTitleJob, a_session.id)
  end

  test "an unfinished job for the session is pending" do
    session = a_session
    queue_a_job_for(session.id)

    assert PendingSessionJob.queued?(SessionTitleJob, session.id)
  end

  # A job that has started took its snapshot of the session when it started, so
  # a transition landing during its run is not covered by it: it does not count,
  # and the enqueue that follows is answered cheaply by the running job's claim.
  test "a job that is already performing is not pending" do
    session = a_session
    queue_a_job_for(session.id, performed_at: 5.seconds.ago)

    refute PendingSessionJob.queued?(SessionTitleJob, session.id)
  end

  # GoodJob resets `performed_at` when it re-enqueues a row for a retry, so a
  # job in retry back-off has not read anything yet and counts as queued.
  test "a job waiting to retry is pending" do
    session = a_session
    queue_a_job_for(session.id, performed_at: nil, scheduled_at: 30.seconds.from_now)

    assert PendingSessionJob.queued?(SessionTitleJob, session.id)
  end

  test "a finished job is not pending" do
    session = a_session
    queue_a_job_for(session.id, finished_at: 1.minute.ago)

    refute PendingSessionJob.queued?(SessionTitleJob, session.id)
  end

  test "another session's job is not this session's" do
    session = a_session
    queue_a_job_for(a_session.id)

    refute PendingSessionJob.queued?(SessionTitleJob, session.id)
  end

  test "the check is per job class" do
    session = a_session
    queue_a_job_for(session.id, job_class: "SessionStatusSummaryJob")

    refute PendingSessionJob.queued?(SessionTitleJob, session.id)
    assert PendingSessionJob.queued?(SessionStatusSummaryJob, session.id)
  end

  # A forced Regenerate is enqueued with keyword arguments after the id; the id
  # is still the first positional argument, so it counts as pending too — a
  # queued forced run covers the transition an automatic refresh would have.
  # The row is built from ActiveJob's own serializer so the SQL is tied to the
  # real argument layout rather than to a hand-written copy of it.
  test "a job with trailing keyword arguments still matches on the session id" do
    session = a_session
    GoodJob::Job.create!(
      job_class: "SessionStatusSummaryJob", queue_name: "inference", scheduled_at: Time.current,
      serialized_params: SessionStatusSummaryJob.new(session.id, force: true).serialize
    )

    assert PendingSessionJob.queued?(SessionStatusSummaryJob, session.id)
  end
end
