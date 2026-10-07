# frozen_string_literal: true

module OauthServer
  # POST /oauth/register — Dynamic Client Registration (RFC 7591).
  #
  # Open: no initial access token, because the connector dialog a human pastes
  # Zimmer's URL into has nowhere to put one. Registering grants nothing — a
  # client still needs a signed-in human from an allowed domain to consent at
  # /oauth/authorize before it holds any credential.
  class RegistrationsController < BaseController
    def create
      doc = JSON.parse(request.raw_post.presence || "null")
      client = OauthServer::Client.register!(doc)
      Rails.logger.info("[oauth_server] registered client #{client.client_id} (#{client.client_name.inspect}) for #{client.redirect_uris.join(', ')}")

      no_store
      render status: :created, json: {
        client_id: client.client_id,
        client_id_issued_at: client.created_at.to_i,
        client_name: client.client_name,
        redirect_uris: client.redirect_uris,
        grant_types: client.grant_types,
        response_types: [ "code" ],
        token_endpoint_auth_method: "none",
        scope: OauthServer::SCOPE
      }.compact
    rescue JSON::ParserError
      render_oauth_error(OauthServer::Error.new("invalid_client_metadata", "the request body is not valid JSON"), status: :bad_request)
    rescue OauthServer::Error => e
      render_oauth_error(e, status: :bad_request)
    end
  end
end
