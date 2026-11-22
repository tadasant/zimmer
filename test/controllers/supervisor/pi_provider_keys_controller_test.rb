require "test_helper"

module Supervisor
  class PiProviderKeysControllerTest < ActionDispatch::IntegrationTest
    setup do
      @row = PiProviderKey.create!(session_id: sessions(:running).id, key_hash: "hash-abc123", name: "zimmer-pi-tag-s1",
                                   limit_usd: 20, expires_at: 1.day.from_now, last_error: "OpenRouter answered 500")
    end

    test "index and show render the key's record" do
      get supervisor_pi_provider_keys_url
      assert_response :success

      get supervisor_pi_provider_key_url(@row)
      assert_response :success
      assert_match "hash-abc123", response.body
      assert_match "OpenRouter answered 500", response.body
    end

    test "the panel is read-only" do
      actions = Rails.application.routes.routes
        .select { |route| route.defaults[:controller] == "supervisor/pi_provider_keys" }
        .map { |route| route.defaults[:action] }

      assert_equal %w[index show], actions.sort
    end
  end
end
