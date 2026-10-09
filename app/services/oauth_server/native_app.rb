# frozen_string_literal: true

module OauthServer
  # Zimmer's own iOS app (`ios/`), as a client of this authorization server.
  #
  # The app signs in the way a remote MCP client does — PKCE, `/oauth/authorize`
  # behind the web sign-in wall (Google, then the second factor), a 60-second
  # code, `/oauth/token` — so the phone holds a revocable grant, never an API key
  # and never a Google credential. What differs is how it is known:
  #
  # - **It is built in, not registered.** The row is found or created on first
  #   use under a fixed `client_id`, so the app needs neither Dynamic Client
  #   Registration nor a metadata document, and a pruned registration can never
  #   strand it. `registration_type` is `first_party`, which the pruner skips.
  # - **Its redirect is a private-use URI scheme** (RFC 8252 §7.1), the reverse
  #   of the app's bundle id. A registered client may not use one — any app on a
  #   phone can claim a scheme — but this one URI is fixed here rather than
  #   claimed by a caller, and the code it carries is useless without the PKCE
  #   verifier that never left the app that started the flow (RFC 8252 §8.1).
  # - **Its tokens open the REST API** (`/api/v1`), which no other client's do.
  #   Api::BaseController checks `first_party?` on the grant's client.
  #
  # The consent screen names it, and its grants are listed and revoked on
  # Settings → API keys like any other connection.
  module NativeApp
    CLIENT_ID = "zimmer-ios"
    CLIENT_NAME = "Zimmer for iOS"
    REDIRECT_URI = "com.tadasant.zimmer:/oauth/callback"

    module_function

    # @return [OauthServer::Client]
    def client
      row = Client.find_by(client_id: CLIENT_ID) || create_client
      # The constants are the truth: a row written by an older build follows them.
      if row.redirect_uris != [ REDIRECT_URI ] || row.client_name != CLIENT_NAME
        row.update!(redirect_uris: [ REDIRECT_URI ], client_name: CLIENT_NAME)
      end
      row
    end

    def client_id?(client_id)
      client_id.to_s == CLIENT_ID
    end

    def create_client
      Client.create!(
        client_id: CLIENT_ID,
        registration_type: Client::FIRST_PARTY,
        client_name: CLIENT_NAME,
        redirect_uris: [ REDIRECT_URI ],
        grant_types: ClientMetadata::GRANT_TYPES
      )
    rescue ActiveRecord::RecordNotUnique
      # Two first sign-ins at once: the other request created it.
      Client.find_by!(client_id: CLIENT_ID)
    end
  end
end
