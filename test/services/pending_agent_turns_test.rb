# frozen_string_literal: true

require "test_helper"

# The question both repair sweeps ask before they enqueue anything: is an
# AgentSessionJob still going to run for this session? Miss a job that is merely
# late and the sweep puts a second agent against one clone; report a job that no
# longer exists and the sweep stands down on a session nothing will ever start.
#
# Pinned here rather than only through its two callers, because the two forms
# have to agree: `for` is used after a bounded read, `without_a_pending_turn` is
# the same predicate pushed into SQL so a bounded read cannot be starved by rows
# it was only going to discard.
class PendingAgentTurnsTest < ActiveSupport::TestCase
  setup do
    GoodJob::Job.delete_all
  end

  def a_session
    Session.create!(git_root: "https://github.com/t/r.git", prompt: "work", status: :waiting)
  end

  # `scheduled_at` in the PAST by default, which is what GoodJob writes for an
  # ordinary immediate `perform_later`: the row is ready and the next poll takes
  # it. A future value is the deliberate deferral (a spot re-check, a clone
  # backoff) and the tests that mean one pass it explicitly.
  def queue_a_turn_for(session_id, job_class: "AgentSessionJob", scheduled_at: 1.minute.ago, **attributes)
    GoodJob::Job.create!(
      job_class: job_class, queue_name: "agents", scheduled_at: scheduled_at,
      serialized_params: { "job_class" => job_class, "arguments" => [ session_id ] },
      **attributes
    )
  end

  test "an empty id list asks the database nothing" do
    assert_equal Set.new, PendingAgentTurns.for([])
  end

  test "a session with an unfinished job is reported, and its neighbour is not" do
    with_a_job = a_session
    without = a_session
    queue_a_turn_for(with_a_job.id)

    assert_equal Set[with_a_job.id], PendingAgentTurns.for([ with_a_job.id, without.id ])
  end

  # `arguments[0]` comes back from jsonb as a string; a Set of strings would
  # never match a Set of ids and every session would read as abandoned.
  test "the ids come back as integers" do
    session = a_session
    queue_a_turn_for(session.id)

    assert_equal [ Integer ], PendingAgentTurns.for([ session.id ]).map(&:class)
  end

  test "a finished job is not a pending turn" do
    session = a_session
    queue_a_turn_for(session.id, finished_at: 1.minute.ago)

    assert_equal Set.new, PendingAgentTurns.for([ session.id ])
  end

  # A job that has started but not finished is the window a repair sweep is most
  # likely to land in: `running_job_id` is written from inside `perform`, so the
  # session's own row still looks abandoned while the job is very much alive.
  test "a job that is mid-execution is a pending turn" do
    session = a_session
    queue_a_turn_for(session.id, performed_at: 1.minute.ago)

    assert_equal Set[session.id], PendingAgentTurns.for([ session.id ])
  end

  test "another job class against the same session is not a pending turn" do
    session = a_session
    queue_a_turn_for(session.id, job_class: "SessionTitleJob")

    assert_equal Set.new, PendingAgentTurns.for([ session.id ])
  end

  # .split is the same population told apart by whether a worker has picked the
  # turn up. RunningTurns needs the difference; the sweeps do not.
  test "split tells a turn on a worker apart from one still in the queue" do
    working = a_session
    queued = a_session
    queue_a_turn_for(working.id, performed_at: 1.minute.ago)
    queue_a_turn_for(queued.id)

    reading = PendingAgentTurns.split([ working.id, queued.id ])

    assert_equal Set[working.id], reading.on_a_worker
    assert_equal Set[queued.id], reading.queued
    assert_equal Set.new, reading.scheduled
  end

  # A job parked on a future `scheduled_at` is a spot-gate re-check or a clone
  # backoff: a turn somebody deliberately deferred, whose owner is the thing that
  # deferred it. Counting it as "queued for a worker" would put every spot-held
  # session into the /inference queue figure and name GoodJob as the resume owner
  # of a session the spot ladder owns.
  test "split keeps a turn parked on a future scheduled_at out of the ready queue" do
    deferred = a_session
    queue_a_turn_for(deferred.id, scheduled_at: 10.minutes.from_now)

    reading = PendingAgentTurns.split([ deferred.id ])

    assert_equal Set.new, reading.on_a_worker
    assert_equal Set.new, reading.queued
    assert_equal Set[deferred.id], reading.scheduled
  end

  # .for is still the sweeps' question — "is ANY turn coming for this session" —
  # so it unions all three buckets. A deferred re-check is very much a turn that
  # is coming, and a sweep that enqueued a second one would duplicate it.
  test "for counts a turn parked on a future scheduled_at" do
    deferred = a_session
    queue_a_turn_for(deferred.id, scheduled_at: 10.minutes.from_now)

    assert_equal Set[deferred.id], PendingAgentTurns.for([ deferred.id ])
  end

  # A re-check racing a recovery leaves a session with two unfinished jobs. It is
  # on a worker if either of them is, and it must appear in exactly one set or a
  # caller adding the sizes double-counts it.
  test "split puts a session with both a started and a queued job on a worker only" do
    session = a_session
    queue_a_turn_for(session.id, performed_at: 1.minute.ago)
    queue_a_turn_for(session.id)

    reading = PendingAgentTurns.split([ session.id ])

    assert_equal Set[session.id], reading.on_a_worker
    assert_equal Set.new, reading.queued
    assert_equal Set.new, reading.scheduled
  end

  test "split asks the database nothing for an empty id list" do
    reading = PendingAgentTurns.split([])

    assert_equal Set.new, reading.on_a_worker
    assert_equal Set.new, reading.queued
    assert_equal Set.new, reading.scheduled
  end

  test "the SQL form selects exactly the sessions the set form omits" do
    with_a_job = a_session
    without = a_session
    queue_a_turn_for(with_a_job.id)

    ids = PendingAgentTurns.without_a_pending_turn(
      Session.where(id: [ with_a_job.id, without.id ])
    ).pluck(:id)

    assert_equal [ without.id ], ids
  end

  test "the SQL form agrees with the set form on a finished job" do
    session = a_session
    queue_a_turn_for(session.id, finished_at: 1.minute.ago)

    assert_equal [ session.id ],
      PendingAgentTurns.without_a_pending_turn(Session.where(id: session.id)).pluck(:id)
  end
end
