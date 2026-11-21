# frozen_string_literal: true

require "net/http"

module TokenBroker
  # The broker's four requests to an authorization server, in the exact shapes
  # strad's token-exchange contract pins (tadasant/strad#537, its contract test
  # "the contract with Zimmer's broker"):
  #
  # - discovery: `GET <origin>/.well-known/oauth-authorization-server`
  # - refresh:   `POST <token_endpoint>` grant_type=refresh_token
  # - exchange:  `POST <token_endpoint>` RFC 8693 token exchange
  # - revoke:    `POST <revocation_endpoint>` RFC 7009
  #
  # Every POST carries a fresh `private_key_jwt` assertion from Zimmer's
  # hosted client identity (OauthClientIdentity), audience the token endpoint.
  #
  # Nothing here logs or raises with a response body that could hold a token.
  # Errors carry the server's `error` and `error_description` only.
  class Client
    TIMEOUT = 15

    TOKEN_EXCHANGE_GRANT = "urn:ietf:params:oauth:grant-type:token-exchange"
    ACCESS_TOKEN_TYPE = "urn:ietf:params:oauth:token-type:access_token"

    Tokens = Struct.new(:access_token, :refresh_token, :expires_in, :scope, keyword_init: true)
    Metadata = Struct.new(:issuer, :authorization_endpoint, :token_endpoint, :revocation_endpoint,
      :grant_types_supported, keyword_init: true)

    # Any failure to get an answer, or a refusal that is not about the grant.
    class Error < StandardError
      attr_reader :status, :oauth_error

      def initialize(message, status: nil, oauth_error: nil)
        super(message)
        @status = status
        @oauth_error = oauth_error
      end

      # Worth trying again later: the server did not answer, or said so.
      def transient? = status.nil? || status >= 500
    end

    # The authorization server refused the refresh token itself
    # (`invalid_grant`): the grant is revoked, expired or was replayed.
    class GrantRejected < Error; end

    # @param transport [#call, nil] `(uri, request) -> Net::HTTPResponse`;
    #   Net::HTTP when nil. Tests pass a recorder to assert the exact requests.
    def initialize(transport: nil)
      @transport = transport
    end

    # @param origin [String] normalized origin
    # @return [Metadata]
    def discover(origin)
      response = get("#{origin}/.well-known/oauth-authorization-server")
      raise Error.new("#{origin} has no OAuth authorization server metadata (HTTP #{response.code})", status: response.code.to_i) unless response.code == "200"

      body = parse_json(response) || raise(Error, "#{origin} returned authorization server metadata that is not JSON")
      Metadata.new(
        issuer: body["issuer"],
        authorization_endpoint: body["authorization_endpoint"],
        token_endpoint: body["token_endpoint"],
        revocation_endpoint: body["revocation_endpoint"],
        grant_types_supported: Array(body["grant_types_supported"])
      )
    end

    # @param grant [McpBrokerGrant]
    # @return [Tokens]
    def refresh(grant)
      params = {
        grant_type: "refresh_token",
        refresh_token: grant.refresh_token,
        client_id: grant.client_id
      }
      params[:resource] = grant.resource if grant.resource.present?

      response = post(grant, grant.token_endpoint, params)
      body = parse_json(response)
      if response.code == "200" && body.is_a?(Hash) && body["access_token"].present?
        return tokens_from(body)
      end

      raise refusal("refreshing the grant", response, body, grant_rejected: body.is_a?(Hash) && body["error"] == "invalid_grant")
    end

    # RFC 8693 token exchange for one child token.
    #
    # @param grant [McpBrokerGrant]
    # @param subject_token [String] the grant's current access token
    # @param scopes [Array<String>] exactly the child's scope
    # @param label [String] strad's `label` extension (the session id)
    # @param expires_in [Integer] seconds asked for; strad may give less
    # @return [Tokens]
    def exchange(grant, subject_token:, scopes:, label:, expires_in:)
      params = {
        grant_type: TOKEN_EXCHANGE_GRANT,
        client_id: grant.client_id,
        subject_token: subject_token,
        subject_token_type: ACCESS_TOKEN_TYPE,
        requested_token_type: ACCESS_TOKEN_TYPE,
        scope: scopes.join(" "),
        expires_in: expires_in.to_i,
        label: label
      }
      params[:resource] = grant.resource if grant.resource.present?

      response = post(grant, grant.token_endpoint, params)
      body = parse_json(response)
      if response.code == "200" && body.is_a?(Hash) && body["access_token"].present?
        return tokens_from(body)
      end

      raise refusal("exchanging for a child token", response, body)
    end

    # RFC 7009. A `200` is success whether or not the token was still live.
    #
    # @param grant [McpBrokerGrant]
    # @param token [String]
    # @return [true]
    def revoke(grant, token, token_type_hint: "access_token")
      endpoint = grant.revocation_endpoint.presence
      raise Error.new("#{grant.authorization_server} advertises no revocation endpoint", status: 400) unless endpoint

      response = post(grant, endpoint, { token: token, token_type_hint: token_type_hint, client_id: grant.client_id })
      return true if response.code == "200"

      raise refusal("revoking a token", response, parse_json(response))
    end

    private

    def tokens_from(body)
      Tokens.new(
        access_token: body["access_token"],
        refresh_token: body["refresh_token"].presence,
        expires_in: body["expires_in"]&.to_i,
        scope: body["scope"]
      )
    end

    def refusal(what, response, body, grant_rejected: false)
      oauth_error = body.is_a?(Hash) ? body["error"].to_s.presence : nil
      description = body.is_a?(Hash) ? body["error_description"].to_s.presence : nil
      detail = [ oauth_error, description ].compact.join(": ").presence || "no OAuth error in the response"
      message = "#{what} failed with HTTP #{response.code} (#{detail.truncate(300)})"
      (grant_rejected ? GrantRejected : Error).new(message, status: response.code.to_i, oauth_error: oauth_error)
    end

    def post(grant, endpoint, params)
      unless OauthClientIdentity.owns_client_id?(grant.client_id)
        raise Error, "the grant for #{grant.authorization_server} was issued to client #{grant.client_id}, " \
          "which is not the client identity this deployment presents (#{OauthClientIdentity.client_id || 'none configured'})"
      end

      uri = URI(endpoint)
      unless HttpsTokenEndpoint.secure?(uri)
        raise Error, "refusing to send credentials to #{HttpsTokenEndpoint.describe(uri)}: the endpoint must be https"
      end

      # Signed before anything is sent, so a KMS outage never half-sends.
      form = params.merge(McpOauthService.new.client_assertion_params(grant.token_endpoint))
      request = Net::HTTP::Post.new(uri.request_uri)
      request["Accept"] = "application/json"
      request["User-Agent"] = McpOauthService::USER_AGENT
      request.set_form_data(form)
      perform(uri, request)
    end

    def get(url)
      uri = URI(url)
      raise Error, "refusing to fetch metadata over #{uri.scheme}" unless uri.is_a?(URI::HTTPS)

      request = Net::HTTP::Get.new(uri.request_uri)
      request["Accept"] = "application/json"
      request["User-Agent"] = McpOauthService::USER_AGENT
      perform(uri, request)
    end

    def perform(uri, request)
      return @transport.call(uri, request) if @transport

      Net::HTTP.start(uri.hostname, uri.port, use_ssl: uri.scheme == "https",
        open_timeout: TIMEOUT, read_timeout: TIMEOUT) do |http|
        http.request(request)
      end
    rescue Timeout::Error, SocketError, SystemCallError, OpenSSL::SSL::SSLError, Net::HTTPBadResponse, IOError => e
      raise Error, "#{uri.host} did not answer (#{e.class})"
    end

    def parse_json(response)
      JSON.parse(response.body.to_s)
    rescue JSON::ParserError
      nil
    end
  end
end
