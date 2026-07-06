require "test_helper"

class PushSubscriptionsControllerTest < ActionDispatch::IntegrationTest
  # Test create action - success cases
  test "should create push subscription with valid params" do
    assert_difference("PushSubscription.count", 1) do
      post push_subscriptions_url, params: {
        endpoint: "https://push.example.com/subscription/new-123",
        p256dh_key: "test_p256dh_key_value",
        auth_key: "test_auth_key_value"
      }, as: :json
    end

    assert_response :created
    json = JSON.parse(response.body)
    assert json.key?("id")
    assert json.key?("endpoint")
    assert json.key?("created_at")
    assert json.key?("updated_at")
  end

  test "should create push subscription with user_agent" do
    assert_difference("PushSubscription.count", 1) do
      post push_subscriptions_url, params: {
        endpoint: "https://push.example.com/subscription/ua-test",
        p256dh_key: "test_p256dh_key",
        auth_key: "test_auth_key",
        user_agent: "Mozilla/5.0 Test Browser"
      }, as: :json
    end

    assert_response :created
    subscription = PushSubscription.last
    assert_equal "Mozilla/5.0 Test Browser", subscription.user_agent
  end

  test "should return 201 created for new subscription" do
    post push_subscriptions_url, params: {
      endpoint: "https://push.example.com/subscription/201-test",
      p256dh_key: "test_key",
      auth_key: "test_auth"
    }, as: :json

    assert_response :created
  end

  test "should return JSON content type" do
    post push_subscriptions_url, params: {
      endpoint: "https://push.example.com/subscription/content-type-test",
      p256dh_key: "test_key",
      auth_key: "test_auth"
    }, as: :json

    assert_equal "application/json; charset=utf-8", response.content_type
  end

  # Test create action - upsert behavior
  test "should update existing subscription when endpoint already exists" do
    existing = PushSubscription.create!(
      endpoint: "https://push.example.com/subscription/existing",
      p256dh_key: "old_p256dh_key",
      auth_key: "old_auth_key"
    )

    assert_no_difference("PushSubscription.count") do
      post push_subscriptions_url, params: {
        endpoint: "https://push.example.com/subscription/existing",
        p256dh_key: "new_p256dh_key",
        auth_key: "new_auth_key"
      }, as: :json
    end

    assert_response :ok
    existing.reload
    assert_equal "new_p256dh_key", existing.p256dh_key
    assert_equal "new_auth_key", existing.auth_key
  end

  test "should return 200 when updating existing subscription" do
    PushSubscription.create!(
      endpoint: "https://push.example.com/subscription/200-test",
      p256dh_key: "old_key",
      auth_key: "old_auth"
    )

    post push_subscriptions_url, params: {
      endpoint: "https://push.example.com/subscription/200-test",
      p256dh_key: "new_key",
      auth_key: "new_auth"
    }, as: :json

    assert_response :ok
  end

  # Test create action - validation errors
  test "should reject subscription without endpoint" do
    assert_no_difference("PushSubscription.count") do
      post push_subscriptions_url, params: {
        p256dh_key: "test_key",
        auth_key: "test_auth"
      }, as: :json
    end

    assert_response :unprocessable_entity
    json = JSON.parse(response.body)
    assert_equal "Validation failed", json["error"]
    assert_includes json["messages"].join, "Endpoint"
  end

  test "should reject subscription without p256dh_key" do
    assert_no_difference("PushSubscription.count") do
      post push_subscriptions_url, params: {
        endpoint: "https://push.example.com/subscription/no-key",
        auth_key: "test_auth"
      }, as: :json
    end

    assert_response :unprocessable_entity
    json = JSON.parse(response.body)
    assert_includes json["messages"].join, "P256dh key"
  end

  test "should reject subscription without auth_key" do
    assert_no_difference("PushSubscription.count") do
      post push_subscriptions_url, params: {
        endpoint: "https://push.example.com/subscription/no-auth",
        p256dh_key: "test_key"
      }, as: :json
    end

    assert_response :unprocessable_entity
    json = JSON.parse(response.body)
    assert_includes json["messages"].join, "Auth key"
  end

  # Test destroy action
  test "should destroy push subscription" do
    subscription = PushSubscription.create!(
      endpoint: "https://push.example.com/subscription/to-destroy",
      p256dh_key: "test_key",
      auth_key: "test_auth"
    )

    assert_difference("PushSubscription.count", -1) do
      delete push_subscription_url(subscription)
    end

    assert_response :no_content
  end

  test "should return 204 no content on successful destroy" do
    subscription = PushSubscription.create!(
      endpoint: "https://push.example.com/subscription/204-test",
      p256dh_key: "test_key",
      auth_key: "test_auth"
    )

    delete push_subscription_url(subscription)
    assert_response :no_content
  end

  test "should return 404 for nonexistent subscription" do
    delete push_subscription_url(999999)
    assert_response :not_found

    json = JSON.parse(response.body)
    assert_equal "Not Found", json["error"]
    assert_equal "Subscription not found", json["message"]
  end

  # Test response format
  test "should return subscription ID on create" do
    post push_subscriptions_url, params: {
      endpoint: "https://push.example.com/subscription/id-test",
      p256dh_key: "test_key",
      auth_key: "test_auth"
    }, as: :json

    json = JSON.parse(response.body)
    assert json["id"].is_a?(Integer)
  end

  test "should return endpoint on create" do
    post push_subscriptions_url, params: {
      endpoint: "https://push.example.com/subscription/endpoint-test",
      p256dh_key: "test_key",
      auth_key: "test_auth"
    }, as: :json

    json = JSON.parse(response.body)
    assert_equal "https://push.example.com/subscription/endpoint-test", json["endpoint"]
  end

  test "should return timestamps in ISO8601 format" do
    post push_subscriptions_url, params: {
      endpoint: "https://push.example.com/subscription/timestamp-test",
      p256dh_key: "test_key",
      auth_key: "test_auth"
    }, as: :json

    json = JSON.parse(response.body)
    # Verify timestamps are valid ISO8601
    assert_nothing_raised { Time.iso8601(json["created_at"]) }
    assert_nothing_raised { Time.iso8601(json["updated_at"]) }
  end

  # Test CSRF protection is skipped (service worker calls don't send CSRF tokens)
  # Using `as: :json` automatically sets Content-Type and encodes the body properly
  test "should allow POST without CSRF token" do
    post push_subscriptions_url, params: {
      endpoint: "https://push.example.com/subscription/csrf-test",
      p256dh_key: "test_key",
      auth_key: "test_auth"
    }, as: :json

    assert_response :created
  end

  test "should allow DELETE without CSRF token" do
    subscription = PushSubscription.create!(
      endpoint: "https://push.example.com/subscription/csrf-delete-test",
      p256dh_key: "test_key",
      auth_key: "test_auth"
    )

    delete push_subscription_url(subscription), as: :json
    assert_response :no_content
  end

  # Test routing
  test "should route POST to create" do
    assert_routing(
      { method: :post, path: "/push_subscriptions" },
      { controller: "push_subscriptions", action: "create" }
    )
  end

  test "should route DELETE to destroy" do
    assert_routing(
      { method: :delete, path: "/push_subscriptions/1" },
      { controller: "push_subscriptions", action: "destroy", id: "1" }
    )
  end

  # Test that sensitive keys are not exposed in response
  test "should not expose p256dh_key in response" do
    post push_subscriptions_url, params: {
      endpoint: "https://push.example.com/subscription/security-test",
      p256dh_key: "secret_p256dh_key",
      auth_key: "secret_auth_key"
    }, as: :json

    json = JSON.parse(response.body)
    assert_not json.key?("p256dh_key")
    assert_not json.key?("auth_key")
  end
end
