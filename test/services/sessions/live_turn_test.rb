# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"

# The shared "is this conversation live?" predicate behind the two #400 guards.
class Sessions::LiveTurnTest < ActiveSupport::TestCase
  setup do
    Log.any_instance.stubs(:broadcast_append_to_timeline)
    Session.any_instance.stubs(:broadcast_status_change)
    GoodJob::Job.where(job_class: "AgentSessionJob").delete_all
    GoodJob::Process.delete_all
  end

  teardown do
    Mocha::Mockery.instance.teardown
    GoodJob::Process.delete_all
  end

  def session(status: :running)
    Session.create!(
      git_root: "https://github.com/tadasant/zimmer.git",
      prompt: "work",
      status: status,
      agent_runtime: "claude_code",
      session_id: SecureRandom.uuid
    )
  end

  # A GoodJob capsule that is alive: registered and refreshing its heartbeat.
  def live_process = GoodJob::Process.create!(state: { "hostname" => "worker-1" })

  # One that was SIGKILLed. Its row survives — nothing deletes it until a later
  # capsule runs GoodJob::Process.cleanup — but the heartbeat stopped.
  def dead_process
    GoodJob::Process.create!(state: { "hostname" => "worker-1" })
      .tap { |p| p.update_column(:updated_at, (GoodJob::Process::EXPIRED_INTERVAL.to_i + 60).seconds.ago) }
  end

  def enqueue_turn!(target, **attrs)
    GoodJob::Job.create!({
      active_job_id: SecureRandom.uuid, queue_name: "agents", job_class: "AgentSessionJob",
      serialized_params: { "arguments" => [ target.id ] }, scheduled_at: 2.minutes.ago
    }.merge(attrs))
  end

  # A turn a live capsule is actually executing.
  def on_a_worker!(target)
    enqueue_turn!(target, performed_at: 1.minute.ago, locked_at: 1.minute.ago, locked_by_id: live_process.id)
  end

  test "a running session with a turn on a worker is in flight" do
    target = session
    on_a_worker!(target)

    assert Sessions::LiveTurn.in_flight?(target)
    assert Sessions::LiveTurn.coming?(target)
  end

  test "a turn merely queued is coming but not in flight" do
    target = session
    enqueue_turn!(target)

    assert_not Sessions::LiveTurn.in_flight?(target),
      "nothing is executing, so an archive destroys no work — it cancels a turn, which is what the caller asked for"
    assert Sessions::LiveTurn.coming?(target)
  end

  # The correction that keeps the fleet-repair sweeps working: a session whose
  # worker was SIGKILLed keeps `performed_at` set and `finished_at` null
  # forever. Nothing is executing, so archiving it destroys nothing — and a
  # stuck session is exactly the one a sweep needs to be able to archive.
  test "a turn whose worker is gone is neither in flight nor coming" do
    target = session
    enqueue_turn!(target, performed_at: 1.minute.ago, locked_at: 1.minute.ago, locked_by_id: dead_process.id)

    assert_not Sessions::LiveTurn.in_flight?(target)
    assert_not Sessions::LiveTurn.coming?(target)
    assert_nil Sessions::LiveTurn.describe(target)
  end

  # The same corpse in its other shape: GoodJob::Process.cleanup nulls
  # locked_by_id on behalf of a capsule that died, leaving a started, unlocked
  # row that JobLiveness calls :interrupted.
  test "a turn that lost its lock mid-perform is neither" do
    target = session
    enqueue_turn!(target, performed_at: 15.seconds.ago, locked_by_id: nil)

    assert_not Sessions::LiveTurn.in_flight?(target)
    assert_not Sessions::LiveTurn.coming?(target)
  end

  test "a running session with no job at all is neither" do
    target = session

    assert_not Sessions::LiveTurn.in_flight?(target)
    assert_not Sessions::LiveTurn.coming?(target)
  end

  # The status is conjoined deliberately: a finished job row can outlive the
  # transition, and a session at rest is not one an archive interrupts.
  test "a session at rest is never in flight, whatever the queue says" do
    target = session(status: :needs_input)
    on_a_worker!(target)

    assert_not Sessions::LiveTurn.in_flight?(target)
    assert_not Sessions::LiveTurn.coming?(target)
  end

  test "both undelivered-prompt markers count" do
    queued = session(status: :needs_input)
    queued.enqueued_messages.create!(content: "the new prompt", position: 1, status: "pending")
    assert Sessions::LiveTurn.undelivered_prompt?(queued)

    stamped = session(status: :running)
    stamped.merge_metadata!("pending_follow_up_prompt" => "the new prompt")
    assert Sessions::LiveTurn.undelivered_prompt?(stamped)
  end

  test "a claimed or retired message is not an undelivered prompt" do
    target = session(status: :needs_input)
    target.enqueued_messages.create!(content: "in flight", position: 1, status: "processing")
    target.enqueued_messages.create!(content: "retired", position: 2, status: "undelivered")

    assert_not Sessions::LiveTurn.undelivered_prompt?(target)
  end

  # The asymmetry that matters: a guard that refuses too often is recoverable,
  # a guard that lets a kill through is not.
  test "an unreadable agents queue reads as a live turn" do
    target = session
    Sessions::LiveTurn.stubs(:unfinished_turns).raises(ActiveRecord::StatementInvalid, "boom")

    assert Sessions::LiveTurn.in_flight?(target)
    assert Sessions::LiveTurn.coming?(target)
  end

  test "describe names the narrower reason, and adds the waiting prompt" do
    target = session
    on_a_worker!(target)

    assert_equal "a turn is in flight on it", Sessions::LiveTurn.describe(target)

    target.merge_metadata!("pending_follow_up_prompt" => "the new prompt")
    assert_equal "a turn is in flight on it, and a prompt has been accepted for it and not yet delivered",
      Sessions::LiveTurn.describe(target)
  end

  test "describe is nil for a conversation at rest" do
    assert_nil Sessions::LiveTurn.describe(session(status: :needs_input))
  end

  test "the refusal names the alternatives before force" do
    target = session

    text = Sessions::LiveTurn.refusal_message(target)

    assert_includes text, "Cannot archive session #{target.id}"
    assert_includes text, "an agent turn is in flight"
    assert_operator text.index("follow_up"), :<, text.index("\"force\": true"),
      "redirecting the session has to come before the way to destroy its turn"
  end

  test "the batch refusal says force applies to the whole batch" do
    assert_includes Sessions::LiveTurn.refusal_message(session, batch: true), "every session in the batch"
  end

  # === #underway?, the guard `running?` used to be (#1040) ===================
  #
  # Since a handed-over turn reads `waiting`, every caller that decided "queue
  # this prompt rather than starting a second turn" on `session.running?` has to
  # ask this instead. It is a pure widening: `running` still answers yes on its
  # own, without a query.

  test "a running session has a turn underway whatever its job rows say" do
    assert Sessions::LiveTurn.underway?(session),
      "a running row with no job is an orphan a sweep owns — a follow-up still queues behind it"
  end

  # THE #1040 CASE. This session reads `waiting` and a worker is coming for it
  # within minutes; delivering into it would be a second turn on one clone.
  test "a waiting session with a ready turn in the agents lane has one underway" do
    target = session(status: :waiting)
    enqueue_turn!(target)

    assert Sessions::LiveTurn.underway?(target)
  end

  test "a waiting session whose turn a worker already has has one underway" do
    target = session(status: :waiting)
    on_a_worker!(target)

    assert Sessions::LiveTurn.underway?(target)
  end

  # A spot-gate re-check or a clone backoff. The turn runs LATER, and a follow-up
  # sent now is supposed to be DELIVERED rather than queued behind a job that may
  # be an hour away — which is why #underway? is narrower than #coming? here.
  test "a waiting session whose turn is parked on a future scheduled_at has none underway" do
    target = session(status: :waiting)
    enqueue_turn!(target, scheduled_at: 30.minutes.from_now)

    assert_not Sessions::LiveTurn.underway?(target)
    assert Sessions::LiveTurn.coming?(target), "it is still a turn that is coming"
  end

  test "a dormant waiting session has no turn underway" do
    assert_not Sessions::LiveTurn.underway?(session(status: :waiting))
  end

  test "a session at rest has no turn underway" do
    assert_not Sessions::LiveTurn.underway?(session(status: :needs_input))
    assert_not Sessions::LiveTurn.underway?(session(status: :failed))
  end

  # THE 30-MINUTE CLIFF. `JobLiveness` calls a ready, unclaimed job `:abandoned`
  # past ABANDONED_QUEUED_JOB_AGE, on a horizon written when only a wedged job
  # could reach it. A turn that has genuinely waited 31 minutes behind the pool is
  # still a turn a worker will run, and dropping it here would open every guard at
  # once — at exactly the moment the queue is deepest.
  test "a turn that has waited past the abandoned horizon is still underway" do
    target = session(status: :waiting)
    enqueue_turn!(target, scheduled_at: 2.hours.ago, created_at: 2.hours.ago)

    assert_equal :abandoned, JobLiveness.status(Sessions::LiveTurn.unfinished_turns(target).sole),
      "precondition: this is the row JobLiveness gives up on"
    assert Sessions::LiveTurn.underway?(target)
  end

  # A clone-only job makes the clone and returns without spawning an agent and
  # without draining the queue, so reading it as a turn would park the first prompt
  # into a cloning session in a queue nothing at that job's end picks up.
  test "a clone-only job is not a turn underway" do
    target = session(status: :waiting)
    GoodJob::Job.create!(
      active_job_id: SecureRandom.uuid, queue_name: "agents", job_class: "AgentSessionJob",
      scheduled_at: 2.minutes.ago,
      serialized_params: { "arguments" => [ target.id, nil, { "clone_only" => true } ] }
    )

    assert_not Sessions::LiveTurn.underway?(target)
  end

  test "a turn that is not clone-only is still underway when both rows exist" do
    target = session(status: :waiting)
    GoodJob::Job.create!(
      active_job_id: SecureRandom.uuid, queue_name: "agents", job_class: "AgentSessionJob",
      scheduled_at: 2.minutes.ago,
      serialized_params: { "arguments" => [ target.id, nil, { "clone_only" => true } ] }
    )
    enqueue_turn!(target)

    assert Sessions::LiveTurn.underway?(target)
  end

  # Fails closed, like #in_flight?: the prompt goes into the durable queue and
  # drains at the next turn boundary, which is recoverable. A second concurrent
  # turn is not.
  test "an unreadable agents queue reads as a turn underway" do
    target = session(status: :waiting)
    Sessions::LiveTurn.stubs(:unfinished_turns).raises(ActiveRecord::StatementInvalid, "boom")

    assert Sessions::LiveTurn.underway?(target)
  end
end
