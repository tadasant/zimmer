# frozen_string_literal: true

require "test_helper"

# The egress-degraded banner lives in the application layout, so any full page
# render exercises it. Drive it off the same shared cache the job writes.
class NetworkHealthBannerTest < ActionDispatch::IntegrationTest
  setup do
    @original_cache = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
  end

  teardown do
    Rails.cache = @original_cache
  end

  test "renders the degraded banner on every page when egress is degraded" do
    Rails.cache.write(EgressHealthCheck::CACHE_KEY, {
      "status" => "degraded",
      "healthy" => false,
      "detail" => "primary resolver 127.0.0.11 could not resolve api.anthropic.com",
      "resolver" => "127.0.0.11",
      "consecutive_failures" => 3,
      "degraded_since" => Time.utc(2026, 7, 8, 19, 5).iso8601,
      "checked_at" => Time.current.iso8601
    })

    get root_path
    assert_response :success
    assert_includes response.body, "Network egress degraded"
    assert_includes response.body, "Since 19:05 UTC"
  end

  test "renders no banner when egress is healthy" do
    Rails.cache.write(EgressHealthCheck::CACHE_KEY, { "status" => "ok" })
    get root_path
    assert_response :success
    assert_not_includes response.body, "Network egress degraded"
  end

  test "renders no banner when no probe has run yet" do
    get root_path
    assert_response :success
    assert_not_includes response.body, "Network egress degraded"
  end
end
