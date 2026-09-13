# All Administrate controllers inherit from this
# `Administrate::ApplicationController`, making it the ideal place to put
# authentication logic or other before_actions.
#
# If you want to add pagination or other controller-level concerns,
# you're free to overwrite the RESTful controller actions.
#
# There is no authentication here, the same as the rest of the web UI: Zimmer is a
# single circle of trust and the network perimeter is the authentication boundary
# (docs/src/content/docs/auth/overview.md). That includes this panel, even though it
# renders `mcp_oauth_credentials`, `mcp_oauth_pending_flows` and `x_oauth_credentials`
# as *editable* resources whose edit forms hold plaintext tokens, client secrets and
# PKCE verifiers. Anything that can reach the host can read them, agent sessions
# included. A dashboard that holds a column back lists it in its DELIBERATELY_OMITTED.
module Supervisor
  class ApplicationController < Administrate::ApplicationController
    # Override this value to specify the number of elements to display at a time
    # on index pages. Defaults to 20.
    # def records_per_page
    #   params[:per_page] || 20
    # end
  end
end
