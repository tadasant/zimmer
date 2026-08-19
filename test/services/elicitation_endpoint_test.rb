# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"

class ElicitationEndpointTest < ActiveSupport::TestCase
  # The test env's cache is :null_store, which would make every write a no-op and
  # every status read nil. Swap in a real store so these tests drive the actual
  # record/read path rather than a store that agrees with everything.
  setup do
    @original_cache = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
    Rails.cache.delete(ElicitationEndpoint::CACHE_KEY)
  end

  teardown do
    Rails.cache = @original_cache
  end

  test "url is built from the app's own base URL" do
    AppUrl.stubs(:base_url).returns("https://zimmer.example.com")

    assert_equal "https://zimmer.example.com/api/v1/elicitations", ElicitationEndpoint.url
  end

  test "url does not double the slash when the base URL has a trailing one" do
    AppUrl.stubs(:base_url).returns("https://zimmer.example.com/")

    assert_equal "https://zimmer.example.com/api/v1/elicitations", ElicitationEndpoint.url
  end

  test "spawn_env names the endpoint and the session" do
    AppUrl.stubs(:base_url).returns("https://zimmer.example.com")

    env = ElicitationEndpoint.spawn_env(session_id: 886)

    assert_equal "https://zimmer.example.com/api/v1/elicitations", env["ELICITATION_REQUEST_URL"]
    assert_equal "886", env["ELICITATION_SESSION_ID"]
    assert_not env.key?("ELICITATION_ENABLED"), "enablement stays the server's decision"
  end

  # The client gates the whole HTTP fallback tier on `requestUrl && pollUrl`, so a
  # request URL without a poll URL leaves the fallback invisible and the approval
  # request never arrives.
  test "spawn_env names the poll URL alongside the request URL" do
    AppUrl.stubs(:base_url).returns("https://zimmer.example.com")

    env = ElicitationEndpoint.spawn_env(session_id: 886)

    assert_equal "https://zimmer.example.com/api/v1/elicitations", env["ELICITATION_POLL_URL"]
    assert_equal env["ELICITATION_REQUEST_URL"], env["ELICITATION_POLL_URL"],
      "the client appends /<request-id> to the collection URL, so both are the same address"
  end

  # Headless Claude Code advertises the native elicitation capability with no human
  # attached, so the default tier order asks the agent instead of the operator.
  test "spawn_env prefers the HTTP fallback over native elicitation" do
    env = ElicitationEndpoint.spawn_env(session_id: 886)

    assert_equal "true", env["ELICITATION_PREFER_HTTP_FALLBACK"]
  end

  # The client's own five-minute default would otherwise outrank this instance's
  # window, since it travels as `com.pulsemcp/expires-at` and that takes precedence.
  test "spawn_env carries this instance's expiry to the client's own deadline" do
    env = ElicitationEndpoint.spawn_env(session_id: 886)

    assert_equal (Elicitation::DEFAULT_EXPIRATION.to_i * 1000).to_s, env["ELICITATION_TTL_MS"]
  end

  test "spawn_env TTL follows the operator's expiration setting" do
    Elicitation.stubs(:default_expiration).returns(120.minutes)

    env = ElicitationEndpoint.spawn_env(session_id: 886)

    assert_equal (120 * 60 * 1000).to_s, env["ELICITATION_TTL_MS"]
  end

  test "every spawn_env key is declared in VARIABLES" do
    env = ElicitationEndpoint.spawn_env(session_id: 886)

    assert_equal [], env.keys - ElicitationEndpoint::VARIABLES,
      "both injection paths iterate VARIABLES, so a key missing from it is never written"
  end

  test "spawn_env omits the session tag when there is no session" do
    env = ElicitationEndpoint.spawn_env(session_id: nil)

    assert_not env.key?("ELICITATION_SESSION_ID")
    assert env["ELICITATION_REQUEST_URL"].present?
  end

  test "probe treats any HTTP response as reachable" do
    # 404 is the expected answer for the probe id and proves the request reached Rails.
    response = Net::HTTPNotFound.new("1.1", "404", "Not Found")
    Net::HTTP.stubs(:start).returns(response)

    result = ElicitationEndpoint.probe

    assert result.reachable
    assert_includes result.detail, "404"
  end

  test "probe reports a transport failure as unreachable" do
    # The production failure: the configured host does not resolve from the container.
    Net::HTTP.stubs(:start).raises(SocketError, "getaddrinfo: Name or service not known")

    result = ElicitationEndpoint.probe

    assert_not result.reachable
    assert_includes result.detail, "getaddrinfo"
  end

  test "unreachable? is false until a probe has actually observed a failure" do
    assert_not ElicitationEndpoint.unreachable?, "never probed must not read as broken"

    ElicitationEndpoint.record(ElicitationEndpoint::Result.new(reachable: true, detail: "HTTP 404", url: "u"))
    assert_not ElicitationEndpoint.unreachable?

    ElicitationEndpoint.record(ElicitationEndpoint::Result.new(reachable: false, detail: "SocketError", url: "u"))
    assert ElicitationEndpoint.unreachable?
  end

  test "record stores the detail and timestamp for the warning to quote" do
    now = Time.utc(2026, 7, 31, 12, 0, 0)
    stored = ElicitationEndpoint.record(
      ElicitationEndpoint::Result.new(reachable: false, detail: "SocketError: nope", url: "https://z/api/v1/elicitations"),
      now: now
    )

    assert_equal false, stored["reachable"]
    assert_equal "SocketError: nope", stored["detail"]
    assert_equal "https://z/api/v1/elicitations", stored["url"]
    assert_equal now.iso8601, stored["checked_at"]
    assert_equal stored, ElicitationEndpoint.status
  end

  test "status survives a cache failure without raising" do
    Rails.cache.stubs(:read).raises(RuntimeError, "redis down")

    assert_nil ElicitationEndpoint.status
    assert_not ElicitationEndpoint.unreachable?
  end
end
