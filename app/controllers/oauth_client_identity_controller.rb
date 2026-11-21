# frozen_string_literal: true

# Zimmer's identity as an OAuth client (OauthClientIdentity), published for the
# authorization servers it connects to:
#
#   GET /oauth-client/metadata.json   the Client ID Metadata Document; its URL is the client_id
#   GET /oauth-client/jwks.json       the public keys client assertions verify against
#
# Public on purpose, and nothing but public: client metadata and public keys. An
# authorization server fetches both unauthenticated when it first sees the
# client_id and when it verifies an assertion, so both sit outside the web UI's
# sign-in gate the way the OAuth discovery documents do. An edge that gates the
# whole host still gates them; opening them there is a separate change.
#
# 404 when the identity is not configured, so a deployment that never turned it
# on does not advertise a client that cannot sign.
class OauthClientIdentityController < ActionController::API
  def metadata
    return head(:not_found) unless OauthClientIdentity.enabled?

    response.set_header("Cache-Control", "public, max-age=300")
    render json: OauthClientIdentity.metadata_document
  end

  def jwks
    return head(:not_found) unless OauthClientIdentity.enabled?

    keys = OauthClientIdentity.jwks
    response.set_header("Cache-Control", "public, max-age=300")
    render json: keys
  rescue OauthClientIdentity::Unavailable => e
    # The reason names configuration (a KMS resource, an env var), so it goes to
    # the log, not to an unauthenticated caller.
    Rails.logger.error("[OauthClientIdentity] JWKS unavailable: #{e.message}")
    response.set_header("Cache-Control", "no-store")
    render json: { error: "temporarily_unavailable" }, status: :service_unavailable
  end
end
