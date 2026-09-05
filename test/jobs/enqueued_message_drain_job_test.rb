# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"

class EnqueuedMessageDrainJobTest < ActiveJob::TestCase
  def idle_session_with_queued_message(content: "and now the other half")
    session = sessions(:waiting)
    session.update!(status: :needs_input)
    message = session.enqueued_messages.create!(content: content, position: 1, status: "pending")
    [ session, message ]
  end

  # The invariant itself: a session sitting in needs_input with something queued
  # for it takes the message and keeps going.
  test "delivers the queued message and puts the session back to work" do
    session, message = idle_session_with_queued_message

    assert_enqueued_with(job: AgentSessionJob) do
      EnqueuedMessageDrainJob.perform_now(session.id)
    end

    assert session.reload.running?, "the session should be running again, not idling on its queue"
    assert_not EnqueuedMessage.exists?(message.id), "the delivered message is consumed"
    assert_empty session.enqueued_messages.pending
  end

  test "says what it did on the session's log" do
    session, = idle_session_with_queued_message

    EnqueuedMessageDrainJob.perform_now(session.id)

    assert session.logs.where("content LIKE ?", "%Queued message delivered%").exists?
  end

  test "leaves several queued messages to the ordinary end-of-turn drain" do
    session, = idle_session_with_queued_message(content: "first")
    session.enqueued_messages.create!(content: "second", position: 2, status: "pending")

    EnqueuedMessageDrainJob.perform_now(session.id)

    assert_equal [ "second" ], session.enqueued_messages.pending.ordered.pluck(:content),
      "only the front message is delivered; the rest ride the turn this one starts"
  end

  test "does nothing for a session that is no longer idle" do
    session, message = idle_session_with_queued_message
    session.update!(status: :running)

    assert_no_enqueued_jobs(only: AgentSessionJob) do
      EnqueuedMessageDrainJob.perform_now(session.id)
    end

    assert_equal "pending", message.reload.status
  end

  test "does nothing when the queue is empty" do
    session = sessions(:waiting)
    session.update!(status: :needs_input)

    assert_no_enqueued_jobs(only: AgentSessionJob) do
      EnqueuedMessageDrainJob.perform_now(session.id)
    end

    assert session.reload.needs_input?
  end

  test "does nothing for a session that no longer exists" do
    id = sessions(:waiting).id
    Session.find(id).destroy!

    assert_nothing_raised { EnqueuedMessageDrainJob.perform_now(id) }
  end

  # The agent process is still alive and blocked on a synchronous MCP
  # elicitation. Resuming would spawn a second process against one clone and
  # orphan the round-trip.
  test "leaves a session blocked on an elicitation alone" do
    session, message = idle_session_with_queued_message
    session.update!(metadata: (session.metadata || {}).merge("blocked_on_elicitation" => true))

    assert_no_enqueued_jobs(only: AgentSessionJob) do
      EnqueuedMessageDrainJob.perform_now(session.id)
    end

    assert_equal "pending", message.reload.status
    assert session.reload.needs_input?
  end

  # A fresh turn would hit the same quota or auth wall, burn the message, and
  # park again. AgentSessionJob's own end-of-turn drain reads the same marker.
  test "leaves a session parked on an auth outage alone" do
    session, message = idle_session_with_queued_message
    session.update!(metadata: (session.metadata || {}).merge("auth_outage_reason" => "quota_exhausted"))

    assert_no_enqueued_jobs(only: AgentSessionJob) do
      EnqueuedMessageDrainJob.perform_now(session.id)
    end

    assert_equal "pending", message.reload.status
  end

  # ---------------------------------------------------------------------------
  # `waiting` — the other resting state (#566, #690)
  #
  # The three create surfaces all promise the caller delivery "when the session
  # becomes idle", and a session resting in `waiting` already is: asleep on an
  # `open-pr` self-wake, slept by `action_session sleep`, resting after a park.
  # This job used to refuse every one of them, and nothing else was coming.
  # ---------------------------------------------------------------------------

  def sleeping_session_with_queued_message(content: "Your PR merged. That is your signal to archive.")
    session = sessions(:waiting)
    session.update!(
      status: :waiting,
      session_id: SecureRandom.uuid,
      transcript: { "type" => "user", "message" => { "content" => "go" } }.to_json,
      metadata: { "working_directory" => "/tmp/drain-waiting-clone" }
    )
    message = session.enqueued_messages.create!(content: content, position: 1, status: "pending")
    [ session, message ]
  end

  test "delivers to a session resting in waiting, not just one in needs_input" do
    session, message = sleeping_session_with_queued_message

    assert_enqueued_with(job: AgentSessionJob) do
      EnqueuedMessageDrainJob.perform_now(session.id)
    end

    assert session.reload.running?, "a sleeping session takes the message it was owed"
    assert_not EnqueuedMessage.exists?(message.id)
  end

  # The wake this consumes is the one the session armed to sleep on the very
  # thing that just arrived. Spending it to deliver the notice is the point.
  test "delivering to a sleeping session is worth the wake it consumes" do
    session, = sleeping_session_with_queued_message
    session.stubs(:paused_until_scheduled_time?).returns(true)
    Session.stubs(:find_by).with(id: session.id).returns(session)

    EnqueuedMessageDrainJob.perform_now(session.id)

    assert session.reload.running?,
      "an armed self-wake is not a reason to leave the message it was waiting for undelivered"
  end

  # `waiting` is not only a resting state — it is also where a session sits for
  # the whole of its FIRST START, from the moment AgentSessionJob claims
  # `running_job_id` through the clone and the spawn until the transition to
  # `running`. Delivering into that window LOSES the message: the processor takes
  # its resume! branch (which does not clear `running_job_id`), destroys the row,
  # and the fresh AgentSessionJob it enqueues is refused as a duplicate of the
  # live first-start job.
  test "leaves a session a job is already driving alone" do
    session, message = sleeping_session_with_queued_message
    session.update!(running_job_id: SecureRandom.uuid)

    assert_no_enqueued_jobs(only: AgentSessionJob) do
      EnqueuedMessageDrainJob.perform_now(session.id)
    end

    assert_equal "pending", message.reload.status
    assert session.reload.waiting?, "a session mid-first-start is not idling on its queue"
  end

  # The refusal above is scoped to `waiting` deliberately. A `needs_input` session
  # carrying a stale job id is exactly what this job's bounded retry and alert
  # exist to report, so it must still be attempted rather than skipped silently.
  test "a stale job id does not stop a drain for a session in needs_input" do
    session, message = idle_session_with_queued_message
    session.update!(running_job_id: SecureRandom.uuid)

    EnqueuedMessageDrainJob.perform_now(session.id)

    assert_not EnqueuedMessage.exists?(message.id), "the needs_input drain is unchanged"
  end

  # A follow-up prompt into a session with no runtime session id is reclassified
  # by AgentSessionJob as a FRESH START, which runs the session's own prompt and
  # DISCARDS the follow-up. "Delivering" here would destroy the message.
  test "leaves a session that has never started alone" do
    session, message = sleeping_session_with_queued_message
    session.update!(session_id: nil, transcript: nil)

    assert_no_enqueued_jobs(only: AgentSessionJob) do
      EnqueuedMessageDrainJob.perform_now(session.id)
    end

    assert_equal "pending", message.reload.status
    assert session.reload.waiting?
  end

  # The population `never_ran?` would have missed, and the one that matters most.
  # A session that HAS run has a transcript, so `never_ran?` is false — but the
  # reclassification this refusal guards against keys on the session id alone,
  # and a session whose stale runtime id was released (failed-resume recovery,
  # ProcessLifecycleManager#release_stale_runtime_session_id!) has a full
  # transcript and no id. Draining into one spends the message on a turn that
  # runs `session.prompt` instead and throws the message away.
  test "leaves a session whose runtime session id was released alone, transcript or no transcript" do
    session, message = sleeping_session_with_queued_message
    session.update!(session_id: nil)
    assert_not session.never_ran?, "this session has run — the narrower guard would not have caught it"

    assert_no_enqueued_jobs(only: AgentSessionJob) do
      EnqueuedMessageDrainJob.perform_now(session.id)
    end

    assert_equal "pending", message.reload.status
    assert session.reload.waiting?
  end

  # SpotSessionHold refuses the turn at the door and re-queues it as a fresh row.
  # Draining into one would churn the message's position and origin on every
  # pass while the gate's own re-check is already the thing that will run it.
  test "leaves a session held at the spot quota gate alone" do
    session, message = sleeping_session_with_queued_message
    session.merge_metadata!(SpotSessionHold::HELD_REASON => "at_utilization_limit")

    assert_no_enqueued_jobs(only: AgentSessionJob) do
      EnqueuedMessageDrainJob.perform_now(session.id)
    end

    assert_equal "pending", message.reload.status
  end

  test "leaves a session paused in the spot queue alone" do
    session, message = sleeping_session_with_queued_message
    session.merge_metadata!(SpotSessionPause::PAUSED_REASON => "at_utilization_limit")

    assert_no_enqueued_jobs(only: AgentSessionJob) do
      EnqueuedMessageDrainJob.perform_now(session.id)
    end

    assert_equal "pending", message.reload.status
  end

  # The park's own marker already covers both resting states, and it has to: a
  # fresh turn would hit the same wall, burn the message and park again. The
  # queued notice is delivered by the un-park instead, which resumes with a
  # recovery nudge that AgentSessionJob hands to the queue.
  test "leaves a session parked on an auth outage in waiting alone" do
    session, message = sleeping_session_with_queued_message
    session.merge_metadata!("auth_outage_reason" => "quota_exhausted")

    assert_no_enqueued_jobs(only: AgentSessionJob) do
      EnqueuedMessageDrainJob.perform_now(session.id)
    end

    assert_equal "pending", message.reload.status
  end

  test "leaves a session waiting on a scheduled MCP retry alone" do
    session, message = idle_session_with_queued_message
    session.update!(metadata: (session.metadata || {}).merge("paused_by" => "mcp_retry"))

    assert_no_enqueued_jobs(only: AgentSessionJob) do
      EnqueuedMessageDrainJob.perform_now(session.id)
    end

    assert_equal "pending", message.reload.status
  end

  # A queue that emptied without a delivery is a success, not the failure the
  # retry/alert path exists for. A stale conflict notice is retired rather than
  # delivered (EnqueuedMessage#stale?), which leaves the processor with nothing
  # to claim — and paging about that would turn the fix into a new alert.
  test "a queue retired rather than delivered is not treated as a failed drain" do
    session, message = idle_session_with_queued_message(
      content: AutomatedPrompts.merge_conflict_message("https://github.com/tadasant/zimmer/pull/834")
    )
    message.update!(origin: "automated_merge_conflict")
    GithubPullRequestMergeability.stubs(:read).returns(:mergeable)
    AlertService.expects(:raise_alert).never

    assert_no_enqueued_jobs(only: EnqueuedMessageDrainJob) do
      EnqueuedMessageDrainJob.perform_now(session.id)
    end

    assert_equal "undelivered", message.reload.status
    assert session.reload.needs_input?, "the session keeps resting rather than burning a turn"
  end

  # record_attempt runs before the try, and only `resume` clears it — which a
  # retire-only drain never reaches. Left standing, three of these would leave
  # the counter at MAX_ATTEMPTS and send the next GENUINE failure straight to
  # give_up with no retries and a page.
  test "a retire-only drain gives the attempt back instead of banking it" do
    session, message = idle_session_with_queued_message(
      content: AutomatedPrompts.merge_conflict_message("https://github.com/tadasant/zimmer/pull/834")
    )
    message.update!(origin: "automated_merge_conflict")
    GithubPullRequestMergeability.stubs(:read).returns(:mergeable)

    EnqueuedMessageDrainJob.perform_now(session.id)

    assert_nil session.reload.metadata[EnqueuedMessageDrainJob::ATTEMPTS_KEY],
      "a drain that had nothing left to deliver did not fail at anything"
  end

  # The bounded half of "do not create a spin loop": a drain that cannot deliver
  # backs off rather than retrying on the spot, and counts.
  test "retries with a delay when delivery fails" do
    session, = idle_session_with_queued_message
    EnqueuedMessageProcessorService.any_instance.stubs(:process_next_message).returns(false)

    assert_enqueued_with(job: EnqueuedMessageDrainJob, args: [ session.id ]) do
      EnqueuedMessageDrainJob.perform_now(session.id)
    end

    assert_equal 1, session.reload.metadata[EnqueuedMessageDrainJob::ATTEMPTS_KEY]
  end

  test "gives up after the attempt limit rather than retrying forever" do
    session, = idle_session_with_queued_message
    EnqueuedMessageProcessorService.any_instance.stubs(:process_next_message).returns(false)
    AlertService.stubs(:raise_alert).returns(true)

    EnqueuedMessageDrainJob::MAX_ATTEMPTS.times { EnqueuedMessageDrainJob.perform_now(session.id) }

    assert_equal EnqueuedMessageDrainJob::MAX_ATTEMPTS,
      session.reload.metadata[EnqueuedMessageDrainJob::ATTEMPTS_KEY]
    assert_no_enqueued_jobs(only: EnqueuedMessageDrainJob) do
      # The limit is already reached; nothing further should be scheduled.
      EnqueuedMessageDrainJob.perform_now(session.id)
    end
  end

  # The terminal case has to be loud, because the session is now idle on work it
  # was given and nothing is going to hand it a turn on its own.
  test "pages when it gives up" do
    session, = idle_session_with_queued_message
    EnqueuedMessageProcessorService.any_instance.stubs(:process_next_message).returns(false)
    session.update!(
      metadata: (session.metadata || {})
        .merge(EnqueuedMessageDrainJob::ATTEMPTS_KEY => EnqueuedMessageDrainJob::MAX_ATTEMPTS - 1)
    )

    AlertService.expects(:raise_alert).with do |title, options|
      title == "Session idle with an undeliverable queued message" &&
        options[:dedup_key] == "undeliverable_enqueued_messages_#{session.id}"
    end

    EnqueuedMessageDrainJob.perform_now(session.id)
  end

  # Giving up records the failure; it does not destroy the caller's message.
  # Unlike an archive, an idle session still has a delivery path — the next turn
  # anybody gives it drains the queue through AgentSessionJob.
  test "leaves the undeliverable messages pending rather than retiring them" do
    session, message = idle_session_with_queued_message
    EnqueuedMessageProcessorService.any_instance.stubs(:process_next_message).returns(false)
    AlertService.stubs(:raise_alert).returns(true)

    EnqueuedMessageDrainJob::MAX_ATTEMPTS.times { EnqueuedMessageDrainJob.perform_now(session.id) }

    assert_equal "pending", message.reload.status,
      "the message is still deliverable, so it must not be marked undelivered"
    assert session.logs.where("content LIKE ?", "%Could not deliver%").exists?
  end

  test "a broken alert service cannot take the job down with it" do
    session, = idle_session_with_queued_message
    EnqueuedMessageProcessorService.any_instance.stubs(:process_next_message).returns(false)
    AlertService.stubs(:raise_alert).raises(StandardError, "slack is on fire")
    session.update!(
      metadata: (session.metadata || {})
        .merge(EnqueuedMessageDrainJob::ATTEMPTS_KEY => EnqueuedMessageDrainJob::MAX_ATTEMPTS - 1)
    )

    assert_nothing_raised { EnqueuedMessageDrainJob.perform_now(session.id) }
  end

  # The counter bounds retries within one idle spell, so it must not survive the
  # session getting going again — otherwise a later drain inherits a used-up
  # budget and gives up on its first try.
  test "resuming the session clears the attempt counter" do
    session, = idle_session_with_queued_message
    EnqueuedMessageProcessorService.any_instance.stubs(:process_next_message).returns(false)

    EnqueuedMessageDrainJob.perform_now(session.id)
    assert_equal 1, session.reload.metadata[EnqueuedMessageDrainJob::ATTEMPTS_KEY]

    session.resume!

    assert_not session.reload.metadata.key?(EnqueuedMessageDrainJob::ATTEMPTS_KEY)
  end
end
