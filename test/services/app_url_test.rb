require "test_helper"

class AppUrlTest < ActiveSupport::TestCase
  # The meaningful behavior: the host is read from the deploy-provisioned
  # ZIMMER_*_BASE_URL secret, not hardcoded. This is the regression guard for the
  # bug where generated links ignored the env var and pointed at a placeholder.
  test "production reads ZIMMER_PROD_BASE_URL set by the deploy" do
    original = ENV["ZIMMER_PROD_BASE_URL"]
    ENV["ZIMMER_PROD_BASE_URL"] = "https://zimmer.example.org/"

    # Trailing slash is trimmed so callers can append "/sessions/..." safely.
    assert_equal "https://zimmer.example.org", AppUrl.base_url(env: "production")
  ensure
    if original.nil?
      ENV.delete("ZIMMER_PROD_BASE_URL")
    else
      ENV["ZIMMER_PROD_BASE_URL"] = original
    end
  end

  test "staging reads ZIMMER_STAGING_BASE_URL set by the deploy" do
    original = ENV["ZIMMER_STAGING_BASE_URL"]
    ENV["ZIMMER_STAGING_BASE_URL"] = "https://staging.zimmer.example.org"

    assert_equal "https://staging.zimmer.example.org", AppUrl.base_url(env: "staging")
  ensure
    if original.nil?
      ENV.delete("ZIMMER_STAGING_BASE_URL")
    else
      ENV["ZIMMER_STAGING_BASE_URL"] = original
    end
  end

  # When the deploy has NOT set the secret, fall back to a placeholder host. The
  # real host is never baked into the image — it comes from the deploy config.
  test "production falls back to the placeholder host when the secret is unset" do
    original = ENV.delete("ZIMMER_PROD_BASE_URL")

    assert_equal AppUrl::PLACEHOLDER_PROD_BASE_URL, AppUrl.base_url(env: "production")
  ensure
    ENV["ZIMMER_PROD_BASE_URL"] = original if original
  end

  test "staging falls back to the placeholder host when the secret is unset" do
    original = ENV.delete("ZIMMER_STAGING_BASE_URL")

    assert_equal AppUrl::PLACEHOLDER_STAGING_BASE_URL, AppUrl.base_url(env: "staging")
  ensure
    ENV["ZIMMER_STAGING_BASE_URL"] = original if original
  end

  test "local development falls back to localhost" do
    local_override = ENV.delete("ZIMMER_LOCAL_BASE_URL")

    assert_equal "http://localhost:3000", AppUrl.base_url(env: "development")
  ensure
    ENV["ZIMMER_LOCAL_BASE_URL"] = local_override if local_override
  end

  test "local development honors ZIMMER_LOCAL_BASE_URL override" do
    original = ENV["ZIMMER_LOCAL_BASE_URL"]
    ENV["ZIMMER_LOCAL_BASE_URL"] = "http://localhost:9999"

    assert_equal "http://localhost:9999", AppUrl.base_url(env: "development")
  ensure
    if original.nil?
      ENV.delete("ZIMMER_LOCAL_BASE_URL")
    else
      ENV["ZIMMER_LOCAL_BASE_URL"] = original
    end
  end
end
