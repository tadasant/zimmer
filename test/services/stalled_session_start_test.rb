# frozen_string_literal: true

require "test_helper"

# The sweep for a session that was created, queued, and then forgotten.
#
# A session's first turn rides on exactly one AgentSessionJob, and — unlike a
# spot hold, a ceiling pause, an auth park or a recovery pause — a session that
# has never run carries no marker saying so. Lose that job and the row sits in
# `waiting` looking exactly like a session created a moment ago, which is why no
# other sweep has ever looked at it. Production session 10426 sat there for three
# days while the PR it was spawned to gate was merged by a human seven minutes
# after it was created.
#
# Two halves, and both are load-bearing. A stranded session must come back — and
# a session that is merely queued, held, paused, parked or asleep must not be
# started underneath the thing that stopped it.
class StalledSessionStartTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    GoodJob::Job.delete_all
    # Fixture sessions sitting in `waiting` are legitimate candidates for this
    # sweep, so move them out of its population rather than asserting around them.
    Session.where(status: :waiting).update_all(status: Session.statuses[:needs_input])
  end

  # A session that was created `age` ago and never started: no session_id, no
  # marker, no job.
  def stalled_session(age: StalledSessionStart::GRACE + 5.minutes, prompt: "gate the PR", **attributes)
    session = Session.create!(
      git_root: "https://github.com/tadasant/tadasant-internal.git",
      prompt: prompt,
      genesis: SessionGenesis::GITHUB_LABEL,
      status: :waiting,
      **attributes
    )
    session.update_columns(created_at: age.ago, updated_at: age.ago)
    session.reload
  end

  def with_metadata(session, metadata)
    session.merge_metadata!(metadata)
    # `merge_metadata!` stamps `updated_at`, which is exactly the cooldown the
    # sweep leans on between attempts (see the cooldown test below). Put the row
    # back where the test wants it.
    session.update_columns(updated_at: session.created_at)
    session.reload
  end

  # Written straight into GoodJob rather than enqueued: the suite runs on the
  # ActiveJob test adapter, which persists nothing, and the pending-turn check
  # deliberately reads the durable queue.
  def queue_a_turn_for(session, scheduled_at: 1.minute.from_now)
    GoodJob::Job.create!(
      job_class: "AgentSessionJob", queue_name: "agents", scheduled_at: scheduled_at,
      serialized_params: { "job_class" => "AgentSessionJob", "arguments" => [ session.id ] }
    )
  end

  # --- the core defect ----------------------------------------------------------

  test "a session that has been waiting to start with no job behind it is re-enqueued" do
    session = stalled_session

    result = nil
    assert_enqueued_with(job: AgentSessionJob, args: [ session.id ]) do
      result = StalledSessionStart.sweep!
    end

    assert_equal 1, result.restarted
    assert_equal 1, result.stalled
    assert_equal 0, result.skipped
    assert_equal 1, session.reload.metadata[StalledSessionStart::RESTART_COUNT]
    assert session.waiting?, "the repair is a job, not a status change"
    assert session.logs.where(level: "warning").any? { |log| log.content.include?("never started") },
      "the session's own log has to say why a turn suddenly appeared"
  end

  test "the sweep reports nothing to do when every waiting session is healthy" do
    result = StalledSessionStart.sweep!

    assert_equal 0, result.stalled
    assert_equal 0, result.restarted
  end

  # --- not a lost job ------------------------------------------------------------

  test "a session created inside the grace is left alone" do
    stalled_session(age: StalledSessionStart::GRACE - 2.minutes)

    assert_no_enqueued_jobs(only: AgentSessionJob) do
      assert_equal 0, StalledSessionStart.sweep!.stalled
    end
  end

  # A congested `agents` queue is not a lost job. Re-enqueuing here would put a
  # SECOND agent against one clone.
  test "a session whose start job is still queued is counted but not restarted" do
    session = stalled_session
    queue_a_turn_for(session)
    jobs_before = GoodJob::Job.count

    result = StalledSessionStart.sweep!

    assert_equal 0, result.restarted
    assert_equal 1, result.stalled
    assert_equal 1, result.skipped
    assert_equal jobs_before, GoodJob::Job.count, "no second job may be enqueued"
    assert_nil session.reload.metadata[StalledSessionStart::RESTART_COUNT]
  end

  # A job that is mid-execution is unfinished too — it has simply not written
  # `running_job_id` yet, which is exactly the window this sweep looks into.
  test "a session whose start job is mid-execution is not restarted" do
    session = stalled_session
    queue_a_turn_for(session, scheduled_at: 5.minutes.ago).update!(performed_at: 1.minute.ago)

    assert_no_enqueued_jobs(only: AgentSessionJob) do
      assert_equal 0, StalledSessionStart.sweep!.restarted
    end
  end

  test "a finished start job does not count as a job still behind the session" do
    session = stalled_session
    queue_a_turn_for(session, scheduled_at: 20.minutes.ago).update!(finished_at: 15.minutes.ago)

    assert_enqueued_with(job: AgentSessionJob, args: [ session.id ]) do
      assert_equal 1, StalledSessionStart.sweep!.restarted
    end
  end

  # --- asleep on purpose ---------------------------------------------------------

  test "a held spot session is not restarted" do
    with_metadata(stalled_session, SpotSessionHold::HELD_REASON => "fleet_at_cap")

    assert_no_enqueued_jobs(only: AgentSessionJob) do
      assert_equal 0, StalledSessionStart.sweep!.stalled
    end
  end

  test "a session paused by the spot ceiling is not restarted" do
    with_metadata(stalled_session, SpotSessionPause::PAUSED_REASON => "at_utilization_limit")

    assert_no_enqueued_jobs(only: AgentSessionJob) do
      assert_equal 0, StalledSessionStart.sweep!.stalled
    end
  end

  test "a session parked on an auth outage is not restarted" do
    with_metadata(stalled_session, "auth_outage_reason" => "quota_exhausted")

    assert_no_enqueued_jobs(only: AgentSessionJob) do
      assert_equal 0, StalledSessionStart.sweep!.stalled
    end
  end

  # `paused_by: "recovery"` is CleanupOrphanedSessionsJob's population. Two sweeps
  # continuing one session is the duplicate turn both are written to avoid.
  test "a recovery-paused waiting session is left to the recovery sweeps" do
    with_metadata(stalled_session, "paused_by" => "recovery")

    assert_no_enqueued_jobs(only: AgentSessionJob) do
      assert_equal 0, StalledSessionStart.sweep!.stalled
    end
  end

  test "a session with a wake-up still ahead of it is not restarted" do
    session = stalled_session
    Trigger.create!(
      name: "Wake session ##{session.id}",
      status: "enabled",
      agent_root_name: "zimmer",
      prompt_template: "Wake up",
      reuse_session: true,
      last_session_id: session.id,
      trigger_conditions_attributes: [
        { condition_type: "schedule",
          configuration: { "scheduled_at" => 2.hours.from_now.iso8601, "timezone" => "UTC" } }
      ]
    )

    result = nil
    assert_no_enqueued_jobs(only: AgentSessionJob) do
      result = StalledSessionStart.sweep!
    end

    assert_equal 0, result.restarted
    assert_equal 1, result.dormant, "it is counted as stalled-looking, and then deliberately skipped"
  end

  # --- the wrong population ------------------------------------------------------

  # The same predicate every other recovery path uses for "has never run". A
  # session that HAS run comes back through `paused_by = 'recovery'`; re-running
  # its start job would re-clone underneath a conversation that already exists.
  test "a session that has already run is not restarted" do
    session = stalled_session
    session.update_columns(session_id: SecureRandom.uuid)

    assert_no_enqueued_jobs(only: AgentSessionJob) do
      assert_equal 0, StalledSessionStart.sweep!.stalled
    end
  end

  # The sharpest version of the rule above. A status-summary fork carries a
  # runtime session id from creation, and resuming one as a full agent session
  # makes it replay its parent's task — including its GitHub writes
  # (tadasant/zimmer#716). A fork that never got its prompt (#730) is a stranded
  # `waiting` row, and it must stay this sweep's problem to leave alone.
  test "a status-summary fork is never started by this sweep" do
    session = stalled_session
    session.update_columns(session_id: SecureRandom.uuid)
    with_metadata(session, SessionStatusSummaryGenerator::FORK_MARKER => "7340")

    assert_no_enqueued_jobs(only: AgentSessionJob) do
      assert_equal 0, StalledSessionStart.sweep!.stalled
    end
  end

  test "a clone-only session with no prompt is not restarted" do
    stalled_session(prompt: nil)

    assert_no_enqueued_jobs(only: AgentSessionJob) do
      assert_equal 0, StalledSessionStart.sweep!.stalled
    end
  end

  test "sessions in a frozen category are never touched" do
    category = Category.create!(name: "Parked #{SecureRandom.hex(4)}", is_frozen: true)
    session = stalled_session
    session.update_columns(category_id: category.id)

    assert_no_enqueued_jobs(only: AgentSessionJob) do
      assert_equal 0, StalledSessionStart.sweep!.stalled
    end
  end

  test "only waiting sessions are swept" do
    session = stalled_session
    session.update_columns(status: Session.statuses[:archived])

    assert_no_enqueued_jobs(only: AgentSessionJob) do
      assert_equal 0, StalledSessionStart.sweep!.stalled
    end
  end

  # --- bounds --------------------------------------------------------------------

  # A session whose start job keeps disappearing is not one to re-enqueue
  # forever. A `waiting` row is on nobody's list; a `failed` one is on the
  # dashboard and can be restarted by hand.
  test "a session past the restart budget is failed rather than re-enqueued again" do
    session = with_metadata(stalled_session,
      StalledSessionStart::RESTART_COUNT => StalledSessionStart::MAX_RESTARTS)

    result = nil
    assert_no_enqueued_jobs(only: AgentSessionJob) do
      result = StalledSessionStart.sweep!
    end

    assert_equal 1, result.failed
    assert_equal 0, result.restarted
    session.reload
    assert session.failed?
    assert_includes session.metadata["failure_reason"], "never started"
    assert session.logs.where(level: "error").any? { |log| log.content.include?("never run") }
  end

  test "the restart budget is spent one attempt at a time" do
    session = with_metadata(stalled_session, StalledSessionStart::RESTART_COUNT => 1)

    assert_enqueued_with(job: AgentSessionJob, args: [ session.id ]) do
      assert_equal 1, StalledSessionStart.sweep!.restarted
    end

    assert_equal 2, session.reload.metadata[StalledSessionStart::RESTART_COUNT]
  end

  test "one pass restarts at most MAX_RESTARTS_PER_SWEEP sessions" do
    (StalledSessionStart::MAX_RESTARTS_PER_SWEEP + 3).times { stalled_session }

    result = StalledSessionStart.sweep!

    assert_equal StalledSessionStart::MAX_RESTARTS_PER_SWEEP, result.restarted
    assert_equal StalledSessionStart::MAX_RESTARTS_PER_SWEEP + 3, result.stalled
  end

  # Having restarted once, the next pass five minutes later must see the job it
  # enqueued and leave the session alone rather than stacking a second turn.
  test "a session restarted by one pass is not restarted again by the next" do
    session = stalled_session
    StalledSessionStart.sweep!
    # The test adapter persists nothing, so stand in the durable row the real
    # enqueue would have written, and undo the cooldown so the pending-turn guard
    # is the only thing left holding the sweep back.
    queue_a_turn_for(session)
    session.reload.update_columns(updated_at: session.created_at)

    assert_equal 0, StalledSessionStart.sweep!.restarted
    assert_equal 1, session.reload.metadata[StalledSessionStart::RESTART_COUNT]
  end

  # The second guard against a stacked turn, and the one that does not depend on
  # reading GoodJob: recording the attempt stamps `updated_at`, so the session
  # falls back outside the grace and the next pass cannot even see it.
  test "a restart puts the session back inside the grace for another GRACE" do
    session = stalled_session
    StalledSessionStart.sweep!

    assert session.reload.updated_at > StalledSessionStart::GRACE.ago,
      "recording the attempt has to reset the clock, or a five-minute cron would restart it again"
    assert_equal 0, StalledSessionStart.sweep!.stalled
  end

  # It runs on a cron beside everything else: a failed pass costs a pass.
  test "the sweep never raises" do
    stalled_session
    Sessions::StartNow.stub(:call, ->(*) { raise "boom" }) do
      assert_equal 0, StalledSessionStart.sweep!.restarted
    end
  end
end
