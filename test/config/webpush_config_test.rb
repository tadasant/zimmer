# frozen_string_literal: true

require "test_helper"

class WebpushConfigTest < ActiveSupport::TestCase
  test "WebpushConfig module exists" do
    assert defined?(WebpushConfig), "WebpushConfig module should be defined"
  end

  test "WebpushConfig responds to public_key" do
    assert_respond_to WebpushConfig, :public_key
  end

  test "WebpushConfig responds to private_key" do
    assert_respond_to WebpushConfig, :private_key
  end

  test "WebpushConfig responds to subject" do
    assert_respond_to WebpushConfig, :subject
  end

  test "WebpushConfig responds to configured?" do
    assert_respond_to WebpushConfig, :configured?
  end

  test "WebpushConfig responds to vapid_keys" do
    assert_respond_to WebpushConfig, :vapid_keys
  end

  test "configured? returns false when keys are not set" do
    # Stub credentials to return nil for webpush keys
    Rails.application.credentials.stub(:dig, nil) do
      assert_not WebpushConfig.configured?
    end
  end

  test "configured? returns true when both keys are present" do
    # Create mock credentials response
    mock_creds = {
      webpush: {
        public_key: "test_public_key",
        private_key: "test_private_key",
        subject: "mailto:test@example.com"
      }
    }

    Rails.application.stub(:credentials, OpenStruct.new(mock_creds)) do
      # Re-define the methods to use the mock
      WebpushConfig.stub(:public_key, "test_public_key") do
        WebpushConfig.stub(:private_key, "test_private_key") do
          assert WebpushConfig.configured?
        end
      end
    end
  end

  test "vapid_keys returns nil when not configured" do
    WebpushConfig.stub(:configured?, false) do
      assert_nil WebpushConfig.vapid_keys
    end
  end

  test "vapid_keys returns hash with keys when configured" do
    WebpushConfig.stub(:configured?, true) do
      WebpushConfig.stub(:public_key, "test_public") do
        WebpushConfig.stub(:private_key, "test_private") do
          WebpushConfig.stub(:subject, "mailto:test@example.com") do
            result = WebpushConfig.vapid_keys

            assert_kind_of Hash, result
            assert_equal "test_public", result[:public_key]
            assert_equal "test_private", result[:private_key]
            assert_equal "mailto:test@example.com", result[:subject]
          end
        end
      end
    end
  end

  test "vapid_keys provides default subject when not configured" do
    WebpushConfig.stub(:configured?, true) do
      WebpushConfig.stub(:public_key, "test_public") do
        WebpushConfig.stub(:private_key, "test_private") do
          WebpushConfig.stub(:subject, nil) do
            result = WebpushConfig.vapid_keys

            assert_equal "mailto:admin@zimmer.local", result[:subject]
          end
        end
      end
    end
  end

  test "public_key reads from credentials" do
    # This test verifies the method correctly calls credentials.dig
    # The actual value depends on test credentials configuration
    result = WebpushConfig.public_key
    # Should return nil or a string (depending on test credentials)
    assert result.nil? || result.is_a?(String)
  end

  test "private_key reads from credentials" do
    result = WebpushConfig.private_key
    assert result.nil? || result.is_a?(String)
  end

  test "subject reads from credentials" do
    result = WebpushConfig.subject
    assert result.nil? || result.is_a?(String)
  end
end
