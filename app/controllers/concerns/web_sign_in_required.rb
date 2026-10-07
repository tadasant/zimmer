# frozen_string_literal: true

# The web UI's login wall. Included by ApplicationController, the /supervisor
# panel's base controller, and GoodJob's dashboard (config/initializers/web_auth.rb),
# which together are every browser surface Zimmer serves.
#
# What it does NOT cover, on purpose, because none of them inherits from those
# controllers: the REST API and `/mcp` (Api::BaseController, an API key), the
# inbound webhooks (Webhooks::BaseController, a signature), the OAuth machine
# endpoints for `/mcp` (OauthServer::BaseController, PKCE or a token), and `/up`
# (Rails::HealthController). `/oauth/authorize` IS covered: it is a browser page.
# test/integration/web_sign_in_route_audit_test.rb walks every route and fails if
# one lands somewhere this list does not explain.
#
# With the gate off (no ZIMMER_WEB_AUTH_GOOGLE_CLIENT_ID) every check here is a
# no-op and nobody is asked to sign in.
module WebSignInRequired
  extend ActiveSupport::Concern

  LOGIN_PATH = "/login"

  # Paths the wall never answers, whatever controller ends up serving them.
  # Every one of these is a machine endpoint with its own credential (an API
  # key, a provider signature, an OAuth client) or none at all (health checks,
  # OAuth discovery), and a 302 to /login would break its client. None of
  # them is served by a controller that includes this concern; the list is the
  # second line of defence if one ever is. `/oauth/authorize` is deliberately
  # absent: it is a browser page and belongs behind the wall. A format suffix
  # (`/mcp.json`) is covered, because the routes accept one.
  MACHINE_PATHS = %r{
    \A(?:
      /mcp(?:/external_app)?(?:\.\w+)?/?\z
      | /api(?:/|\z)
      | /webhooks(?:/|\z)
      | /up(?:/deep)?(?:\.\w+)?/?\z
      | /\.well-known/oauth-
      | /oauth/(?:register|token|revoke)(?:\.\w+)?/?\z
    )
  }x

  # The longest return path kept, measured as the session cookie stores it.
  # The cookie store serializes JSON, which writes `&` `<` `>` as six-byte
  # escapes, and the encrypted cookie must stay under 4 KB with the CSRF token
  # and the OAuth state beside it. A longer path is not kept, and the browser
  # lands on / after sign-in instead of a 500 for an overflowing cookie.
  RETURN_TO_MAX_BYTES = 1500
  RETURN_TO_KEY = :web_auth_return_to

  included do
    before_action :require_web_sign_in
    rescue_from WebAuth::Configuration::Unavailable, with: :web_auth_unavailable
    helper_method :current_web_identity, :web_auth_configuration if respond_to?(:helper_method)
  end

  class_methods do
    # For the few actions a signed-out browser must reach: the login flow itself,
    # the 404 page, and /up/deep.
    def allow_signed_out_access(**options)
      skip_before_action :require_web_sign_in, **options
    end
  end

  private

  def require_web_sign_in
    return if request.path.match?(MACHINE_PATHS)

    configuration = web_auth_configuration
    return unless configuration.enabled?

    if (identity = WebAuth::Cookies.signed_in_identity(cookies, configuration))
      @current_web_identity = identity
      WebAuth::Cookies.refresh_if_due(cookies, configuration)
      return
    end

    deny_signed_out_request
  end

  # The process has never been able to read its sign-in configuration, so it
  # cannot tell whether the wall should be up. It answers 503 rather than guess.
  def web_auth_unavailable(exception)
    render plain: "Sign-in is unavailable: #{exception.message}. Try again in a minute.", status: :service_unavailable
  end

  # A page load goes to the login page and comes back afterwards. Anything else
  # (a form post, a Turbo frame or stream fetch, a JSON poll) gets a bare 401: a
  # redirect there would land login HTML inside a fragment, or replay a write.
  def deny_signed_out_request
    if request.get? && page_load? && !request.xhr? && request.headers["Turbo-Frame"].blank?
      session[RETURN_TO_KEY] = request.fullpath if ActiveSupport::JSON.encode(request.fullpath).bytesize <= RETURN_TO_MAX_BYTES
      redirect_to LOGIN_PATH
    else
      head :unauthorized
    end
  end

  # A browser asks for HTML; curl and most other clients ask for */*. Both are a
  # page load. A Turbo Stream or JSON request is not.
  def page_load?
    request.format.html? || request.format == Mime::ALL
  end

  def current_web_identity = @current_web_identity

  def web_auth_configuration
    @web_auth_configuration ||= WebAuth::Configuration.current
  end
end
