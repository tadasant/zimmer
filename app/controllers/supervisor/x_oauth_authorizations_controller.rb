# frozen_string_literal: true

module Supervisor
  # Runs the X (Twitter) OAuth consent flow from the panel, so minting or
  # re-minting the XOauthCredential needs a browser rather than a shell on the
  # box (#852).
  #
  #   new      — the form for connecting an account that has no credential yet
  #   create   — starts a flow (XOauthPendingFlow.start!) and sends the operator
  #              to X, or, when X will redirect somewhere Zimmer does not serve,
  #              shows the consent link and a box to paste the redirect URL into
  #   callback — X's redirect, when the redirect URI is Zimmer's own
  #   complete — the pasted redirect URL, otherwise
  #
  # callback and complete finish the same way: the `state` X echoed back claims the
  # pending flow, once (XOauthPendingFlow.claim!), and the code is exchanged with
  # that flow's verifier and redirect URI. A missing, unknown, replayed or expired
  # state stops there, before anything is sent to X.
  #
  # The authorization boundary is Supervisor::ApplicationController's operator
  # realm, on every action including the callback. The callback arrives in the
  # operator's own browser, which already holds the /supervisor credential, and
  # the fleet's sessions do not hold it (CliSpawnEnv clears SUPERVISOR_PASSWORD),
  # so an agent can neither start a flow nor finish one.
  class XOauthAuthorizationsController < Supervisor::ApplicationController
    DEFAULT_ACCESS_TOKEN_ENV_VAR = "X_OAUTH_ACCESS_TOKEN"

    # What a token exchange can raise on the way to X and back. The code is spent
    # by then either way, so each one ends the flow with a message rather than a 500.
    EXCHANGE_ERRORS = [
      XOauthBootstrap::ExchangeError,
      ActiveRecord::RecordInvalid,
      JSON::ParserError,
      Net::OpenTimeout,
      Net::ReadTimeout,
      SocketError,
      SystemCallError,
      IOError,
      OpenSSL::SSL::SSLError
    ].freeze

    # GET /supervisor/x_oauth/authorize
    def new
      @account_key = params[:account_key].to_s
      @access_token_env_var = params[:access_token_env_var].presence || DEFAULT_ACCESS_TOKEN_ENV_VAR
    end

    # POST /supervisor/x_oauth/authorize
    def create
      client_id = XOauthCredential.client_id
      if client_id.blank? || XOauthCredential.client_secret.blank?
        render_error("X_OAUTH_CLIENT_ID and X_OAUTH_CLIENT_SECRET must both be set (in mcp_secrets or the environment) before an X account can be authorized.",
          status: :unprocessable_entity)
        return
      end

      @flow = XOauthPendingFlow.start!(
        account_key: params[:account_key],
        access_token_env_var: params[:access_token_env_var]
      )
      @authorization_url = @flow.authorization_url(client_id: client_id)

      if @flow.manual?
        render :manual
      else
        redirect_to @authorization_url, allow_other_host: true
      end
    rescue ActiveRecord::RecordInvalid => e
      @account_key = params[:account_key].to_s
      @access_token_env_var = params[:access_token_env_var].to_s
      @errors = e.record.errors.full_messages
      render :new, status: :unprocessable_entity
    end

    # GET /supervisor/x_oauth/callback
    def callback
      finish(
        state: params[:state],
        code: params[:code],
        error: params[:error],
        error_description: params[:error_description]
      )
    end

    # POST /supervisor/x_oauth/complete
    def complete
      redirect = XOauthPendingFlow.parse_redirect(params[:redirect_response])

      if redirect.nil?
        # Nothing was claimed, so the flow the form belongs to is still usable:
        # show it again rather than making the operator start over.
        @flow = XOauthPendingFlow.find_by(state: params[:flow_state].to_s)
        if @flow.nil? || @flow.expired?
          render_error("That doesn't look like the URL X redirected to, and the authorization it belonged to is gone. Start again.")
          return
        end

        @authorization_url = @flow.authorization_url(client_id: XOauthCredential.client_id)
        @error_message = "Paste the whole URL your browser landed on after approving on X. It contains ?state=…&code=…"
        render :manual, status: :unprocessable_entity
        return
      end

      finish(**redirect)
    end

    private

    def finish(state:, code:, error:, error_description:)
      flow = XOauthPendingFlow.claim!(state)

      if error.present?
        render_error("X did not authorize the account: #{error_description.presence || error}")
        return
      end

      if code.blank?
        render_error("X redirected back without an authorization code. Start again.")
        return
      end

      credential = XOauthBootstrap.complete!(
        account_key: flow.account_key,
        env_var: flow.access_token_env_var,
        code: code,
        verifier: flow.code_verifier,
        redirect_uri: flow.redirect_uri
      )

      Rails.logger.info "[XOauthAuthorizations] Stored X credential ##{credential.id} (#{credential.account_key}, #{credential.access_token_env_var})"
      # Escaped here because Administrate's flash partial renders the value with
      # html_safe, and account_key is whatever the operator typed.
      flash[:notice] = "Authorized #{ERB::Util.html_escape(credential.account_key)} with X. " \
        "#{credential.access_token_env_var} is vended from this credential."
      redirect_to supervisor_x_oauth_credential_path(credential)
    rescue XOauthPendingFlow::ClaimError => e
      render_error(e.message)
    rescue *EXCHANGE_ERRORS => e
      Rails.logger.warn "[XOauthAuthorizations] Token exchange failed: #{e.class}: #{e.message}"
      render_error("X did not exchange the authorization code for a token (#{e.class}: #{e.message}). The code is single-use, so start again.")
    end

    def render_error(message, status: :bad_request)
      @error_message = message
      render :error, status: status
    end
  end
end
