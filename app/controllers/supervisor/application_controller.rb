# All Administrate controllers inherit from this
# `Administrate::ApplicationController`, making it the ideal place to put
# authentication logic or other before_actions.
#
# If you want to add pagination or other controller-level concerns,
# you're free to overwrite the RESTful controller actions.
module Supervisor
  class ApplicationController < Administrate::ApplicationController
    include SpeculativeRequest
    include OperatorHttpBasicAuth

    # One shared HTTP Basic credential gates the whole Administrate surface. The realm
    # itself — the variables, the constant-time comparison, and the fail-closed posture
    # when SUPERVISOR_PASSWORD is unset — lives in OperatorHttpBasicAuth, which the
    # mutating /health actions share (#312, #371). What is specific to this surface is
    # *why* it gets a second wall: the panel renders `claude_accounts`,
    # `mcp_oauth_credentials`, and `x_oauth_credentials` as *editable* resources, and
    # those hold plaintext OAuth access and refresh tokens.
    #
    # Kept as constants on this class because tests and docs name them here.
    USERNAME_ENV = OperatorHttpBasicAuth::USERNAME_ENV
    PASSWORD_ENV = OperatorHttpBasicAuth::PASSWORD_ENV
    DEFAULT_USERNAME = OperatorHttpBasicAuth::DEFAULT_USERNAME
    REALM = OperatorHttpBasicAuth::REALM

    before_action :authenticate_operator

    private

    # The concern's default refusal always challenges. This surface must not, for one
    # case, and separating refusing from challenging is the whole point of the override.
    #
    # The 401 is the gate saying no. The `WWW-Authenticate: Basic` header on it is
    # a separate instruction — "ask the human for a credential" — and the browser
    # obeys it for any same-origin `fetch` that carries credentials, not just for
    # a navigation the human started (WHATWG Fetch, HTTP-network-or-cache fetch,
    # step 4xx). Turbo Drive prefetches same-origin links on hover, so the cursor
    # drifting over the dashboard's "Supervisor" button was enough to open the
    # browser's native sign-in dialog on top of a page nobody was leaving. It
    # looked random because it tracked the mouse, not any click.
    #
    # So a speculative request gets the refusal without the challenge. That
    # weakens nothing: the request is still rejected, it was still going to
    # render nothing, and every real navigation still gets the challenge and
    # still logs in. It only stops the browser recruiting the human into a
    # request they never made.
    def refuse_operator(realm_configured: true)
      return request_http_basic_authentication(REALM) unless prefetch_request?

      # Turbo hands a prefetched response to a subsequent click on the same link,
      # so this body is what a link that forgot `data-turbo-prefetch="false"`
      # would render. Give it somewhere to go rather than a blank page — and,
      # when the realm is unconfigured, say so instead of sending an operator to
      # a prompt no credential can satisfy.
      render "supervisor/shared/prefetch_unauthorized",
        layout: false,
        status: :unauthorized,
        locals: { realm_configured: realm_configured }
    end

    # Override this value to specify the number of elements to display at a time
    # on index pages. Defaults to 20.
    # def records_per_page
    #   params[:per_page] || 20
    # end
  end
end
