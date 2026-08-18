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

  test "leaves a session waiting on a scheduled MCP retry alone" do
    session, message = idle_session_with_queued_message
    session.update!(metadata: (session.metadata || {}).merge("paused_by" => "mcp_retry"))

    assert_no_enqueued_jobs(only: AgentSessionJob) do
      EnqueuedMessageDrainJob.perform_now(session.id)
    end

    assert_equal "pending", message.reload.status
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
