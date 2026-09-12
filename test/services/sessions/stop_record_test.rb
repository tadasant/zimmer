require "test_helper"
require "mocha/minitest"

# The invariant this file exists to pin: **a session that leaves `running` for
# `waiting` records why it stopped** (tadasant/zimmer#608).
#
# Three PRIORITY sessions started cleanly on 2026-08-22 and were back in `waiting`
# sixty to seventy-five seconds later carrying no `exit_status`, no
# `auth_outage_reason` and no `auth_outage_parked_at`. The tests below cover both
# halves of that: the specific path that produced it (AuthOutageParkServiceTest
# owns that one), and the recording gap that made it undiagnosable — which is what
# these assert.
class Sessions::StopRecordTest < ActiveSupport::TestCase
  setup do
    @session = Session.create!(
      prompt: "Test prompt",
      agent_runtime: "claude_code",
      status: :running,
      git_root: "https://github.com/test/repo.git",
      branch: "main",
      session_id: SecureRandom.uuid,
      metadata: { "clone_path" => "/tmp/test-clone", "working_directory" => "/tmp/test-clone" }
    )
  end

  def stop_reason(session = @session)
    session.reload.metadata[Sessions::StopRecord::REASON]
  end

  # A real, fireable one-time wake aimed at +session+, so a `scheduled_wake` sleep
  # intent is one #execute_pending_sleep will honour rather than drop.
  def arm_wake_for(session)
    Trigger.create!(
      name: "Wake ##{session.id}",
      status: "enabled",
      agent_root_name: "zimmer",
      prompt_template: "Wake",
      reuse_session: true,
      last_session_id: session.id,
      trigger_conditions_attributes: [
        { condition_type: "schedule",
          configuration: { "scheduled_at" => 30.minutes.from_now.iso8601, "timezone" => "UTC" } }
      ]
    )
    session.reload
  end

  # ---------------------------------------------------------------------------
  # The invariant itself
  # ---------------------------------------------------------------------------

  test "a running session carried to waiting always records a reason" do
    @session.merge_metadata!("pending_sleep" => true)

    @session.pause!

    assert_equal "waiting", @session.reload.status
    assert_not_nil stop_reason, "a `running -> waiting` transition must record why"
    assert @session.metadata[Sessions::StopRecord::AT].present?
    assert @session.metadata[Sessions::StopRecord::DETAIL].present?
  end

  # The exact signature reported in #608: dormant, and nothing on the row explains
  # it. The point is not that the reason is good — it is that the transition is no
  # longer silent, and says so on the timeline a human reads.
  test "a stop nothing on the row explains is recorded as unattributed and announced" do
    @session.merge_metadata!("pending_sleep" => true)

    @session.pause!

    assert_equal Sessions::StopRecord::UNATTRIBUTED, stop_reason
    warning = @session.logs.where(level: "warning").last
    assert_not_nil warning, "an unattributed stop must leave an operator signal on the session"
    assert_match(/no attributable cause|nothing on the record/i, warning.content)
    assert_match(/608/, warning.content)
  end

  test "an ordinary needs_input sleep records a reason too" do
    @session.pause!
    assert_equal "needs_input", @session.reload.status

    @session.sleep!

    assert_equal "waiting", @session.reload.status
    assert_not_nil stop_reason
  end

  # ---------------------------------------------------------------------------
  # Classification
  # ---------------------------------------------------------------------------

  test "the provenance stamped with the sleep intent names the cause" do
    @session.merge_metadata!(
      Sessions::StopRecord.pending_sleep(Sessions::StopRecord::AUTH_OUTAGE_PARK)
    )

    @session.pause!

    assert_equal Sessions::StopRecord::AUTH_OUTAGE_PARK, stop_reason
  end

  test "the provenance survives a stop whose mechanism recorded nothing else" do
    # AuthOutageParkService writes both in one statement, so it cannot produce this
    # row. It is the shape any two-write mechanism would leave on a lost second
    # write, and the stamp is what keeps such a stop attributable.
    @session.merge_metadata!(
      Sessions::StopRecord.pending_sleep(Sessions::StopRecord::AUTH_OUTAGE_PARK)
    )

    @session.pause!

    assert_nil @session.reload.metadata["auth_outage_reason"]
    assert_equal Sessions::StopRecord::AUTH_OUTAGE_PARK, stop_reason
  end

  test "a park record on the row classifies the stop when no provenance is stamped" do
    @session.pause!
    @session.merge_metadata!(
      "auth_outage_reason" => AuthOutageParkService::QUOTA_EXHAUSTED,
      "auth_outage_parked_at" => Time.current.utc.iso8601
    )

    @session.sleep!

    assert_equal Sessions::StopRecord::AUTH_OUTAGE_PARK, stop_reason
    assert_match(/login pool/i, @session.reload.metadata[Sessions::StopRecord::DETAIL])
  end

  test "a spot ceiling pause on the row classifies the stop" do
    @session.pause!
    @session.merge_metadata!(
      SpotSessionPause::PAUSED_AT => Time.current.utc.iso8601,
      SpotSessionPause::PAUSED_REASON => SpotSessionPause::UTILIZATION_REASON,
      SpotSessionPause::PAUSED_DETAIL => "the window is spent"
    )

    @session.sleep!

    assert_equal Sessions::StopRecord::SPOT_PAUSE, stop_reason
  end

  test "a deliberate sleep classifies as deliberate rather than unattributed" do
    @session.pause!
    @session.merge_metadata!(Session::DELIBERATE_SLEEP_KEY => Time.current.iso8601)

    @session.sleep!

    assert_equal Sessions::StopRecord::DELIBERATE_SLEEP, stop_reason
  end

  test "a session asleep on a wake it armed classifies as a scheduled wake" do
    @session.pause!
    @session.stubs(:armed_scheduled_wake?).returns(true)

    @session.sleep!

    assert_equal Sessions::StopRecord::SCHEDULED_WAKE, stop_reason
  end

  # `paused_by` carries four values from four paths, and none of them is cleared by
  # a pause or a sleep. Collapsing them would report Zimmer's own recovery of an
  # interrupted process as something a human did.
  test "a recovery pause is not reported as something a human did" do
    @session.pause!
    @session.merge_metadata!("paused_by" => "recovery")

    @session.sleep!

    assert_equal Sessions::StopRecord::RECOVERY_PAUSE, stop_reason
    assert_match(/recovery/i, @session.reload.metadata[Sessions::StopRecord::DETAIL])
  end

  test "a human pause is reported as one" do
    @session.pause!
    @session.merge_metadata!("paused_by" => "user")

    @session.sleep!

    assert_equal Sessions::StopRecord::USER_PAUSE, stop_reason
  end

  # An armed wake is the operationally useful fact — the session is coming back on
  # it — and `paused_by` outliving an earlier pause must not suppress that.
  test "an armed wake outranks a paused_by left over from an earlier stop" do
    @session.pause!
    @session.merge_metadata!("paused_by" => "recovery")
    @session.stubs(:armed_scheduled_wake?).returns(true)

    @session.sleep!

    assert_equal Sessions::StopRecord::SCHEDULED_WAKE, stop_reason
  end

  test "an unrecognised paused_by value is not invented into a cause" do
    @session.pause!
    @session.merge_metadata!("paused_by" => "something_new")

    @session.sleep!

    assert_equal Sessions::StopRecord::UNATTRIBUTED, stop_reason
  end

  test "a session returned to the queue before it ever ran classifies as such" do
    @session.pause!
    @session.merge_metadata!(Sessions::ReturnToQueue::REASON_KEY => "no prompt to run")

    @session.sleep!

    assert_equal Sessions::StopRecord::UNSTARTED_REQUEUE, stop_reason
  end

  # ---------------------------------------------------------------------------
  # Lifecycle of the record
  # ---------------------------------------------------------------------------

  test "the record is dropped when the session runs again" do
    @session.merge_metadata!("pending_sleep" => true)
    @session.pause!
    assert_not_nil stop_reason

    @session.resume!

    # `waiting`: the resume hands the turn over and the session queues for a worker
    # (#1040). The record is dropped either way — the point is that it does not
    # survive onto a session that has work coming.
    assert_equal "waiting", @session.reload.status
    Sessions::StopRecord::STOP_KEYS.each do |key|
      assert_nil @session.metadata[key], "#{key} must not survive a resume"
    end
  end

  test "the record is dropped when a waiting session starts" do
    @session.merge_metadata!("pending_sleep" => true)
    @session.pause!
    assert_equal "waiting", @session.reload.status

    @session.start!

    assert_equal "running", @session.reload.status
    assert_nil @session.metadata[Sessions::StopRecord::REASON]
  end

  # The wake has to be really armed, not just intended: since #1172 a
  # `scheduled_wake` intent with nothing armed is DROPPED rather than executed, so
  # a session with no trigger rows would take that branch and never reach the
  # sleep this test is about.
  test "the sleep intent and its provenance are cleared together" do
    arm_wake_for(@session)
    @session.merge_metadata!(
      Sessions::StopRecord.pending_sleep(Sessions::StopRecord::SCHEDULED_WAKE)
    )

    @session.pause!

    reloaded = @session.reload
    assert_equal "waiting", reloaded.status, "this test is about the executed sleep, not the dropped intent"
    assert_nil reloaded.metadata["pending_sleep"]
    assert_nil reloaded.metadata[Sessions::StopRecord::PENDING_SLEEP_REASON],
      "a provenance stamp outliving its flag would attribute the NEXT stop to this one"
  end

  test "a resume clears the sleep intent and its provenance together" do
    arm_wake_for(@session)
    @session.merge_metadata!(
      Sessions::StopRecord.pending_sleep(Sessions::StopRecord::SCHEDULED_WAKE)
    )
    @session.pause!
    @session.reload
    assert_equal "waiting", @session.status
    # Put the pair back on a needs_input row, as a failed pause would leave it.
    @session.update!(status: :needs_input)
    @session.merge_metadata!(
      Sessions::StopRecord.pending_sleep(Sessions::StopRecord::SCHEDULED_WAKE)
    )

    @session.resume!

    reloaded = @session.reload
    assert_nil reloaded.metadata["pending_sleep"]
    assert_nil reloaded.metadata[Sessions::StopRecord::PENDING_SLEEP_REASON]
  end

  # ---------------------------------------------------------------------------
  # Failure containment
  # ---------------------------------------------------------------------------

  test "a failure to record the stop does not cost the transition" do
    @session.merge_metadata!("pending_sleep" => true)
    Sessions::StopRecord.stubs(:classify).raises(StandardError, "boom")

    @session.pause!

    assert_equal "waiting", @session.reload.status,
      "losing the note must not also lose the transition it describes"
  end

  # Stubbed at the real underlying read, NOT at the predicate, because the two
  # predicates disagree on purpose and that disagreement is the thing being pinned:
  # #awaiting_scheduled_wake? rescues an unreadable trigger table to TRUE, and a
  # classifier inheriting that would attribute an unexplained stop to a wake nobody
  # could see.
  test "an unreadable trigger table does not let an unexplained stop borrow an explanation" do
    @session.pause!
    @session.stubs(:pending_one_time_wake_conditions).raises(ActiveRecord::StatementInvalid, "gone")

    assert @session.awaiting_scheduled_wake?,
      "the predicate every start path asks still fails safe to true"

    @session.sleep!

    assert_equal Sessions::StopRecord::UNATTRIBUTED, stop_reason
  end

  # SessionRecoveryService strips `pending_sleep` on its own and lets the session
  # keep running. A stamp surviving that would sit on a RUNNING row and then name
  # the cause of some later, unrelated stop — #608's invisibility with a false
  # explanation attached.
  test "a stamp whose flag was stripped elsewhere does not survive onto a later stop" do
    @session.merge_metadata!(
      Sessions::StopRecord.pending_sleep(Sessions::StopRecord::SCHEDULED_WAKE)
    )
    @session.remove_metadata!("pending_sleep")

    @session.pause!
    assert_equal "needs_input", @session.reload.status
    @session.resume!

    assert_nil @session.reload.metadata[Sessions::StopRecord::PENDING_SLEEP_REASON]
  end
end
