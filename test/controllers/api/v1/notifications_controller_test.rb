# frozen_string_literal: true

require "test_helper"

class Api::V1::NotificationsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @valid_api_key = "test_api_key_12345"
    @headers = { "X-API-Key" => @valid_api_key }
    ENV["API_KEYS"] = @valid_api_key
    @session = sessions(:needs_input)
    @notification = notifications(:default_notification)
  end

  teardown do
    ENV.delete("API_KEYS")
  end

  # Authentication tests
  test "should return 401 without API key" do
    get api_v1_notifications_path
    assert_response :unauthorized
  end

  test "should return 401 with invalid API key" do
    get api_v1_notifications_path, headers: { "X-API-Key" => "invalid" }
    assert_response :unauthorized
  end

  # Index tests
  test "should return list of notifications" do
    get api_v1_notifications_path, headers: @headers
    assert_response :success

    json = JSON.parse(response.body)
    assert json.key?("notifications")
    assert json.key?("pagination")
  end

  test "should only return active notifications" do
    stale = Notification.create!(session: @session, notification_type: "needs_input", stale: true)

    get api_v1_notifications_path, headers: @headers
    assert_response :success

    json = JSON.parse(response.body)
    ids = json["notifications"].map { |n| n["id"] }
    assert_not_includes ids, stale.id
  end

  test "should filter by read status" do
    read_notif = Notification.create!(session: @session, notification_type: "needs_input", read: true)

    get api_v1_notifications_path, params: { status: "unread" }, headers: @headers
    assert_response :success

    json = JSON.parse(response.body)
    json["notifications"].each do |n|
      assert_equal false, n["read"]
    end
  end

  test "should filter for read notifications" do
    Notification.create!(session: @session, notification_type: "needs_input", read: true)

    get api_v1_notifications_path, params: { status: "read" }, headers: @headers
    assert_response :success

    json = JSON.parse(response.body)
    json["notifications"].each do |n|
      assert_equal true, n["read"]
    end
  end

  test "should paginate notifications" do
    get api_v1_notifications_path, params: { per_page: 1 }, headers: @headers
    assert_response :success

    json = JSON.parse(response.body)
    assert json["notifications"].length <= 1
  end

  test "should include session info in notifications" do
    get api_v1_notifications_path, headers: @headers
    assert_response :success

    json = JSON.parse(response.body)
    notif = json["notifications"].first
    if notif
      assert notif.key?("session")
      assert notif["session"].key?("id")
      assert notif["session"].key?("status")
    end
  end

  # Show tests
  test "should return single notification" do
    get api_v1_notification_path(@notification), headers: @headers
    assert_response :success

    json = JSON.parse(response.body)
    assert_equal @notification.id, json["notification"]["id"]
  end

  test "should return notification with all expected fields" do
    get api_v1_notification_path(@notification), headers: @headers
    assert_response :success

    json = JSON.parse(response.body)["notification"]
    %w[id session_id notification_type read stale created_at updated_at].each do |field|
      assert json.key?(field), "Expected field '#{field}' to be present"
    end
  end

  test "should return 404 for nonexistent notification" do
    get api_v1_notification_path(999999), headers: @headers
    assert_response :not_found
  end

  # Badge tests
  test "should return badge count" do
    get badge_api_v1_notifications_path, headers: @headers
    assert_response :success

    json = JSON.parse(response.body)
    assert json.key?("pending_count")
    assert_kind_of Integer, json["pending_count"]
  end

  # Mark read tests
  test "should mark notification as read" do
    assert_not @notification.read

    patch mark_read_api_v1_notification_path(@notification), headers: @headers
    assert_response :success

    json = JSON.parse(response.body)
    assert_equal true, json["notification"]["read"]
    assert @notification.reload.read
  end

  # Mark all read tests
  test "should mark all notifications as read" do
    # Create additional unread notifications
    Notification.create!(session: @session, notification_type: "needs_input", read: false)
    Notification.create!(session: @session, notification_type: "needs_input", read: false)

    patch mark_all_read_api_v1_notifications_path, headers: @headers
    assert_response :success

    json = JSON.parse(response.body)
    assert json.key?("marked_count")
    assert json.key?("pending_count")
    assert_equal 0, json["pending_count"]
  end

  # Dismiss tests
  test "should dismiss read notification" do
    @notification.mark_read!

    assert_difference("Notification.count", -1) do
      delete dismiss_api_v1_notification_path(@notification), headers: @headers
    end

    assert_response :no_content
  end

  test "should reject dismissing unread notification" do
    assert_not @notification.read

    assert_no_difference("Notification.count") do
      delete dismiss_api_v1_notification_path(@notification), headers: @headers
    end

    assert_response :unprocessable_entity
  end

  # Dismiss all read tests
  test "should dismiss all read notifications" do
    Notification.create!(session: @session, notification_type: "needs_input", read: true)
    Notification.create!(session: @session, notification_type: "needs_input", read: true)

    delete dismiss_all_read_api_v1_notifications_path, headers: @headers
    assert_response :success

    json = JSON.parse(response.body)
    assert json.key?("dismissed_count")
    assert json.key?("pending_count")
  end

  # Response format tests
  test "should return JSON with correct content type" do
    get api_v1_notifications_path, headers: @headers
    assert_equal "application/json; charset=utf-8", response.content_type
  end

  # Push notification tests
  test "push should return 401 without API key" do
    post api_v1_notifications_push_path, params: { session_id: @session.id, message: "Test" }
    assert_response :unauthorized
  end

  test "push should return 401 with invalid API key" do
    post api_v1_notifications_push_path, params: { session_id: @session.id, message: "Test" },
         headers: { "X-API-Key" => "invalid" }
    assert_response :unauthorized
  end

  test "should return 422 when session_id is missing" do
    post api_v1_notifications_push_path, params: { message: "Test" }, headers: @headers
    assert_response :unprocessable_entity

    json = JSON.parse(response.body)
    assert_equal "Missing parameter", json["error"]
    assert_includes json["message"], "session_id"
  end

  test "should return 422 when message is missing" do
    post api_v1_notifications_push_path, params: { session_id: @session.id }, headers: @headers
    assert_response :unprocessable_entity

    json = JSON.parse(response.body)
    assert_equal "Missing parameter", json["error"]
    assert_includes json["message"], "message"
  end

  test "should return 404 when session does not exist" do
    post api_v1_notifications_push_path, params: { session_id: 999999, message: "Test" }, headers: @headers
    assert_response :not_found
  end

  test "should queue push notification job with valid params" do
    assert_enqueued_with(job: SendPushNotificationJob) do
      post api_v1_notifications_push_path, params: {
        session_id: @session.id,
        message: "Needs your attention"
      }, headers: @headers
    end

    assert_response :success
    json = JSON.parse(response.body)
    assert_equal true, json["success"]
    assert_equal "Push notification queued", json["message"]
    assert_equal @session.id, json["session_id"]
  end

  test "should work with any session status" do
    running_session = sessions(:running)

    assert_enqueued_with(job: SendPushNotificationJob) do
      post api_v1_notifications_push_path, params: {
        session_id: running_session.id,
        message: "Session needs attention"
      }, headers: @headers
    end

    assert_response :success
  end

  test "should pass custom message to the job" do
    assert_enqueued_with(
      job: SendPushNotificationJob,
      args: [ @session.id, :custom_message, "PR ready, needs approval" ]
    ) do
      post api_v1_notifications_push_path, params: {
        session_id: @session.id,
        message: "PR ready, needs approval"
      }, headers: @headers
    end
  end
end
