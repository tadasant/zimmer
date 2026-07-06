require "test_helper"

class PushSubscriptionTest < ActiveSupport::TestCase
  # Test attribute persistence
  test "should create push subscription with all required attributes" do
    subscription = PushSubscription.create!(
      endpoint: "https://push.example.com/subscription/123",
      p256dh_key: "BNcRdreALRFXTkOOUHK1EtK2wtaz5Ry4YfYCA_0QTpQtUbVlUls0VJXg7A8u-Ts1XbjhazAkj7I99e8QcYP7DkM",
      auth_key: "tBHItJI5svbpez7KI4CCXg"
    )

    subscription.reload
    assert_equal "https://push.example.com/subscription/123", subscription.endpoint
    assert_equal "BNcRdreALRFXTkOOUHK1EtK2wtaz5Ry4YfYCA_0QTpQtUbVlUls0VJXg7A8u-Ts1XbjhazAkj7I99e8QcYP7DkM", subscription.p256dh_key
    assert_equal "tBHItJI5svbpez7KI4CCXg", subscription.auth_key
  end

  test "should create push subscription with optional user_agent" do
    subscription = PushSubscription.create!(
      endpoint: "https://push.example.com/subscription/456",
      p256dh_key: "test_p256dh_key",
      auth_key: "test_auth_key",
      user_agent: "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)"
    )

    subscription.reload
    assert_equal "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)", subscription.user_agent
  end

  test "should allow nil user_agent" do
    subscription = PushSubscription.new(
      endpoint: "https://push.example.com/subscription/789",
      p256dh_key: "test_p256dh_key",
      auth_key: "test_auth_key",
      user_agent: nil
    )
    assert subscription.valid?
  end

  # Test validations - endpoint
  test "should require endpoint presence" do
    subscription = PushSubscription.new(
      p256dh_key: "test_p256dh_key",
      auth_key: "test_auth_key"
    )
    assert_not subscription.valid?
    assert_includes subscription.errors[:endpoint], "can't be blank"
  end

  test "should require unique endpoint" do
    PushSubscription.create!(
      endpoint: "https://push.example.com/duplicate",
      p256dh_key: "key1",
      auth_key: "auth1"
    )

    duplicate = PushSubscription.new(
      endpoint: "https://push.example.com/duplicate",
      p256dh_key: "key2",
      auth_key: "auth2"
    )
    assert_not duplicate.valid?
    assert_includes duplicate.errors[:endpoint], "has already been taken"
  end

  test "should not save subscription without endpoint" do
    subscription = PushSubscription.new(
      p256dh_key: "test_p256dh_key",
      auth_key: "test_auth_key"
    )
    assert_not subscription.save
  end

  # Test validations - p256dh_key
  test "should require p256dh_key presence" do
    subscription = PushSubscription.new(
      endpoint: "https://push.example.com/test",
      auth_key: "test_auth_key"
    )
    assert_not subscription.valid?
    assert_includes subscription.errors[:p256dh_key], "can't be blank"
  end

  test "should not save subscription without p256dh_key" do
    subscription = PushSubscription.new(
      endpoint: "https://push.example.com/test",
      auth_key: "test_auth_key"
    )
    assert_not subscription.save
  end

  # Test validations - auth_key
  test "should require auth_key presence" do
    subscription = PushSubscription.new(
      endpoint: "https://push.example.com/test",
      p256dh_key: "test_p256dh_key"
    )
    assert_not subscription.valid?
    assert_includes subscription.errors[:auth_key], "can't be blank"
  end

  test "should not save subscription without auth_key" do
    subscription = PushSubscription.new(
      endpoint: "https://push.example.com/test",
      p256dh_key: "test_p256dh_key"
    )
    assert_not subscription.save
  end

  # Test timestamps
  test "should have created_at timestamp" do
    subscription = PushSubscription.create!(
      endpoint: "https://push.example.com/timestamp-test",
      p256dh_key: "test_p256dh_key",
      auth_key: "test_auth_key"
    )
    assert_not_nil subscription.created_at
    assert_kind_of Time, subscription.created_at
  end

  test "should have updated_at timestamp" do
    subscription = PushSubscription.create!(
      endpoint: "https://push.example.com/updated-test",
      p256dh_key: "test_p256dh_key",
      auth_key: "test_auth_key"
    )
    assert_not_nil subscription.updated_at
    assert_kind_of Time, subscription.updated_at
  end

  # Test update
  test "should update p256dh_key" do
    subscription = PushSubscription.create!(
      endpoint: "https://push.example.com/update-key-test",
      p256dh_key: "original_key",
      auth_key: "test_auth_key"
    )

    subscription.update!(p256dh_key: "updated_key")
    subscription.reload
    assert_equal "updated_key", subscription.p256dh_key
  end

  test "should update auth_key" do
    subscription = PushSubscription.create!(
      endpoint: "https://push.example.com/update-auth-test",
      p256dh_key: "test_p256dh_key",
      auth_key: "original_auth"
    )

    subscription.update!(auth_key: "updated_auth")
    subscription.reload
    assert_equal "updated_auth", subscription.auth_key
  end

  # Test destroy
  test "should destroy subscription" do
    subscription = PushSubscription.create!(
      endpoint: "https://push.example.com/destroy-test",
      p256dh_key: "test_p256dh_key",
      auth_key: "test_auth_key"
    )

    assert_difference("PushSubscription.count", -1) do
      subscription.destroy!
    end
  end

  # Test queries
  test "should find subscription by endpoint" do
    subscription = PushSubscription.create!(
      endpoint: "https://push.example.com/find-test",
      p256dh_key: "test_p256dh_key",
      auth_key: "test_auth_key"
    )

    found = PushSubscription.find_by(endpoint: "https://push.example.com/find-test")
    assert_equal subscription.id, found.id
  end
end
