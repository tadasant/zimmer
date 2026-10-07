# frozen_string_literal: true

module OauthServer
  # The machine-facing endpoints of Zimmer's authorization server: the two
  # well-known metadata documents, registration, token and revocation. A browser
  # never posts a form to them and no cookie authenticates them, so they sit on
  # ActionController::API — outside the web UI's sign-in gate and its CSRF check,
  # the way the REST API does.
  #
  # CORS is open (`*`, no credentials): a browser-based MCP client such as the
  # MCP Inspector calls these from its own origin, and nothing here is
  # authenticated by ambient credentials a cross-origin page could borrow.
  class BaseController < ActionController::API
    include ControllerDatabaseRetry

    before_action :set_cors_headers

    rescue_from OauthServer::Error do |error|
      status = error.code == "invalid_client" ? :unauthorized : :bad_request
      render_oauth_error(error, status: status)
    end

    def preflight
      head :no_content
    end

    private

    def set_cors_headers
      response.set_header("Access-Control-Allow-Origin", "*")
      response.set_header("Access-Control-Allow-Headers", "authorization, content-type, mcp-protocol-version")
      response.set_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
      response.set_header("Access-Control-Max-Age", "600")
    end

    def no_store
      response.set_header("Cache-Control", "no-store")
      response.set_header("Pragma", "no-cache")
    end

    def render_oauth_error(error, status:)
      no_store
      Rails.logger.info("[oauth_server] #{request.request_method} #{request.path} #{status}: #{error.code}: #{error.description}")
      render json: error.to_h, status: status
    end

    def oauth_config
      @oauth_config ||= OauthServer::Config.current(request)
    end
  end
end
