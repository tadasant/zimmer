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
  layout "application_shell"

  # POST/GET callback may not have CSRF token from OAuth provider
  # Initiate action may also have stale CSRF tokens after deploys, so we skip it there too
  # Security is maintained via: valid session_id required, OAuth state parameter protection
  skip_forgery_protection only: [ :callback, :initiate ]

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
      flash[:notice] = "OAuth credentials already exist for #{server_name}"
      redirect_to session_path(@session)
      return
    end

    # Get the MCP server config for credential key computation
    mcp_server_config = get_mcp_server_config(server_name)

    # Check for pre-registered OAuth config first (takes precedence over server probing)
    # Some servers like BigQuery don't require auth for initialization but do for tool calls
    preregistered_oauth = PreregisteredOauthConfig.find_for_server(server_name)

    if preregistered_oauth
      oauth_metadata = {
        authorization_endpoint: preregistered_oauth.authorization_endpoint,
        token_endpoint: preregistered_oauth.token_endpoint,
        client_id: preregistered_oauth.client_id,
        client_secret: preregistered_oauth.client_secret,
        scopes: preregistered_oauth.scopes
      }
      Rails.logger.info "[McpOauthController] Using pre-registered OAuth for #{server_name}"
    else
      # Fall back to probing the server to discover OAuth metadata via RFC 8414/9728.
      # Pass through any statically-configured client id from the catalog `oauth`
      # block so servers that require a pre-registered client (e.g. Slack) use it
      # instead of the `agent-orchestrator` placeholder.
      catalog_server = ServersConfig.find(server_name)
      oauth_service = McpOauthService.new
      requirement = oauth_service.check_oauth_requirement(
        server_url,
        configured_client_id: catalog_server&.oauth_client_id,
        configured_client_secret: catalog_server&.oauth_client_secret
      )

      unless requirement.required && requirement.metadata
        flash[:error] = "Could not determine OAuth requirements for #{server_name}"
        redirect_to session_path(@session)
        return
      end

      oauth_metadata = {
        authorization_endpoint: requirement.metadata.authorization_endpoint,
        token_endpoint: requirement.metadata.token_endpoint,
        registration_endpoint: requirement.metadata.registration_endpoint,
        client_id: requirement.metadata.client_id,
        client_secret: requirement.metadata.client_secret,
        scopes: requirement.metadata.scopes_supported&.join(" "),
        resource: requirement.metadata.resource
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
    oauth_service ||= McpOauthService.new
    redirect_uri = oauth_service.build_redirect_uri
    pending_flow = McpOauthPendingFlow.create_for_session!(
      session: @session,
      server_name: server_name,
      server_url: server_url,
      oauth_metadata: oauth_metadata,
      redirect_uri: redirect_uri,
      mcp_server_config: mcp_server_config
    )

    # Redirect to OAuth provider
    redirect_to pending_flow.authorization_url, allow_other_host: true
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

    # Exchange code for tokens
    oauth_service = McpOauthService.new
    token_data = oauth_service.exchange_code_for_tokens(pending_flow, params[:code])

    unless token_data && token_data["access_token"]
      pending_flow.destroy
      render_error("Failed to exchange authorization code for tokens. Please try again.")
      return
    end

    # Store the credentials
    credential = McpOauthCredential.find_or_initialize_by(credential_key: pending_flow.credential_key)
    credential.update!(
      server_name: pending_flow.server_name,
      server_url: pending_flow.server_url,
      client_id: pending_flow.client_id,
      client_secret: pending_flow.client_secret,
      access_token: token_data["access_token"],
      refresh_token: token_data["refresh_token"],
      token_endpoint: pending_flow.token_endpoint,
      scopes: token_data["scope"],
      resource: pending_flow.resource,
      expires_at: token_data["expires_in"] ? Time.current + token_data["expires_in"].to_i.seconds : nil
    )

    session = pending_flow.session

    # Clean up pending flow
    pending_flow.destroy

    Rails.logger.info "[McpOauthController] OAuth credentials stored for #{credential.server_name}"

    # Resume the session if every blocking OAuth flow is now complete. The
    # service is idempotent and fires the resume exactly once, replaying the
    # session's original prompt.
    McpOauthResumeService.new(session).call

    flash[:notice] = "Successfully authorized #{credential.server_name}"
    redirect_to session_path(session)
  end

  private

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
