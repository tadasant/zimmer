# All Administrate controllers inherit from this
# `Administrate::ApplicationController`, making it the ideal place to put
# authentication logic or other before_actions.
#
# If you want to add pagination or other controller-level concerns,
# you're free to overwrite the RESTful controller actions.
module Supervisor
  class ApplicationController < Administrate::ApplicationController
    # One shared HTTP Basic credential gates the whole Administrate surface. There
    # is no user model behind it — Zimmer is a single circle of trust, so this is
    # not "who are you" but "are you inside the perimeter at all". The panel
    # renders `claude_accounts`, `mcp_oauth_credentials`, and `x_oauth_credentials`
    # as *editable* resources, and those hold plaintext OAuth access and refresh
    # tokens, so it is the one surface that gets a second wall behind the tailnet.
    #
    # The realm fails closed: with SUPERVISOR_PASSWORD unset, every request is
    # rejected. An unconfigured deployment gets no admin panel, not an anonymous
    # one — the opposite of the stub this replaced.
    USERNAME_ENV = "SUPERVISOR_USERNAME"
    PASSWORD_ENV = "SUPERVISOR_PASSWORD"
    DEFAULT_USERNAME = "supervisor"
    REALM = "Zimmer supervisor"

    before_action :authenticate_supervisor

    private

    def authenticate_supervisor
      expected_password = ENV[PASSWORD_ENV].to_s
      return request_http_basic_authentication(REALM) if expected_password.empty?

      expected_username = ENV[USERNAME_ENV].presence || DEFAULT_USERNAME

      authenticate_or_request_with_http_basic(REALM) do |username, password|
        # `&`, not `&&`: compare both halves every time, so a wrong username costs
        # the same as a wrong password and neither leaks which one was wrong.
        secure_compare(username, expected_username) & secure_compare(password, expected_password)
      end
    end

    # Constant-time comparison, mirroring Api::BaseController#authenticate_api_key.
    # `secure_compare` (as opposed to `fixed_length_secure_compare`) digests both
    # sides first, so it tolerates unequal lengths without leaking them.
    def secure_compare(given, expected)
      ActiveSupport::SecurityUtils.secure_compare(given.to_s, expected.to_s)
    end

    # Override this value to specify the number of elements to display at a time
    # on index pages. Defaults to 20.
    # def records_per_page
    #   params[:per_page] || 20
    # end
  end
end
