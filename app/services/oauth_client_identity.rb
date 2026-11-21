# frozen_string_literal: true

require "securerandom"

# Zimmer's own identity as an OAuth *client* of remote MCP servers' authorization
# servers: a hosted Client ID Metadata Document (CIMD), a published key set, and
# `private_key_jwt` client assertions (RFC 7523) signed by a key the backend can
# use but cannot read.
#
# This is the client side. Zimmer's authorization server, which *accepts* CIMD
# clients, is OauthServer::* and shares nothing with this.
#
# ## Off unless configured
#
# Two things must both be set before any of this does anything:
#
# - ZIMMER_OAUTH_CLIENT_BASE_URL — the public origin the document and the key set
#   are served from (`https://zimmer.tadasant.com`). The `client_id` is built from
#   it and never from a request's Host header, so a request cannot change who
#   Zimmer says it is.
# - a key source: ZIMMER_OAUTH_CLIENT_KMS_KEY_VERSIONS (GCP KMS, production) or
#   ZIMMER_OAUTH_CLIENT_SIGNING_KEYS (a local private key: development, tests and
#   the open-source build). See OauthClientIdentity::KeySet.
#
# And a server must opt in, through `"clientIdentity": "cimd"` in its catalog
# `oauth` block or `client_identity: cimd` in its `mcp_oauth_clients` entry. A
# server that does not opt in keeps today's client identity exactly; so does one
# that opts in on a deployment where the identity is not configured.
#
# ## What the follow-on token broker builds on
#
#   OauthClientIdentity.enabled?                      # configured at all?
#   OauthClientIdentity.client_id                     # the CIMD URL
#   OauthClientIdentity.client_assertion(audience:)   # a fresh signed JWT
#   OauthClientIdentity.assertion_params(audience:)   # the two form fields
#   OauthClientIdentity.owns_client_id?(client_id)    # is this ours?
module OauthClientIdentity
  # Raised when the identity is needed and cannot be produced: not configured,
  # or the signer failed. The message is safe to show and to log.
  class Unavailable < StandardError; end

  BASE_URL_ENV = "ZIMMER_OAUTH_CLIENT_BASE_URL"
  CLIENT_NAME_ENV = "ZIMMER_OAUTH_CLIENT_NAME"
  DEFAULT_CLIENT_NAME = "Zimmer"

  # The two public paths. Kept out of `/oauth/*`, which is Zimmer's own
  # authorization server (its consent page included), so an edge rule opening
  # these two cannot open anything else by accident.
  METADATA_PATH = "/oauth-client/metadata.json"
  JWKS_PATH = "/oauth-client/jwks.json"

  # The value a catalog `oauth.clientIdentity` / `mcp_oauth_clients.client_identity`
  # takes to opt a server in.
  OPT_IN_VALUE = "cimd"

  ASSERTION_TYPE = "urn:ietf:params:oauth:client-assertion-type:jwt-bearer"

  # How long a client assertion is valid. Short on purpose: it is posted once,
  # straight away, and a captured one must be useless quickly.
  ASSERTION_LIFETIME = 60

  module_function

  # Whether this deployment has a client identity to offer. Cheap: reads
  # configuration only, and never contacts KMS.
  def enabled?(env = ENV)
    base_url(env).present? && KeySet.configured?(env)
  end

  # Whether a server's configuration asks for this identity.
  def opted_in?(value)
    value.to_s.strip.casecmp?(OPT_IN_VALUE)
  end

  # Whether the flow for a server that set `value` should use this identity:
  # it asked for it, and the deployment can provide it. A server that asks on a
  # deployment that cannot gets today's behaviour and a warning, because the
  # catalog is shared between deployments and an open-source build has no key.
  def use_for?(value, server_name: nil)
    return false unless opted_in?(value)
    return true if enabled?

    Rails.logger.warn(
      "[OauthClientIdentity] #{server_name || 'a server'} opts into Zimmer's OAuth client identity, " \
      "but #{BASE_URL_ENV} or a signing key is not configured here; using the default client identity"
    )
    false
  end

  # The public origin, normalized: scheme and host lowercased, no trailing slash.
  # nil when unset or not an absolute https URL (http is accepted for localhost,
  # so a developer can run the whole flow on their machine).
  def base_url(env = ENV)
    raw = env[BASE_URL_ENV].to_s.strip
    return nil if raw.empty?

    uri = URI.parse(raw)
    return nil unless uri.host.present? && uri.path.in?([ "", "/" ]) && uri.query.nil? && uri.fragment.nil?
    return nil unless uri.scheme == "https" || (uri.scheme == "http" && local_host?(uri.host))

    port = uri.port && uri.port != uri.default_port ? ":#{uri.port}" : ""
    "#{uri.scheme.downcase}://#{uri.host.downcase}#{port}"
  rescue URI::InvalidURIError
    nil
  end

  def local_host?(host)
    host == "localhost" || host == "127.0.0.1" || host.end_with?(".localhost")
  end

  # The CIMD URL, which is the client_id.
  def client_id(env = ENV)
    origin = base_url(env)
    origin && "#{origin}#{METADATA_PATH}"
  end

  def jwks_uri(env = ENV)
    origin = base_url(env)
    origin && "#{origin}#{JWKS_PATH}"
  end

  # The redirect URI listed in the document, and the one a flow using this
  # identity must send: the hosted callback on the configured origin.
  def redirect_uri(env = ENV)
    origin = base_url(env)
    origin && "#{origin}/mcp_oauth/callback"
  end

  # Is this credential's or flow's client_id the identity this deployment
  # presents? A credential minted under it is refreshed with an assertion.
  def owns_client_id?(value, env = ENV)
    value.present? && (own = client_id(env)).present? && value == own
  end

  # Does this client_id have the shape of a hosted identity — an http(s) URL
  # ending in METADATA_PATH — whether or not it is the one configured here? A
  # credential issued under an identity this deployment no longer presents
  # cannot be refreshed, and must not be refreshed without its assertion.
  def hosted_client_id?(value)
    uri = URI.parse(value.to_s)
    uri.is_a?(URI::HTTP) && uri.path == METADATA_PATH
  rescue URI::InvalidURIError
    false
  end

  # The Client ID Metadata Document (MCP authorization, revision 2026-07-28,
  # client registration; draft-ietf-oauth-client-id-metadata-document). Public
  # metadata only: names, URLs and the auth method. No key material — that is
  # what `jwks_uri` is for. No `token_endpoint_auth_signing_alg` either: it is
  # optional, and naming it would make serving this document depend on reaching
  # KMS. Each JWK carries its own `alg`.
  def metadata_document(env = ENV)
    {
      client_id: client_id(env),
      client_name: env[CLIENT_NAME_ENV].presence || DEFAULT_CLIENT_NAME,
      client_uri: base_url(env),
      redirect_uris: [ redirect_uri(env) ],
      grant_types: %w[authorization_code refresh_token],
      response_types: %w[code],
      token_endpoint_auth_method: "private_key_jwt",
      jwks_uri: jwks_uri(env)
    }
  end

  # The public JWK Set: every published key, the active signer first. More than
  # one during a rotation, so a verifier holding an assertion signed by either
  # key can check it.
  def jwks(env = ENV)
    { keys: KeySet.from_env(env).published.map(&:public_jwk) }
  end

  # A signed client assertion for one token request.
  #
  # @param audience [String] the token endpoint the assertion is posted to
  # @return [String] a compact JWS
  # @raise [Unavailable]
  def client_assertion(audience:, env: ENV, now: Time.current)
    id = client_id(env)
    raise Unavailable, "Zimmer's OAuth client identity is not configured (#{BASE_URL_ENV} and a signing key)" unless id && KeySet.configured?(env)
    raise Unavailable, "a client assertion needs the token endpoint as its audience" if audience.blank?

    issued_at = now.to_i
    claims = {
      iss: id,
      sub: id,
      aud: audience,
      iat: issued_at,
      exp: issued_at + ASSERTION_LIFETIME,
      jti: SecureRandom.uuid
    }
    KeySet.from_env(env).active.sign_jwt(claims)
  end

  # The form fields RFC 7523 §2.2 adds to a token request.
  def assertion_params(audience:, env: ENV)
    {
      client_assertion_type: ASSERTION_TYPE,
      client_assertion: client_assertion(audience: audience, env: env)
    }
  end

  # Drops the memoized key set. Tests, and anything that changes the env.
  def reset!
    KeySet.reset!
  end
end
