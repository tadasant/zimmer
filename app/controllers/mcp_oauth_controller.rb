# Controller for handling MCP OAuth flows.
#
# This controller handles OAuth authentication flows for MCP servers that require
# OAuth credentials. It provides endpoints for:
# - Initiating OAuth flows for sessions
# - Handling OAuth callbacks
# - Checking OAuth status for sessions
#
# Supported flows:
#
# 1. User starts a session with MCP servers requiring OAuth
# 2. Session enters "waiting" state with oauth_required metadata
# 3. User clicks "Authorize" for each server requiring OAuth
# 4. Controller initiates OAuth flow, redirecting to OAuth provider
# 5. OAuth provider redirects back to callback with authorization code
# 6. Controller exchanges code for tokens, stores credentials
# 7. When all OAuth flows complete, session can proceed
class McpOauthController < ApplicationController
  # The real app-wide layout. (An earlier "application_shell" name pointed at a template
  # that does not exist in this repo — a leftover from the squashed AO import — so any
  # HTML render here, e.g. the error page or the manual authorization page, raised
  # MissingTemplate. "application" is the layout every other page uses.)
  layout "application"

  # POST/GET callback may not have CSRF token from OAuth provider.
  # Initiate and complete may also have stale CSRF tokens after deploys (the manual
  # authorization page can sit open while the user consents in another tab), so we skip
  # them there too.
  # Security is maintained via: valid session_id required, OAuth state parameter protection
  skip_forgery_protection only: [ :callback, :initiate, :complete ]

  # GET /mcp_oauth/status/:session_id
  # Returns the OAuth status for a session's MCP servers
  def status
    @session = Session.find(params[:session_id])
    @oauth_status = compute_oauth_status(@session)

    respond_to do |format|
      format.html { render partial: "mcp_oauth/status", locals: { session: @session, oauth_status: @oauth_status } }
      format.json { render json: @oauth_status }
    end
  end

  # POST /mcp_oauth/initiate
  # Initiates OAuth flow for a specific MCP server
  def initiate
    @session = Session.find(params[:session_id])
    server_name = params[:server_name]
    server_url = params[:server_url]

    # Check if we already have valid credentials
    credential_key = compute_credential_key(server_name, server_url)
    existing_credential = McpOauthCredential.for_credential_key(credential_key).active.first

    if existing_credential
      # A valid credential already exists, so this was never "the user must
      # authorize" — it is "the runtime never honored the token Zimmer already
      # holds" (typically the host-global needs-auth cache short-circuited the
      # connection). Clicking Authorize here used to only flash a notice and
      # redirect, leaving the banner in place — which reads to the user as "the
      # button does nothing". Re-inject the credential, clear the runtime's
      # needs-auth cache so the CLI actually retries, and resume the session.
      # Only promise a retry when the resume actually fired — if another required
      # server still needs auth (:partial) or re-injection failed, the session
      # stays parked and the message must not claim otherwise.
      resumed = reinject_and_resume(@session, server_name) == :resumed
      flash[:notice] = if resumed
        "#{server_name} is already authorized — retrying the session."
      else
        "#{server_name} is already authorized."
      end
      redirect_to session_path(@session)
      return
    end

    # Get the MCP server config for credential key computation
    mcp_server_config = get_mcp_server_config(server_name)

    oauth_service = McpOauthService.new

    # Check for pre-registered OAuth config first (takes precedence over server probing)
    # Some servers like BigQuery don't require auth for initialization but do for tool calls
    preregistered_oauth = PreregisteredOauthConfig.find_for_server(server_name)

    if preregistered_oauth
      # Thread the RFC 8707 resource indicator through the pre-registered path too, so
      # audience-binding servers accept the token. Derive it from the server URL the same
      # way the probe path does, unless the config sets an explicit `resource` (a blank
      # value suppresses it, for servers that reject an unexpected resource param).
      resource = if preregistered_oauth.resource.nil?
        oauth_service.canonical_resource(nil, server_url)
      else
        preregistered_oauth.resource.presence
      end

      # A configured redirect_uri (e.g. the localhost redirect the third-party client
      # permits) wins over Zimmer's hosted callback.
      redirect_uri = oauth_service.resolve_redirect_uri(preregistered_oauth.redirect_uri)

      oauth_metadata = {
        authorization_endpoint: preregistered_oauth.authorization_endpoint,
        token_endpoint: preregistered_oauth.token_endpoint,
        client_id: preregistered_oauth.client_id,
        client_secret: preregistered_oauth.client_secret,
        scopes: preregistered_oauth.scopes,
        resource: resource,
        manual: preregistered_oauth.manual? || oauth_service.manual_completion_required?(redirect_uri)
      }
      Rails.logger.info "[McpOauthController] Using pre-registered OAuth for #{server_name}"
    else
      # Fall back to probing the server to discover OAuth metadata via RFC 8414/9728.
      # Pass through any statically-configured client id from the catalog `oauth`
      # block so servers that require a pre-registered client (e.g. Slack) use it
      # instead of the `zimmer` placeholder.
      catalog_server = ServersConfig.find(server_name)
      requirement = oauth_service.check_oauth_requirement(
        server_url,
        configured_client_id: catalog_server&.oauth_client_id,
        configured_client_secret: catalog_server&.oauth_client_secret,
        configured_redirect_uri: catalog_server&.oauth_redirect_uri
      )

      unless requirement.required && requirement.metadata
        flash[:error] = "Could not determine OAuth requirements for #{server_name}"
        redirect_to session_path(@session)
        return
      end

      # The catalog `oauth` block configures the redirect URI on the same footing as
      # the client id above: a pre-registered client accepts only the redirects
      # registered against it at the provider, whether its endpoints came from the
      # catalog or from discovery. Servers without one keep the hosted callback.
      redirect_uri = oauth_service.resolve_redirect_uri(catalog_server&.oauth_redirect_uri)

      oauth_metadata = {
        authorization_endpoint: requirement.metadata.authorization_endpoint,
        token_endpoint: requirement.metadata.token_endpoint,
        registration_endpoint: requirement.metadata.registration_endpoint,
        client_id: requirement.metadata.client_id,
        client_secret: requirement.metadata.client_secret,
        scopes: requirement.metadata.scopes_supported&.join(" "),
        resource: requirement.metadata.resource,
        manual: oauth_service.manual_completion_required?(redirect_uri)
      }
    end

    unless oauth_metadata && oauth_metadata[:authorization_endpoint]
      flash[:error] = "Could not determine OAuth endpoints for #{server_name}"
      redirect_to session_path(@session)
      return
    end

    # Check if client_id is available - if DCR failed, we can't proceed
    unless oauth_metadata[:client_id].present?
      flash[:error] = "Dynamic Client Registration failed for #{server_name}. The OAuth provider may be temporarily unavailable. Please try again."
      redirect_to session_path(@session)
      return
    end

    # Delete any existing pending flow for this session/server (user is re-initiating)
    existing_pending = McpOauthPendingFlow.for_session(@session).find_by(server_name: server_name)
    existing_pending&.destroy

    # Create pending flow
    pending_flow = McpOauthPendingFlow.create_for_session!(
      session: @session,
      server_name: server_name,
      server_url: server_url,
      oauth_metadata: oauth_metadata,
      redirect_uri: redirect_uri,
      mcp_server_config: mcp_server_config
    )

    if pending_flow.manual?
      # Out-of-band completion: the user consents in their own browser (which lands on a
      # localhost/oob redirect with nothing listening) and pastes the resulting URL back.
      @pending_flow = pending_flow
      render :manual
    else
      # Redirect to OAuth provider; Zimmer's hosted callback finishes the flow.
      redirect_to pending_flow.authorization_url, allow_other_host: true
    end
  end

  # GET /mcp_oauth/callback
  # Handles OAuth callback from the OAuth provider
  def callback
    state = params[:state]

    unless state.present?
      render_error("Missing state parameter")
      return
    end

    pending_flow = McpOauthPendingFlow.find_by(state: state)

    unless pending_flow
      render_error("OAuth flow not found. It may have expired.")
      return
    end

    if pending_flow.expired?
      pending_flow.destroy
      render_error("OAuth flow has expired. Please try again.")
      return
    end

    # Check for OAuth error
    if params[:error].present?
      Rails.logger.warn "[McpOauthController] OAuth error: #{params[:error]} - #{params[:error_description]}"
      pending_flow.destroy
      render_error("OAuth authorization failed: #{params[:error_description] || params[:error]}")
      return
    end

    unless params[:code].present?
      pending_flow.destroy
      render_error("No authorization code received from OAuth provider.")
      return
    end

    session = pending_flow.session
    credential = store_tokens_and_resume(pending_flow, params[:code])

    unless credential
      pending_flow.destroy
      render_error("Failed to exchange authorization code for tokens. Please try again.")
      return
    end

    flash[:notice] = "Successfully authorized #{credential.server_name}"
    redirect_to session_path(session)
  end

  # POST /mcp_oauth/complete
  # Completes a manual ("paste-back") OAuth flow. The user consented in their own
  # browser, which landed on a localhost/oob redirect with nothing listening; they paste
  # the full redirect URL (or the bare code) here, and we finish the token exchange using
  # the persisted PKCE code_verifier and redirect_uri.
  def complete
    state = params[:state]

    unless state.present?
      render_error("Missing state parameter")
      return
    end

    pending_flow = McpOauthPendingFlow.find_by(state: state)

    unless pending_flow
      render_error("OAuth flow not found. It may have expired.")
      return
    end

    if pending_flow.expired?
      pending_flow.destroy
      render_error("OAuth flow has expired. Please try again.")
      return
    end

    code = pending_flow.authorization_code_from_pasted(params[:redirect_response])

    unless code.present?
      @pending_flow = pending_flow
      @error_message = "Couldn't find an authorization code in what you pasted, or the state didn't match. " \
        "Paste the full URL your browser landed on (it contains ?code=…&state=…), or just the code value."
      render :manual, status: :bad_request
      return
    end

    session = pending_flow.session
    credential = store_tokens_and_resume(pending_flow, code)

    unless credential
      @pending_flow = pending_flow
      @error_message = "Failed to exchange the authorization code for tokens. " \
        "The code may have already been used or expired — re-authorize and paste a fresh URL."
      render :manual, status: :bad_request
      return
    end

    flash[:notice] = "Successfully authorized #{credential.server_name}"
    redirect_to session_path(session)
  end

  private

  # Handles the "Authorize" click for a server Zimmer already holds a valid
  # credential for: re-inject the token into the runtime store, clear the
  # runtime's needs-auth cache so the CLI retries with it, then run the resume
  # service (which clears the OAuth metadata and re-enqueues the original run
  # once every required server is authorized). Best-effort — a failure here must
  # not turn the click into a 500; the flash + redirect still happen.
  #
  # @return [Symbol, nil] the McpOauthResumeService result (:resumed, :partial,
  #   :not_blocked), or nil when re-injection/resume raised.
  def reinject_and_resume(session, server_name)
    working_directory = session.metadata&.dig("working_directory")
    injector = McpOauthCredentialInjector.new(session, working_directory: working_directory)
    injector.inject_credentials!
    injector.clear_runtime_needs_auth_cache([ server_name ])
    McpOauthResumeService.new(session).call
  rescue => e
    Rails.logger.warn(
      "[McpOauthController] reinject_and_resume failed for #{server_name} " \
      "on session #{session.id}: #{e.class}: #{e.message}"
    )
    nil
  end

  # Exchanges the authorization code for tokens, stores the credential, and resumes the
  # session if every blocking OAuth flow is now complete. Shared by the hosted callback
  # and the manual paste-back completion.
  #
  # On success: destroys the pending flow, fires the (idempotent) resume, and returns the
  # stored credential. On failure (no usable token in the response): leaves the pending
  # flow intact and returns nil, so the caller can decide whether to retry or clean up.
  #
  # @param pending_flow [McpOauthPendingFlow]
  # @param code [String] the authorization code
  # @return [McpOauthCredential, nil]
  def store_tokens_and_resume(pending_flow, code)
    oauth_service = McpOauthService.new
    token_data = oauth_service.exchange_code_for_tokens(pending_flow, code)
    tokens = oauth_service.extract_tokens(token_data)

    return nil unless tokens

    credential = McpOauthCredential.find_or_initialize_by(credential_key: pending_flow.credential_key)
    credential.update!(
      server_name: pending_flow.server_name,
      server_url: pending_flow.server_url,
      client_id: pending_flow.client_id,
      client_secret: pending_flow.client_secret,
      access_token: tokens["access_token"],
      refresh_token: tokens["refresh_token"],
      token_endpoint: pending_flow.token_endpoint,
      scopes: tokens["scope"],
      resource: pending_flow.resource,
      expires_at: tokens["expires_in"] ? Time.current + tokens["expires_in"].to_i.seconds : nil
    )

    session = pending_flow.session

    # Clean up pending flow
    pending_flow.destroy

    Rails.logger.info "[McpOauthController] OAuth credentials stored for #{credential.server_name}"

    # Resume the session if every blocking OAuth flow is now complete. The
    # service is idempotent and fires the resume exactly once, replaying the
    # session's original prompt.
    McpOauthResumeService.new(session).call

    credential
  end

  def render_error(message)
    @error_message = message
    render :error, status: :bad_request
  end

  # Computes OAuth status for all MCP servers in a session
  def compute_oauth_status(session)
    mcp_servers = session.all_mcp_servers
    return {} if mcp_servers.blank?

    status = {}
    mcp_servers.each do |server_name|
      server_config = get_mcp_server_config(server_name)
      next unless server_config && server_config[:url]

      credential_key = McpOauthCredential.compute_credential_key(server_name, server_config)
      credential = McpOauthCredential.for_credential_key(credential_key).active.first

      pending_flow = McpOauthPendingFlow.for_session(session).find_by(server_name: server_name)

      status[server_name] = {
        server_url: server_config[:url],
        requires_oauth: nil, # Will be determined by check_oauth_requirement
        has_credentials: credential.present?,
        credential_valid: credential&.active?,
        pending_flow: pending_flow.present?
      }
    end

    status
  end

  # Gets the MCP server config from the catalog
  def get_mcp_server_config(server_name)
    ServersConfig.credential_config(server_name)
  end

  # Computes credential key for a server
  def compute_credential_key(server_name, server_url)
    config = get_mcp_server_config(server_name)
    config ||= { type: "http", url: server_url }
    McpOauthCredential.compute_credential_key(server_name, config)
  end
end
