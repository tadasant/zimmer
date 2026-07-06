# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"

class WebPushServiceTest < ActiveSupport::TestCase
  setup do
    @mock_webpush = mock("WebPush")
    @service = WebPushService.new(webpush_client: @mock_webpush)

    # Create test subscriptions
    @subscription1 = PushSubscription.create!(
      endpoint: "https://push.example.com/sub1",
      p256dh_key: "test_p256dh_key_1",
      auth_key: "test_auth_key_1"
    )
    @subscription2 = PushSubscription.create!(
      endpoint: "https://push.example.com/sub2",
      p256dh_key: "test_p256dh_key_2",
      auth_key: "test_auth_key_2"
    )

    # Stub WebpushConfig to be configured
    @vapid_keys = {
      public_key: "test_public_key",
      private_key: "test_private_key",
      subject: "mailto:test@example.com"
    }

    # Create a mock HTTP response for testing WebPush exceptions
    @mock_response = stub(code: "410", body: "Gone")
  end

  teardown do
    PushSubscription.delete_all
  end

  # === send_to_all tests ===

  test "send_to_all returns skipped when VAPID keys not configured" do
    WebpushConfig.stubs(:configured?).returns(false)

    result = @service.send_to_all(title: "Test", body: "Body")

    assert_equal 0, result[:sent]
    assert_equal 0, result[:failed]
    assert_equal 0, result[:expired]
    assert result[:skipped]
  end

  test "send_to_all sends to all subscriptions when configured" do
    WebpushConfig.stubs(:configured?).returns(true)
    WebpushConfig.stubs(:vapid_keys).returns(@vapid_keys)
    @mock_webpush.expects(:payload_send).twice.returns(true)

    result = @service.send_to_all(title: "Test", body: "Body")

    assert_equal 2, result[:sent]
    assert_equal 0, result[:failed]
    assert_equal 0, result[:expired]
    assert_nil result[:skipped]
  end

  test "send_to_all includes URL in payload when provided" do
    WebpushConfig.stubs(:configured?).returns(true)
    WebpushConfig.stubs(:vapid_keys).returns(@vapid_keys)
    @mock_webpush.expects(:payload_send).twice.with(
      has_entry(:message, includes('"url":"/sessions/123"'))
    ).returns(true)

    @service.send_to_all(title: "Test", body: "Body", url: "/sessions/123")
  end

  test "send_to_all handles mixed results" do
    WebpushConfig.stubs(:configured?).returns(true)
    WebpushConfig.stubs(:vapid_keys).returns(@vapid_keys)

    # First subscription succeeds
    @mock_webpush.expects(:payload_send).with(
      has_entry(:endpoint, @subscription1.endpoint)
    ).returns(true)

    # Second subscription fails
    @mock_webpush.expects(:payload_send).with(
      has_entry(:endpoint, @subscription2.endpoint)
    ).raises(StandardError.new("Network error"))

    result = @service.send_to_all(title: "Test", body: "Body")

    assert_equal 1, result[:sent]
    assert_equal 1, result[:failed]
    assert_equal 0, result[:expired]
  end

  # === send_to_subscription tests ===

  test "send_to_subscription returns :sent on success" do
    WebpushConfig.stubs(:vapid_keys).returns(@vapid_keys)
    @mock_webpush.expects(:payload_send).returns(true)

    result = @service.send_to_subscription(@subscription1, title: "Test", body: "Body")

    assert_equal :sent, result
  end

  test "send_to_subscription deletes subscription and returns :expired on ExpiredSubscription" do
    WebpushConfig.stubs(:vapid_keys).returns(@vapid_keys)
    @mock_webpush.expects(:payload_send).raises(WebPush::ExpiredSubscription.new(@mock_response, "push.example.com"))

    result = @service.send_to_subscription(@subscription1, title: "Test", body: "Body")

    assert_equal :expired, result
    assert_nil PushSubscription.find_by(id: @subscription1.id)
  end

  test "send_to_subscription deletes subscription and returns :expired on InvalidSubscription" do
    WebpushConfig.stubs(:vapid_keys).returns(@vapid_keys)
    @mock_webpush.expects(:payload_send).raises(WebPush::InvalidSubscription.new(@mock_response, "push.example.com"))

    result = @service.send_to_subscription(@subscription1, title: "Test", body: "Body")

    assert_equal :expired, result
    assert_nil PushSubscription.find_by(id: @subscription1.id)
  end

  test "send_to_subscription returns :failed on ResponseError" do
    WebpushConfig.stubs(:vapid_keys).returns(@vapid_keys)
    @mock_webpush.expects(:payload_send).raises(WebPush::ResponseError.new(@mock_response, "push.example.com"))

    result = @service.send_to_subscription(@subscription1, title: "Test", body: "Body")

    assert_equal :failed, result
    # Subscription should still exist
    assert PushSubscription.exists?(@subscription1.id)
  end

  test "send_to_subscription returns :failed on network error" do
    WebpushConfig.stubs(:vapid_keys).returns(@vapid_keys)
    @mock_webpush.expects(:payload_send).raises(StandardError.new("Connection refused"))

    result = @service.send_to_subscription(@subscription1, title: "Test", body: "Body")

    assert_equal :failed, result
    # Subscription should still exist
    assert PushSubscription.exists?(@subscription1.id)
  end

  test "send_to_subscription passes correct parameters to webpush" do
    WebpushConfig.stubs(:vapid_keys).returns(@vapid_keys)
    @mock_webpush.expects(:payload_send).with(
      message: anything,
      endpoint: @subscription1.endpoint,
      p256dh: @subscription1.p256dh_key,
      auth: @subscription1.auth_key,
      vapid: @vapid_keys,
      urgency: "normal"
    ).returns(true)

    @service.send_to_subscription(@subscription1, title: "Test", body: "Body")
  end

  # === Payload building tests ===

  test "payload includes title and body" do
    WebpushConfig.stubs(:vapid_keys).returns(@vapid_keys)
    captured_message = nil
    @mock_webpush.expects(:payload_send).with { |args|
      captured_message = JSON.parse(args[:message])
      true
    }.returns(true)

    @service.send_to_subscription(@subscription1, title: "My Title", body: "My Body")

    assert_equal "My Title", captured_message["title"]
    assert_equal "My Body", captured_message["body"]
  end

  test "payload includes icon and badge" do
    WebpushConfig.stubs(:vapid_keys).returns(@vapid_keys)
    captured_message = nil
    @mock_webpush.expects(:payload_send).with { |args|
      captured_message = JSON.parse(args[:message])
      true
    }.returns(true)

    @service.send_to_subscription(@subscription1, title: "Test", body: "Body")

    assert_equal "/icons/icon-192x192.png", captured_message["icon"]
    assert_equal "/icons/icon-192x192.png", captured_message["badge"]
  end

  test "payload includes URL in data when provided" do
    WebpushConfig.stubs(:vapid_keys).returns(@vapid_keys)
    captured_message = nil
    @mock_webpush.expects(:payload_send).with { |args|
      captured_message = JSON.parse(args[:message])
      true
    }.returns(true)

    @service.send_to_subscription(@subscription1, title: "Test", body: "Body", url: "/sessions/42")

    assert_equal "/sessions/42", captured_message["data"]["url"]
  end

  test "payload includes custom data" do
    WebpushConfig.stubs(:vapid_keys).returns(@vapid_keys)
    captured_message = nil
    @mock_webpush.expects(:payload_send).with { |args|
      captured_message = JSON.parse(args[:message])
      true
    }.returns(true)

    @service.send_to_subscription(
      @subscription1,
      title: "Test",
      body: "Body",
      data: { session_id: 123, type: "test" }
    )

    assert_equal 123, captured_message["data"]["session_id"]
    assert_equal "test", captured_message["data"]["type"]
  end

  # === Edge cases ===

  test "send_to_all with no subscriptions returns zero counts" do
    PushSubscription.delete_all

    WebpushConfig.stubs(:configured?).returns(true)
    WebpushConfig.stubs(:vapid_keys).returns(@vapid_keys)

    result = @service.send_to_all(title: "Test", body: "Body")

    assert_equal 0, result[:sent]
    assert_equal 0, result[:failed]
    assert_equal 0, result[:expired]
  end

  test "send_to_all handles all subscriptions expiring" do
    WebpushConfig.stubs(:configured?).returns(true)
    WebpushConfig.stubs(:vapid_keys).returns(@vapid_keys)
    @mock_webpush.expects(:payload_send).twice.raises(WebPush::ExpiredSubscription.new(@mock_response, "push.example.com"))

    result = @service.send_to_all(title: "Test", body: "Body")

    assert_equal 0, result[:sent]
    assert_equal 0, result[:failed]
    assert_equal 2, result[:expired]
    assert_equal 0, PushSubscription.count
  end
end
