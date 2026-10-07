# frozen_string_literal: true

module OauthServer
  # The two discovery documents a remote MCP client reads before anything else.
  #
  #   GET /.well-known/oauth-protected-resource/mcp   RFC 9728: /mcp, and who issues its tokens
  #   GET /.well-known/oauth-authorization-server     RFC 8414: this server's endpoints
  #
  # Each is also served at the other spelling clients probe (the bare
  # protected-resource path; the authorization-server path suffixed with /mcp).
  class MetadataController < BaseController
    def protected_resource
      no_store
      render json: {
        resource: oauth_config.resource,
        resource_name: "Zimmer",
        authorization_servers: [ oauth_config.issuer ],
        scopes_supported: [ OauthServer::SCOPE ],
        bearer_methods_supported: [ "header" ],
        resource_documentation: DOCUMENTATION_URL
      }
    end

    def authorization_server
      no_store
      issuer = oauth_config.issuer
      render json: {
        issuer: issuer,
        authorization_endpoint: "#{issuer}/oauth/authorize",
        token_endpoint: "#{issuer}/oauth/token",
        registration_endpoint: "#{issuer}/oauth/register",
        revocation_endpoint: "#{issuer}/oauth/revoke",
        response_types_supported: [ "code" ],
        response_modes_supported: [ "query" ],
        grant_types_supported: OauthServer::ClientMetadata::GRANT_TYPES,
        code_challenge_methods_supported: [ "S256" ],
        token_endpoint_auth_methods_supported: [ "none" ],
        revocation_endpoint_auth_methods_supported: [ "none" ],
        scopes_supported: [ OauthServer::SCOPE ],
        authorization_response_iss_parameter_supported: true,
        client_id_metadata_document_supported: true,
        service_documentation: DOCUMENTATION_URL
      }
    end

    DOCUMENTATION_URL = "https://docs.zimmer.tadasant.com/auth/mcp-authorization-server/"
  end
end
