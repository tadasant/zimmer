# frozen_string_literal: true

require "jwt"

# An in-process stand-in for strad's authorization server, plugged into
# TokenBroker::Client as its transport. It answers the four requests the broker
# makes — discovery, refresh, RFC 8693 token exchange, RFC 7009 revocation —
# in the shapes tadasant/strad#537 pins, and records every request so a test
# can assert what Zimmer sent.
#
# Each POST's `client_assertion` is verified the way strad verifies it
# (#532/#534): ES256 against the identity's published JWKS, `iss` = `sub` =
# the client id, `aud` the token endpoint, a fresh `jti`, `exp` at most 300s
# out. A request that fails that is answered `401 invalid_client`, as strad
# would.
class FakeStrad
  ORIGIN = "https://strad.example.com"
  RESOURCE = "#{ORIGIN}/mcp"
  TOKEN_ENDPOINT = "#{ORIGIN}/oauth/token"
  REVOKE_ENDPOINT = "#{ORIGIN}/oauth/revoke"

  Request = Struct.new(:method, :path, :params, :assertion_claims, keyword_init: true)

  attr_reader :requests, :revoked
  attr_accessor :exchange_failure, :refresh_failure, :revoke_failure, :token_exchange_advertised,
    :child_expires_in, :parent_expires_in

  def initialize
    @requests = []
    @revoked = []
    @seen_jtis = Set.new
    @counter = 0
    @token_exchange_advertised = true
    @child_expires_in = 21_600
    @parent_expires_in = 3600
  end

  def client(**) = TokenBroker::Client.new(transport: self, **)

  def call(uri, request)
    path = uri.path
    if request.is_a?(Net::HTTP::Get)
      return metadata_response if path == "/.well-known/oauth-authorization-server"

      return json(404, { error: "not_found" })
    end

    params = URI.decode_www_form(request.body.to_s).to_h
    claims = verify_assertion(params, path)
    @requests << Request.new(method: "POST", path: path, params: params, assertion_claims: claims)
    return json(401, { error: "invalid_client", error_description: @assertion_error }) unless claims

    case path
    when "/oauth/token" then token(params)
    when "/oauth/revoke" then revoke(params)
    else json(404, { error: "not_found" })
    end
  end

  def exchanges = requests.select { |r| r.params["grant_type"] == TokenBroker::Client::TOKEN_EXCHANGE_GRANT }
  def refreshes = requests.select { |r| r.params["grant_type"] == "refresh_token" }
  def revocations = requests.select { |r| r.path == "/oauth/revoke" }

  # A grant row as consent would have stored it, issued to the configured
  # identity (call inside `with_oauth_client_identity`).
  def create_grant!(**overrides)
    McpBrokerGrant.create!({
      authorization_server: ORIGIN,
      issuer: ORIGIN,
      token_endpoint: TOKEN_ENDPOINT,
      revocation_endpoint: REVOKE_ENDPOINT,
      resource: RESOURCE,
      client_id: OauthClientIdentity.client_id,
      access_token: "strad_oat_parent#{SecureRandom.hex(8)}",
      refresh_token: "strad_ort_parent#{SecureRandom.hex(8)}",
      access_token_expires_at: 1.hour.from_now,
      scope: "mcp",
      status: "active",
      consented_at: Time.current
    }.merge(overrides))
  end

  private

  def token(params)
    case params["grant_type"]
    when "refresh_token"
      return json(*refresh_failure) if refresh_failure

      @counter += 1
      json(200, { access_token: "strad_oat_refreshed#{@counter}#{SecureRandom.hex(6)}", token_type: "Bearer",
                  refresh_token: "strad_ort_rotated#{@counter}#{SecureRandom.hex(6)}", expires_in: parent_expires_in, scope: "mcp" })
    when TokenBroker::Client::TOKEN_EXCHANGE_GRANT
      return json(*exchange_failure) if exchange_failure
      return json(400, { error: "invalid_request", error_description: "subject_token_type is required" }) unless params["subject_token_type"] == TokenBroker::Client::ACCESS_TOKEN_TYPE
      return json(400, { error: "invalid_scope", error_description: "name at least one slug:" }) unless params["scope"].to_s.split.all? { |s| s.start_with?("slug:") }

      @counter += 1
      json(200, { access_token: "strad_oat_child#{@counter}#{SecureRandom.hex(8)}",
                  issued_token_type: TokenBroker::Client::ACCESS_TOKEN_TYPE, token_type: "Bearer",
                  expires_in: [ params["expires_in"].to_i, child_expires_in ].min, scope: params["scope"].split.sort.join(" ") })
    else
      json(400, { error: "unsupported_grant_type" })
    end
  end

  def revoke(params)
    return json(*revoke_failure) if revoke_failure

    @revoked << params["token"]
    Net::HTTPOK.new("1.1", "200", "OK").tap { |r| stub_body(r, "") }
  end

  def verify_assertion(params, path)
    @assertion_error = nil
    assertion = params["client_assertion"]
    unless params["client_assertion_type"] == OauthClientIdentity::ASSERTION_TYPE && assertion
      @assertion_error = "client assertion required"
      return nil
    end

    jwks = JWT::JWK::Set.new(JSON.parse(OauthClientIdentity.jwks.to_json))
    claims, = JWT.decode(assertion, nil, true, algorithms: %w[ES256 RS256], jwks: jwks)
    expected_aud = [ TOKEN_ENDPOINT, ORIGIN, (path == "/oauth/revoke" ? REVOKE_ENDPOINT : nil) ].compact
    errors = []
    errors << "iss must equal client_id" unless claims["iss"] == params.fetch("client_id", claims["iss"]) && claims["iss"] == claims["sub"]
    errors << "wrong aud" unless expected_aud.include?(claims["aud"])
    errors << "exp too far out" unless claims["exp"].to_i <= Time.now.to_i + 300
    errors << "jti replayed" unless @seen_jtis.add?(claims["jti"])
    if errors.any?
      @assertion_error = errors.join(", ")
      return nil
    end
    claims
  rescue JWT::DecodeError => e
    @assertion_error = e.message
    nil
  end

  def metadata_response
    grants = %w[authorization_code refresh_token]
    grants << TokenBroker::Client::TOKEN_EXCHANGE_GRANT if token_exchange_advertised
    json(200, { issuer: ORIGIN, authorization_endpoint: "#{ORIGIN}/oauth/authorize", token_endpoint: TOKEN_ENDPOINT,
                revocation_endpoint: REVOKE_ENDPOINT, grant_types_supported: grants })
  end

  def json(status, body)
    klass = Net::HTTPResponse::CODE_TO_OBJ[status.to_s] || Net::HTTPResponse
    response = klass.new("1.1", status.to_s, "")
    response["Content-Type"] = "application/json"
    stub_body(response, body.is_a?(String) ? body : JSON.generate(body))
    response
  end

  def stub_body(response, body)
    response.instance_variable_set(:@read, true)
    response.instance_variable_set(:@body, body)
  end
end
