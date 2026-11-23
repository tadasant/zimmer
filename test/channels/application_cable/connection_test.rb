# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"

# The cable's half of the web login wall: every Turbo Stream arrives over this
# one WebSocket, so with the gate on a browser without a sign-in cookie is
# refused at connect.
class ApplicationCable::ConnectionTest < ActionCable::Connection::TestCase
  include WebAuthTestHelpers
  include SecurityTelemetryTestHelpers

  CLIENT_HEADERS = { "User-Agent" => "TestBrowser/1.0", "Origin" => "https://zimmer.example.com" }.freeze

  def signed_in_identity
    WebIdentity.create!(google_sub: "sub-cable", email: "owner@example.com", hosted_domain: "example.com",
      totp_secret: WebAuth::Totp.generate_secret, totp_enrolled_at: 1.day.ago)
  end

  test "with the gate off, anyone connects, as before" do
    WebAuth::Configuration.stubs(:current).returns(WebAuth::Configuration.new({}))

    connect
    assert_nil connection.web_identity
  end

  test "with the gate on, a connection without a sign-in cookie is refused" do
    enable_web_auth

    assert_reject_connection { connect }
  end

  test "with the gate on, a signed-in browser connects as its identity" do
    configuration = enable_web_auth
    identity = signed_in_identity
    cookies.encrypted[WebAuth::Cookies::SIGN_IN] = { value: { "id" => identity.id, "g" => identity.session_generation, "f" => "totp", "r" => Time.current.to_i } }

    connect
    assert_equal identity, connection.web_identity
    assert configuration.totp_required?
  end

  test "a sign-in cookie from before a sign-out-everywhere is refused" do
    enable_web_auth
    identity = signed_in_identity
    cookies.encrypted[WebAuth::Cookies::SIGN_IN] = { value: { "id" => identity.id, "g" => identity.session_generation, "f" => "totp", "r" => Time.current.to_i } }
    identity.sign_out_everywhere!

    assert_reject_connection { connect }
  end

  test "a store that has never answered refuses rather than guesses" do
    WebAuth::Configuration.stubs(:current).raises(WebAuth::Configuration::Unavailable, "down")

    assert_reject_connection { connect }
  end

  # `connect` above is called directly. This goes through Action Cable's own
  # open handler, whose rescue is what turns a refusal into a closed socket.
  test "a refused socket is closed as unauthorized, with no reconnect and no welcome" do
    socket = Class.new do
      attr_reader :frames, :closed
      def initialize = @frames = []
      def protocol = "actioncable-v1-json"
      def alive? = true
      def transmit(frame) = @frames << JSON.parse(frame)
      def close = @closed = true
    end

    enable_web_auth
    ordinary = socket.new
    open_through_action_cable(ordinary)

    WebAuth::Configuration.stubs(:current).raises(WebAuth::Configuration::Unavailable, "down")
    unavailable = socket.new
    open_through_action_cable(unavailable)

    [ ordinary, unavailable ].each do |refused|
      assert_equal [ { "type" => "disconnect", "reason" => "unauthorized", "reconnect" => false } ], refused.frames
      assert refused.closed
    end
  end

  # --- what a refusal logs and counts ----------------------------------------

  test "a browser with no cookie is an ordinary refusal: WARN, counted, client named" do
    enable_web_auth

    line = assert_refused(:warn, "no_cookie")
    assert_includes line, 'ip="203.0.113.9"'
    assert_includes line, 'user_agent="TestBrowser/1.0"'
    assert_includes line, 'origin="https://zimmer.example.com"'
  end

  test "a cookie past the expiry in its payload is an ordinary refusal" do
    enable_web_auth(session_days: "1")
    sign_in_with(signed_in_identity, at: 2.days.ago)

    assert_refused(:warn, "expired")
  end

  test "a cookie past the expiry sealed into it is expired, not unreadable" do
    configuration = enable_web_auth(session_days: "1")
    use_real_cookie_jar
    WebAuth::Cookies.sign_in(cookies, signed_in_identity, configuration, factor: "totp")
    sealed = cookies[WebAuth::Cookies::SIGN_IN]

    travel 2.days do
      use_real_cookie_jar(WebAuth::Cookies::SIGN_IN.to_s => sealed)
      refute_includes assert_refused(:warn, "expired"), sealed
    end
  end

  test "signed out everywhere is an ordinary refusal" do
    enable_web_auth
    identity = signed_in_identity
    sign_in_with(identity)
    identity.sign_out_everywhere!

    assert_refused(:warn, "signed_out_everywhere")
  end

  test "a cookie issued without the required second factor is an ordinary refusal" do
    enable_web_auth
    sign_in_with(signed_in_identity, factor: "none")

    assert_refused(:warn, "second_factor_missing")
  end

  test "a configuration that cannot be read is an ERROR" do
    WebAuth::Configuration.stubs(:current).raises(WebAuth::Configuration::Unavailable, "the secret store did not answer")

    assert_includes assert_refused(:error, "configuration_unavailable"), "the secret store did not answer"
  end

  test "a misconfigured gate is an ERROR whatever the cookie, and names the problem" do
    enable_web_auth(client_secret: nil)

    line = assert_refused(:error, "misconfigured")
    assert_includes line, 'cookie="no_cookie"'
    assert_includes line, "ZIMMER_WEB_AUTH_GOOGLE_CLIENT_SECRET is not set"
  end

  test "a misconfigured gate still connects a browser that is signed in" do
    enable_web_auth(client_secret: nil)
    identity = signed_in_identity
    sign_in_with(identity)

    connect
    assert_equal identity, connection.web_identity
  end

  test "a cookie this deployment cannot decrypt is an ERROR that does not quote it" do
    enable_web_auth
    use_real_cookie_jar(WebAuth::Cookies::SIGN_IN.to_s => "bm90LW91cnM=--aXY=--dGFn")

    refute_includes assert_refused(:error, "unreadable_cookie"), "bm90LW91cnM"
  end

  test "a cookie that is not valid UTF-8 is refused like any other unreadable one" do
    enable_web_auth
    use_real_cookie_jar(WebAuth::Cookies::SIGN_IN.to_s => "\xFF")
    assert_refused(:error, "unreadable_cookie")

    use_real_cookie_jar(WebAuth::Cookies::SIGN_IN.to_s => " ")
    assert_refused(:warn, "no_cookie")
  end

  test "a cookie sealed under another key is an ERROR" do
    configuration = enable_web_auth
    use_real_cookie_jar
    cookies.request.set_header(ActionDispatch::Cookies::GENERATOR_KEY, ActiveSupport::KeyGenerator.new("a rotated secret_key_base"))
    WebAuth::Cookies.sign_in(cookies, signed_in_identity, configuration, factor: "totp")
    use_real_cookie_jar(WebAuth::Cookies::SIGN_IN.to_s => cookies[WebAuth::Cookies::SIGN_IN])

    assert_refused(:error, "unreadable_cookie")
  end

  test "a cookie that decrypts to something other than a sign-in is an ERROR" do
    enable_web_auth
    use_real_cookie_jar
    cookies.encrypted[WebAuth::Cookies::SIGN_IN] = { value: "not a hash", expires: 1.day.from_now }

    assert_refused(:error, "unreadable_cookie")
  end

  test "a real sealed cookie connects" do
    configuration = enable_web_auth
    use_real_cookie_jar
    identity = signed_in_identity
    WebAuth::Cookies.sign_in(cookies, identity, configuration, factor: "totp")

    connect
    assert_equal identity, connection.web_identity
  end

  test "an identity that is gone, or whose domain is no longer allowed, is an ERROR" do
    enable_web_auth
    identity = signed_in_identity
    sign_in_with(identity)
    identity.update!(hosted_domain: "dropped.example")
    assert_refused(:error, "domain_not_allowed")

    identity.destroy!
    assert_refused(:error, "identity_missing")
  end

  test "headers cannot forge a log line, flood it, or keep the connection open" do
    enable_web_auth

    request = ActionDispatch::TestRequest.create("HTTP_X_FORWARDED_FOR" => "203.0.113.9", "HTTP_CLIENT_IP" => "198.51.100.7")
    disagreeing = ActionDispatch::RemoteIp::GetIp.new(request, true, ActionDispatch::RemoteIp::TRUSTED_PROXIES)
    line = assert_refused(:warn, "no_cookie", remote_ip: disagreeing,
      headers: { "User-Agent" => "x\n\xFF ERROR forged #{"y" * 1000}", "Origin" => "z" * 1000 })
    refute_includes line, "\n"
    assert_operator line.length, :<, 1000
    assert_includes line, "conflicting Client-Ip and X-Forwarded-For"
  end

  test "every ordinary reason is one SecurityTelemetry counts" do
    assert_empty ApplicationCable::Connection::ORDINARY_REFUSALS - SecurityTelemetry::AUTH_FAILURE_REASONS.fetch("web_cable")
  end

  private

  def open_through_action_cable(socket)
    connection = ApplicationCable::Connection.new(ActionCable.server, ActionDispatch::TestRequest.create.env)
    connection.instance_variable_set(:@websocket, socket)
    connection.send(:handle_open)
  end

  def sign_in_with(identity, factor: "totp", at: Time.current)
    cookies.encrypted[WebAuth::Cookies::SIGN_IN] = { value: { "id" => identity.id, "g" => identity.session_generation, "f" => factor, "r" => at.to_i } }
  end

  # The test case's own jar does no encryption, so anything about reading a
  # sealed cookie needs Rails' real one.
  def use_real_cookie_jar(raw = {})
    @cookie_jar = ActionDispatch::Cookies::CookieJar.build(ActionDispatch::TestRequest.create, raw)
  end

  # Asserts a refusal, its one log line at `severity`, nothing else at ERROR,
  # and one count under `reason`.
  #
  # @return [String] the log line
  def assert_refused(severity, reason, headers: CLIENT_HEADERS, remote_ip: "203.0.113.9")
    entries = nil
    report = with_security_telemetry do
      entries = capture_log_entries { assert_reject_connection { connect(headers: headers, env: { "action_dispatch.remote_ip" => remote_ip }) } }
    end

    refusals = entries.select { |_, message| message.include?("An unauthorized connection attempt was rejected") }
    assert_equal [ severity.to_s.upcase ], refusals.map(&:first)
    assert_includes refusals.first.last, "reason=#{reason.inspect}"
    errors = entries.select { |level, _| %w[ERROR FATAL].include?(level) }
    assert_equal severity == :error ? 1 : 0, errors.size, errors.inspect

    counts = report[:auth_failures_by_kind_and_reason]["web_cable"]
    assert_equal({ reason => 1 }, counts.select { |_, count| count.positive? })
    refusals.first.last
  end
end
