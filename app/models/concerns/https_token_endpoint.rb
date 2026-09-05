# frozen_string_literal: true

# One rule for every OAuth token endpoint Zimmer stores or posts to: it must be
# an `https://` URL with a host.
#
# The endpoint string decides two things at once. It says where the request goes,
# and — because `McpOauthService#post_form` sets `use_ssl: uri.scheme == "https"`
# — it says whether that request is encrypted. The request itself carries the
# OAuth `client_secret` as a form parameter, alongside either the authorization
# code (initial exchange) or the refresh token (renewal), so an `http://` value
# publishes long-lived credentials in a cleartext POST body. Nothing surfaces
# afterwards: whatever is listening answers `200` and the refresh reports success.
#
# The rule is exceptionless, loopback included. See McpOauthCredential's
# #token_endpoint_must_be_https comment for why.
module HttpsTokenEndpoint
  extend ActiveSupport::Concern

  MESSAGE = "must be an https:// URL with a host — Zimmer sends the OAuth client secret to it in a form body, " \
            "which an http:// endpoint would put on the wire in the clear"

  # Bound on .describe's output. The endpoint can come from a remote discovery
  # document, and its rendering lands in a flash message and a log line.
  DESCRIPTION_LIMIT = 200

  # True when `value` names an endpoint an OAuth client secret may be sent to.
  #
  # Anything that is not an https URL with a host is false, including the values
  # that look close enough to pass a `LIKE 'https://%'` filter: a bare
  # `https://`, a single-slash `https:/host/token`, a trailing space. An
  # unparseable string answers false rather than raising, so callers never have
  # to guard it.
  #
  # Userinfo is deliberately *permitted*: `McpOauthService#post_form` reads it
  # (`request.basic_auth(uri.user, uri.password) if uri.user`) because some
  # providers document `client_secret_basic` as credentials embedded in the
  # token URL, and over TLS those are as confidential as any other header. This
  # is where the rule differs from XOauthCredential's, whose transport overwrites
  # the Authorization header and would silently ignore them.
  #
  # @param value [String, URI::Generic, nil]
  # @return [Boolean]
  def self.secure?(value)
    uri = value.is_a?(URI::Generic) ? value : URI.parse(value.to_s)
    uri.is_a?(URI::HTTPS) && uri.host.present?
  rescue URI::Error
    false
  end

  # Renders an endpoint for a log line, a flash message or an exception without
  # carrying its userinfo along. The value can arrive from a remote server's
  # discovery document, so it is trusted to be neither short, clean nor
  # secret-free: userinfo is dropped, and the result is truncated so a server
  # cannot answer discovery with a kilobyte of path and have Zimmer render it.
  #
  # @param value [String, URI::Generic, nil]
  # @return [String]
  def self.describe(value)
    uri = value.is_a?(URI::Generic) ? value : URI.parse(value.to_s)
    return "(unusable URL)" if uri.host.blank?

    port = (uri.port && uri.port != uri.default_port) ? ":#{uri.port}" : ""
    "#{uri.scheme}://#{uri.host}#{port}#{uri.path}".truncate(DESCRIPTION_LIMIT)
  rescue URI::Error
    "(unparseable URL)"
  end

  private

  # Included models call this from a `validate`. Blank is not this validation's
  # business — a model that requires the endpoint says so with its own presence
  # validation, and one that treats a blank endpoint as "cannot refresh" (see
  # McpOauthCredential#can_refresh?) must keep being able to store nil.
  def token_endpoint_must_be_https
    return if token_endpoint.blank?
    return if HttpsTokenEndpoint.secure?(token_endpoint)

    errors.add(:token_endpoint, HttpsTokenEndpoint::MESSAGE)
  end
end
