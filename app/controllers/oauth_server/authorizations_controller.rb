# frozen_string_literal: true

module OauthServer
  # /oauth/authorize — where a human consents to an MCP client connecting to
  # Zimmer's `/mcp` as them.
  #
  #   GET  /oauth/authorize   validate the request, then show the consent screen
  #   POST /oauth/authorize   the human's decision; on approve, redirect back with a code
  #
  # The only browser page of the authorization server, so the only one on
  # ApplicationController: it sits behind the web UI's sign-in wall
  # (WebSignInRequired), which sends a signed-out browser through Google and
  # back to this exact URL, and it has the CSRF check that keeps another origin
  # from submitting the consent form.
  # The POST carries the request's parameters back as hidden fields and is
  # validated from scratch, so no pending state is stored between the two.
  #
  # A redirect to the client is a privilege: until the client and its
  # redirect_uri are verified, every error is a page here, never a redirect to a
  # URI nobody has vouched for. After that, errors go back to the client the way
  # RFC 6749 §4.1.2.1 says.
  #
  # The human must be signed in, and their email must be in an allowed domain
  # (OauthServer::Config#allowed_domains). Neither holding means no code. With
  # the wall off there is nobody signed in, so nothing is issued — except in
  # development and test, where ZIMMER_DEV_WEB_USER_EMAIL names a user so the
  # flow can be walked on a laptop.
  class AuthorizationsController < ApplicationController
    DEV_EMAIL_ENV = "ZIMMER_DEV_WEB_USER_EMAIL"

    CHALLENGE_FORMAT = /\A[A-Za-z0-9\-._~]{43}\z/

    # Error pages and the consent page render without the app chrome.
    layout "oauth_server"

    # Prepended, so the wall's own redirect to /login carries these headers too.
    prepend_before_action :harden_response

    rescue_from OauthServer::Error, with: :render_error_page

    def new
      prepare!
      prepare_consent_page
    end

    # Approving takes a privilege level, and there is no default: whether this
    # client's messages are recorded as the human's own words is a choice the
    # human makes here, on purpose, every time a client is connected. An approval
    # without one re-renders the page rather than guessing either way.
    def create
      prepare!

      if params[:decision] != "approve"
        Rails.logger.info("[oauth_server] #{@email} denied #{@client.client_id.inspect}")
        return redirect_to_client(error: "access_denied", error_description: "the request was denied")
      end

      privilege = params[:privilege].to_s
      unless OauthServer::PRIVILEGES.include?(privilege)
        prepare_consent_page
        @privilege_error = "Choose what this connection may do before approving it."
        return render :new, status: :unprocessable_entity
      end

      _row, code = OauthServer::AuthorizationCode.issue!(
        client: @client, redirect_uri: @redirect_uri, code_challenge: @code_challenge,
        resource: oauth_config.resource, user_email: @email, scope: OauthServer.scope_for(privilege)
      )
      Rails.logger.info("[oauth_server] #{@email} approved #{@client.client_id.inspect} as #{privilege}; code issued for #{@redirect_uri}")
      redirect_to_client(code: code)
    end

    private

    # Validate the authorization request. Sets @email, @client, @redirect_uri,
    # @code_challenge and @state, or raises: OauthServer::Error before the
    # redirect_uri is trusted (a page), RedirectError after it (back to the client).
    #
    # Who is asking comes first. Until a signed-in human from an allowed domain is
    # on the other end, nothing else happens: no client metadata document is
    # fetched on a stranger's say-so, and no error is redirected to a URI that
    # anyone may register — which would make Zimmer an open redirector
    # (RFC 9700 §4.11.2).
    def prepare!
      @email = consenting_email
      raise NotSignedIn if @email.blank?
      raise DomainRefused, @email unless oauth_config.email_allowed?(@email)
      oauth_config.issuer # before any outbound fetch: an unconfigured server does nothing

      @client = OauthServer::Client.resolve!(params[:client_id])
      @redirect_uri = resolve_redirect_uri!
      @state = params[:state].presence

      raise RedirectError.new("unsupported_response_type", "response_type must be code") unless params[:response_type] == "code"
      raise RedirectError.new("invalid_request", "code_challenge_method must be S256") unless params[:code_challenge_method] == "S256"
      raise RedirectError.new("invalid_request", "code_challenge must be a 43-character S256 challenge") unless params[:code_challenge].to_s.match?(CHALLENGE_FORMAT)
      if params[:resource].present? && !oauth_config.resource_matches?(params[:resource])
        raise RedirectError.new("invalid_target", "resource must be #{oauth_config.resource}")
      end

      @code_challenge = params[:code_challenge]
      @resource = oauth_config.resource
    end

    def prepare_consent_page
      @client_metadata_host = @client.publisher_host
      @loopback_redirect = OauthServer::ClientMetadata.loopback_redirect?(@redirect_uri)
    end

    # The signed-in human the wall let through. With the wall off: nobody,
    # outside development and test.
    def consenting_email
      return current_web_identity&.email if web_auth_configuration.enabled?

      Rails.env.local? ? ENV[DEV_EMAIL_ENV].presence : nil
    end

    def resolve_redirect_uri!
      requested = params[:redirect_uri].presence
      if requested.nil?
        return @client.redirect_uris.first if @client.redirect_uris.one?

        raise OauthServer::Error.new("invalid_request", "redirect_uri is required: this client registered more than one")
      end
      return requested if @client.redirect_uri_registered?(requested)

      where = @client.cimd? ? "listed in the client's metadata document at #{@client.publisher_host}" : "registered for this client"
      raise OauthServer::Error.new("invalid_request", "redirect_uri #{requested.inspect} is not one #{where}")
    end

    class NotSignedIn < StandardError; end
    class DomainRefused < StandardError; end
    class RedirectError < OauthServer::Error; end

    rescue_from RedirectError do |error|
      Rails.logger.info("[oauth_server] authorize for #{@client.client_id.inspect} refused: #{error.code}: #{error.description}")
      redirect_to_client(error: error.code, error_description: error.description)
    end

    rescue_from OauthServer::Config::NotConfigured do |error|
      Rails.logger.warn("[oauth_server] #{request.request_method} #{request.path}: #{error.description}")
      @heading = "Connections are not set up on this deployment"
      @detail = error.description
      render :error, status: :service_unavailable
    end

    rescue_from NotSignedIn do
      @heading = "Sign in to Zimmer first"
      @detail = "Approving a connection names the person who approved it, and nobody is signed in. " \
        "This deployment has not turned on web sign-in, so it cannot issue a token for /mcp."
      render :error, status: :unauthorized
    end

    rescue_from DomainRefused do |error|
      domains = oauth_config.allowed_domains
      @heading = "This account cannot connect"
      @detail = if domains.empty?
        "No allowed sign-in domain is configured, so Zimmer issues no tokens for /mcp."
      else
        "Connections to Zimmer are restricted to #{domains.map { |d| "@#{d}" }.to_sentence(two_words_connector: ' or ', last_word_connector: ', or ')} accounts. You are signed in as #{error.message}."
      end
      render :error, status: :forbidden
    end

    def render_error_page(error)
      Rails.logger.info("[oauth_server] #{request.request_method} #{request.path} refused: #{error.code}: #{error.description}")
      @heading = "This connection request can't be completed"
      @detail = error.description
      render :error, status: :bad_request
    end

    def redirect_to_client(**response_params)
      response_params[:state] = @state if @state
      response_params[:iss] = oauth_config.issuer if oauth_config.configured?
      uri = URI.parse(@redirect_uri)
      query = URI.decode_www_form(uri.query.to_s) + response_params.compact.map { |k, v| [ k.to_s, v ] }
      uri.query = URI.encode_www_form(query)
      redirect_to uri.to_s, allow_other_host: true, status: :found
    end

    def harden_response
      response.set_header("Cache-Control", "no-store")
      # Not `no-referrer`: under it a browser posts the consent form with
      # `Origin: null`, and Rails' CSRF origin check refuses the approval.
      # `same-origin` still keeps this URL (state, challenge) from any other site.
      response.set_header("Referrer-Policy", "same-origin")
      response.set_header("X-Frame-Options", "DENY")
      response.set_header("Content-Security-Policy", "frame-ancestors 'none'")
    end

    def oauth_config
      @oauth_config ||= OauthServer::Config.current
    end
    helper_method :oauth_config
  end
end
