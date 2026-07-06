# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"

class SendPushNotificationJobTest < ActiveJob::TestCase
  setup do
    @session = sessions(:running)
    # Give session a title so we can test expected behavior
    @session.update!(title: "Test Session")
    @mock_service = mock("WebPushService")
    @mock_inference_service = mock("HeadlessInferenceService")
    @mock_broadcast_service = mock("BroadcastService")
    @job = SendPushNotificationJob.new
    @job.web_push_service = @mock_service
    @job.inference_service = @mock_inference_service
    @job.broadcast_service = @mock_broadcast_service
    # Default: allow notification_badge calls with any argument
    @mock_broadcast_service.stubs(:notification_badge)
  end

  # === Basic job behavior ===

  test "job is enqueued in default queue" do
    assert_equal "default", SendPushNotificationJob.new.queue_name
  end

  test "job discards on ActiveRecord::RecordNotFound" do
    assert_nothing_raised do
      SendPushNotificationJob.perform_now(-1, "session_complete")
    end
  end

  # === Notification type handling ===

  test "perform sends session_complete notification" do
    @mock_service.expects(:send_to_all).with(
      title: @session.title,
      body: "#{@session.title} has finished",
      url: "/notifications",
      data: { session_id: @session.id, notification_type: "session_complete" }
    ).returns({ sent: 1, failed: 0, expired: 0 })

    @job.perform(@session.id, :session_complete)
  end

  test "perform sends needs_input notification with fallback body" do
    # When no transcript, falls back to simple body
    @session.update_column(:transcript, nil)

    @mock_service.expects(:send_to_all).with(
      title: @session.title,
      body: "Needs your input",
      url: "/notifications",
      data: { session_id: @session.id, notification_type: "needs_input" }
    ).returns({ sent: 1, failed: 0, expired: 0 })

    @job.perform(@session.id, :needs_input)
  end

  test "perform sends session_failed notification" do
    @mock_service.expects(:send_to_all).with(
      title: @session.title,
      body: "#{@session.title} encountered an error",
      url: "/notifications",
      data: { session_id: @session.id, notification_type: "session_failed" }
    ).returns({ sent: 1, failed: 0, expired: 0 })

    @job.perform(@session.id, :session_failed)
  end

  test "perform sends session_failed notification naming the failed MCP server" do
    @session.update!(
      metadata: (@session.metadata || {}).merge("failure_reason" => "mcp_connection_failed"),
      custom_metadata: (@session.custom_metadata || {}).merge(
        "mcp_failed_servers" => [ { "name" => "good-eggs", "error" => "spawn ENOENT" } ]
      )
    )

    @mock_service.expects(:send_to_all).with(
      title: @session.title,
      body: "MCP server(s) failed to connect: good-eggs — good-eggs: spawn ENOENT",
      url: "/notifications",
      data: { session_id: @session.id, notification_type: "session_failed" }
    ).returns({ sent: 1, failed: 0, expired: 0 })

    @job.perform(@session.id, :session_failed)
  end

  test "perform defaults unknown notification type to session_complete" do
    @mock_service.expects(:send_to_all).with(
      title: @session.title,
      body: "#{@session.title} has finished",
      url: "/notifications",
      data: { session_id: @session.id, notification_type: "session_complete" }
    ).returns({ sent: 1, failed: 0, expired: 0 })

    @job.perform(@session.id, :unknown_type)
  end

  test "perform accepts string notification type" do
    @session.update_column(:transcript, nil)

    @mock_service.expects(:send_to_all).with(
      title: @session.title,
      body: "Needs your input",
      url: "/notifications",
      data: { session_id: @session.id, notification_type: "needs_input" }
    ).returns({ sent: 1, failed: 0, expired: 0 })

    @job.perform(@session.id, "needs_input")
  end

  test "perform defaults to session_complete when type not provided" do
    @mock_service.expects(:send_to_all).with(
      title: @session.title,
      body: "#{@session.title} has finished",
      url: "/notifications",
      data: { session_id: @session.id, notification_type: "session_complete" }
    ).returns({ sent: 1, failed: 0, expired: 0 })

    @job.perform(@session.id)
  end

  # === Session without title ===

  test "perform uses Session ID in title when title is blank" do
    @session.update_column(:title, nil)  # Use update_column to bypass validations/callbacks

    @mock_service.expects(:send_to_all).with(
      title: "Session #{@session.id}",
      body: "Session #{@session.id} has finished",
      url: "/notifications",
      data: { session_id: @session.id, notification_type: "session_complete" }
    ).returns({ sent: 1, failed: 0, expired: 0 })

    @job.perform(@session.id, :session_complete)
  end

  # === URL generation ===

  test "perform always uses notifications URL" do
    @session.update!(slug: "my-session-slug")

    @mock_service.expects(:send_to_all).with(
      has_entry(:url, "/notifications")
    ).returns({ sent: 1, failed: 0, expired: 0 })

    @job.perform(@session.id, :session_complete)
  end

  # === Service result handling ===

  test "perform logs when notifications are skipped" do
    @mock_service.expects(:send_to_all).returns({ sent: 0, failed: 0, expired: 0, skipped: true })

    # Allow other log calls (like notification record creation) with at_least(0)
    Rails.logger.stubs(:info)
    Rails.logger.expects(:info).with(includes("Skipped")).at_least_once

    @job.perform(@session.id, :session_complete)
  end

  test "perform logs results when notifications are sent" do
    result = { sent: 2, failed: 1, expired: 1 }
    @mock_service.expects(:send_to_all).returns(result)

    # Allow other log calls (like notification record creation) with stubs
    Rails.logger.stubs(:info)
    Rails.logger.expects(:info).with(includes("#{result.inspect}")).at_least_once

    @job.perform(@session.id, :session_complete)
  end

  # === Job can be enqueued ===

  test "job can be enqueued with perform_later" do
    assert_enqueued_with(job: SendPushNotificationJob) do
      SendPushNotificationJob.perform_later(@session.id, :session_complete)
    end
  end

  test "job can be enqueued with only session_id" do
    assert_enqueued_with(job: SendPushNotificationJob, args: [ @session.id ]) do
      SendPushNotificationJob.perform_later(@session.id)
    end
  end

  # === Notification record creation ===

  test "perform creates notification record" do
    @session.update_column(:transcript, nil)
    @mock_service.expects(:send_to_all).returns({ sent: 1, failed: 0, expired: 0 })

    assert_difference -> { Notification.count }, 1 do
      @job.perform(@session.id, :needs_input)
    end

    notification = Notification.last
    assert_equal @session.id, notification.session_id
    assert_equal "needs_input", notification.notification_type
    assert_not notification.read?
    assert_not notification.stale?
  end

  test "perform creates notification record even when push is skipped" do
    @mock_service.expects(:send_to_all).returns({ sent: 0, failed: 0, expired: 0, skipped: true })

    assert_difference -> { Notification.count }, 1 do
      @job.perform(@session.id, :session_complete)
    end
  end

  test "perform creates notification with corrected type when unknown type provided" do
    @mock_service.expects(:send_to_all).returns({ sent: 1, failed: 0, expired: 0 })

    @job.perform(@session.id, :unknown_type)

    notification = Notification.last
    assert_equal "session_complete", notification.notification_type
  end

  # === AI summary generation ===

  test "perform falls back to default body when AI summary generation fails" do
    # Set up a session with a transcript
    transcript_entry = {
      "type" => "assistant",
      "timestamp" => Time.current.iso8601,
      "message" => {
        "role" => "assistant",
        "content" => [ { "type" => "text", "text" => "Some assistant message" } ]
      }
    }
    @session.update!(transcript: transcript_entry.to_json)

    # Mock inference service to return nil (simulating failure)
    @mock_inference_service.expects(:generate).returns(nil)

    @mock_service.expects(:send_to_all).with(
      title: @session.title,
      body: "Needs your input",
      url: "/notifications",
      data: { session_id: @session.id, notification_type: "needs_input" }
    ).returns({ sent: 1, failed: 0, expired: 0 })

    @job.perform(@session.id, :needs_input)
  end

  test "perform uses AI-generated summary for needs_input notification body" do
    # Set up a session with a transcript
    transcript_entry = {
      "type" => "assistant",
      "timestamp" => Time.current.iso8601,
      "message" => {
        "role" => "assistant",
        "content" => [ { "type" => "text", "text" => "Which database would you prefer?" } ]
      }
    }
    @session.update!(transcript: transcript_entry.to_json)

    # Mock inference service to return a summary
    @mock_inference_service.expects(:generate).with(anything, timeout: 15).returns("Asking which database to use")

    @mock_service.expects(:send_to_all).with(
      title: @session.title,
      body: "Asking which database to use",
      url: "/notifications",
      data: { session_id: @session.id, notification_type: "needs_input" }
    ).returns({ sent: 1, failed: 0, expired: 0 })

    @job.perform(@session.id, :needs_input)
  end

  # === Notification badge broadcasting ===

  test "perform broadcasts notification badge update after creating notification" do
    @mock_service.expects(:send_to_all).returns({ sent: 1, failed: 0, expired: 0 })

    # Expect the broadcast to be called with the pending count (will be 1 after creation)
    @mock_broadcast_service.unstub(:notification_badge)
    @mock_broadcast_service.expects(:notification_badge).with do |count|
      # The count should be positive (at least the notification we just created)
      count >= 1
    end

    @job.perform(@session.id, :needs_input)
  end

  test "perform broadcasts notification badge even when push is skipped" do
    @mock_service.expects(:send_to_all).returns({ sent: 0, failed: 0, expired: 0, skipped: true })

    @mock_broadcast_service.unstub(:notification_badge)
    @mock_broadcast_service.expects(:notification_badge).once

    @job.perform(@session.id, :session_complete)
  end

  # === needs_input debounce / transition_marker ===

  test "perform skips needs_input notification when session is no longer needs_input" do
    @session.update_columns(
      status: Session.statuses[:running],
      transcript: nil,
      custom_metadata: { "needs_input_count" => 1 }
    )

    @mock_service.expects(:send_to_all).never
    @mock_broadcast_service.expects(:notification_badge).never

    assert_no_difference -> { Notification.count } do
      @job.perform(@session.id, :needs_input, nil, 1)
    end
  end

  test "perform skips needs_input notification when transition_marker is stale (flap reschedule)" do
    @session.update_columns(
      status: Session.statuses[:needs_input],
      transcript: nil,
      custom_metadata: { "needs_input_count" => 2 }
    )

    @mock_service.expects(:send_to_all).never
    @mock_broadcast_service.expects(:notification_badge).never

    assert_no_difference -> { Notification.count } do
      @job.perform(@session.id, :needs_input, nil, 1)
    end
  end

  test "perform sends needs_input notification when transition_marker matches and session still idle" do
    @session.update_columns(
      status: Session.statuses[:needs_input],
      transcript: nil,
      custom_metadata: { "needs_input_count" => 3 }
    )

    @mock_service.expects(:send_to_all).returns({ sent: 1, failed: 0, expired: 0 })

    assert_difference -> { Notification.count }, 1 do
      @job.perform(@session.id, :needs_input, nil, 3)
    end
  end

  # Defensive: in production the state machine always bumps the counter before
  # enqueuing, so a job carrying marker=1 against an empty custom_metadata hash
  # shouldn't occur. If metadata is externally cleared between enqueue and
  # execution, fail safe by skipping rather than firing an unmatched push.
  test "perform skips needs_input notification when session metadata has no counter (defensive)" do
    @session.update_columns(
      status: Session.statuses[:needs_input],
      transcript: nil,
      custom_metadata: {}
    )

    @mock_service.expects(:send_to_all).never

    assert_no_difference -> { Notification.count } do
      @job.perform(@session.id, :needs_input, nil, 1)
    end
  end

  test "perform sends needs_input notification when transition_marker is omitted (legacy/un-debounced enqueue)" do
    @session.update_columns(
      status: Session.statuses[:running],
      transcript: nil
    )

    @mock_service.expects(:send_to_all).returns({ sent: 1, failed: 0, expired: 0 })

    assert_difference -> { Notification.count }, 1 do
      @job.perform(@session.id, :needs_input)
    end
  end

  # === Retry idempotency (issue #3027) ===
  #
  # GoodJob retries can re-enter perform with identical args after a partial
  # failure (e.g. WebPushService timeout). Without dedup, each retry would
  # insert another Notification row visible on /notifications. The job uses a
  # partial unique index on (session_id, notification_type, transition_marker)
  # for marker-bearing types and a recent-window check for unmarked types.

  test "needs_input retry with same transition_marker does not duplicate the Notification" do
    @session.update_columns(
      status: Session.statuses[:needs_input],
      transcript: nil,
      custom_metadata: { "needs_input_count" => 7 }
    )

    @mock_service.expects(:send_to_all).returns({ sent: 1, failed: 0, expired: 0 }).once

    assert_difference -> { Notification.count }, 1 do
      @job.perform(@session.id, :needs_input, nil, 7)
    end

    # Simulate a retry: same args, same session state, same marker.
    # WebPushService is NOT expected to be called again (the dedup short-circuits).
    @job_retry = SendPushNotificationJob.new
    @job_retry.web_push_service = @mock_service
    @job_retry.inference_service = @mock_inference_service
    @job_retry.broadcast_service = @mock_broadcast_service

    assert_no_difference -> { Notification.count } do
      @job_retry.perform(@session.id, :needs_input, nil, 7)
    end
  end

  test "needs_input legitimate flap (different transition_marker) creates a new Notification" do
    @session.update_columns(
      status: Session.statuses[:needs_input],
      transcript: nil,
      custom_metadata: { "needs_input_count" => 1 }
    )

    @mock_service.expects(:send_to_all).twice.returns({ sent: 1, failed: 0, expired: 0 })

    assert_difference -> { Notification.count }, 1 do
      @job.perform(@session.id, :needs_input, nil, 1)
    end

    # User responds, session flaps back to needs_input — counter advances.
    @session.update_columns(custom_metadata: { "needs_input_count" => 2 })

    @job_second = SendPushNotificationJob.new
    @job_second.web_push_service = @mock_service
    @job_second.inference_service = @mock_inference_service
    @job_second.broadcast_service = @mock_broadcast_service

    assert_difference -> { Notification.count }, 1 do
      @job_second.perform(@session.id, :needs_input, nil, 2)
    end
  end

  test "session_complete retry within recent window does not duplicate the Notification" do
    @mock_service.expects(:send_to_all).returns({ sent: 1, failed: 0, expired: 0 }).once

    assert_difference -> { Notification.count }, 1 do
      @job.perform(@session.id, :session_complete)
    end

    @job_retry = SendPushNotificationJob.new
    @job_retry.web_push_service = @mock_service
    @job_retry.inference_service = @mock_inference_service
    @job_retry.broadcast_service = @mock_broadcast_service

    assert_no_difference -> { Notification.count } do
      @job_retry.perform(@session.id, :session_complete)
    end
  end

  test "session_complete after window expires creates a new Notification" do
    @mock_service.expects(:send_to_all).twice.returns({ sent: 1, failed: 0, expired: 0 })

    @job.perform(@session.id, :session_complete)
    first = Notification.last
    # Backdate beyond the recent-window so the second call is treated as a new event.
    first.update_column(:created_at, (SendPushNotificationJob::RECENT_NOTIFICATION_WINDOW + 1.minute).ago)

    @job_second = SendPushNotificationJob.new
    @job_second.web_push_service = @mock_service
    @job_second.inference_service = @mock_inference_service
    @job_second.broadcast_service = @mock_broadcast_service

    assert_difference -> { Notification.count }, 1 do
      @job_second.perform(@session.id, :session_complete)
    end
  end

  test "needs_input retry skips broadcast and push (only sends once)" do
    @session.update_columns(
      status: Session.statuses[:needs_input],
      transcript: nil,
      custom_metadata: { "needs_input_count" => 4 }
    )

    @mock_broadcast_service.unstub(:notification_badge)
    @mock_broadcast_service.expects(:notification_badge).once
    @mock_service.expects(:send_to_all).once.returns({ sent: 1, failed: 0, expired: 0 })

    @job.perform(@session.id, :needs_input, nil, 4)

    @job_retry = SendPushNotificationJob.new
    @job_retry.web_push_service = @mock_service
    @job_retry.inference_service = @mock_inference_service
    @job_retry.broadcast_service = @mock_broadcast_service
    # Retry must NOT broadcast or push again — the .once expectations above
    # would fail if the retry called them.
    @job_retry.perform(@session.id, :needs_input, nil, 4)
  end

  # Documents a deliberate trade-off: when the first attempt commits the
  # Notification row but the push side effect was missed (e.g. a transient
  # error after Notification.create! succeeded), the retry will NOT re-attempt
  # the push — the dedup short-circuit fires on the existing row. This
  # prioritizes "no duplicate /notifications row" over "guaranteed push
  # delivery on retry". In practice WebPushService#send_to_all rescues all
  # per-subscription errors internally, so this code path is rare.
  test "needs_input retry after partial first attempt does NOT re-send push (documented trade-off)" do
    @session.update_columns(
      status: Session.statuses[:needs_input],
      transcript: nil,
      custom_metadata: { "needs_input_count" => 11 }
    )

    # Simulate partial first attempt: Notification row exists, push never went out.
    @session.notifications.create!(notification_type: "needs_input", transition_marker: 11)

    @mock_service.expects(:send_to_all).never
    @mock_broadcast_service.expects(:notification_badge).never

    assert_no_difference -> { Notification.count } do
      @job.perform(@session.id, :needs_input, nil, 11)
    end
  end

  test "RecordNotUnique race resolves to existing row without raising" do
    @session.update_columns(
      status: Session.statuses[:needs_input],
      transcript: nil,
      custom_metadata: { "needs_input_count" => 9 }
    )

    # Simulate a parallel job winning the partial unique index by pre-creating
    # the notification, then forcing find_or_create_by! down its insert path
    # (where it will hit the unique constraint and raise RecordNotUnique). The
    # rescue in find_or_create_notification should resolve to the existing row.
    existing = @session.notifications.create!(notification_type: "needs_input", transition_marker: 9)

    Notification.any_instance.stubs(:save).raises(ActiveRecord::RecordNotUnique.new("duplicate key"))

    @mock_service.expects(:send_to_all).never

    assert_no_difference -> { Notification.count } do
      @job.perform(@session.id, :needs_input, nil, 9)
    end

    assert Notification.exists?(existing.id)
  end
end
