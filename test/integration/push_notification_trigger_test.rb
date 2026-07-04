# frozen_string_literal: true

require "integration_test_helper"
require "mocha/minitest"

class PushNotificationTriggerTest < IntegrationTestCase
  # Tests that push notifications are NOT automatically triggered on session pause.
  #
  # Push notifications are now exclusively sent via the REST API endpoint
  # (POST /api/v1/notifications/push), allowing external tools like MCP servers
  # and the heartbeat agent to trigger them with custom messages.

  test "does not enqueue push notification when session pauses with empty queue" do
    session = Session.create!(
      git_root: "https://github.com/test/repo.git",
      prompt: "Test prompt",
      status: "running",
      agent_runtime: "claude_code"
    )

    assert session.enqueued_messages.pending.none?, "Session should have no pending messages"

    assert_no_enqueued_jobs(only: SendPushNotificationJob) do
      session.pause!
    end

    assert_equal "needs_input", session.status
  end

  test "does not enqueue push notification when queue has pending messages" do
    session = Session.create!(
      git_root: "https://github.com/test/repo.git",
      prompt: "Test prompt",
      status: "running",
      agent_runtime: "claude_code"
    )

    session.enqueued_messages.create!(
      content: "Follow-up message",
      position: 1,
      status: "pending"
    )

    assert_no_enqueued_jobs(only: SendPushNotificationJob) do
      session.pause!
    end

    assert_equal "needs_input", session.status
  end

  test "does not enqueue push notification when user explicitly pauses session" do
    session = Session.create!(
      git_root: "https://github.com/test/repo.git",
      prompt: "Test prompt",
      status: "running",
      agent_runtime: "claude_code"
    )

    session.update!(metadata: (session.metadata || {}).merge("paused_by" => "user"))

    assert_no_enqueued_jobs(only: SendPushNotificationJob) do
      session.pause!
    end

    assert_equal "needs_input", session.status
  end

  test "does not enqueue push notification when agent naturally pauses" do
    session = Session.create!(
      git_root: "https://github.com/test/repo.git",
      prompt: "Test prompt",
      status: "running",
      agent_runtime: "claude_code"
    )

    assert_no_enqueued_jobs(only: SendPushNotificationJob) do
      session.pause!
    end

    assert_equal "needs_input", session.status
  end

  test "clears paused_by metadata on resume" do
    session = Session.create!(
      git_root: "https://github.com/test/repo.git",
      prompt: "Test prompt",
      status: "needs_input",
      agent_runtime: "claude_code",
      metadata: { "paused_by" => "user" }
    )

    assert_equal "user", session.metadata&.dig("paused_by")

    session.resume!
    session.reload

    assert_nil session.metadata&.dig("paused_by")
  end

  # === Debounce behavior ===
  # When push_notifications_enabled is true, the needs_input push job is
  # scheduled with a wait window so brief running → needs_input → running
  # flaps don't generate notifications.

  test "flap within wait window does not produce a notification or push" do
    session = Session.create!(
      git_root: "https://github.com/test/repo.git",
      prompt: "Test prompt",
      status: "running",
      agent_runtime: "claude_code",
      push_notifications_enabled: true
    )

    session.pause!
    session.resume!

    # Run the deferred job — at this point the session is back in running and
    # the marker no longer matches needs_input. The job must no-op.
    perform_enqueued_jobs(only: SendPushNotificationJob)

    assert_equal 0, Notification.where(session: session).count,
      "Flap within wait window should not produce a Notification record"
  end

  test "genuine idle past wait window produces a single notification" do
    session = Session.create!(
      git_root: "https://github.com/test/repo.git",
      prompt: "Test prompt",
      status: "running",
      agent_runtime: "claude_code",
      push_notifications_enabled: true
    )

    # Stub WebPushService to avoid real HTTP calls.
    WebPushService.any_instance.stubs(:send_to_all).returns({ sent: 0, failed: 0, expired: 0, skipped: true })

    session.pause!
    perform_enqueued_jobs(only: SendPushNotificationJob)

    assert_equal 1, Notification.where(session: session).count,
      "A persistent needs_input should produce exactly one Notification"
    assert_equal "needs_input", Notification.where(session: session).first.notification_type
  end

  test "two flaps in a row do not produce double notifications" do
    session = Session.create!(
      git_root: "https://github.com/test/repo.git",
      prompt: "Test prompt",
      status: "running",
      agent_runtime: "claude_code",
      push_notifications_enabled: true
    )

    session.pause!   # marker = 1, schedules job 1
    session.resume!
    session.pause!   # marker = 2, schedules job 2
    session.resume!

    perform_enqueued_jobs(only: SendPushNotificationJob)

    assert_equal 0, Notification.where(session: session).count,
      "Two flaps should produce zero notifications"
  end

  test "genuine idle after a flap produces exactly one notification" do
    session = Session.create!(
      git_root: "https://github.com/test/repo.git",
      prompt: "Test prompt",
      status: "running",
      agent_runtime: "claude_code",
      push_notifications_enabled: true
    )

    WebPushService.any_instance.stubs(:send_to_all).returns({ sent: 0, failed: 0, expired: 0, skipped: true })

    session.pause!   # job 1 scheduled with marker = 1
    session.resume!
    session.pause!   # job 2 scheduled with marker = 2; session stays in needs_input

    perform_enqueued_jobs(only: SendPushNotificationJob)

    # Job 1 sees marker mismatch (current = 2) → skip.
    # Job 2 sees status = needs_input AND marker match → fire.
    assert_equal 1, Notification.where(session: session).count,
      "A genuine idle after a flap should produce exactly one notification"
  end
end
