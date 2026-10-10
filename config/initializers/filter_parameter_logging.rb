# Be sure to restart your server when you modify this file.

# Configure parameters to be partially matched (e.g. passw matches password) and filtered from the log file.
# Use this to limit dissemination of sensitive information.
# See the ActiveSupport::ParameterFilter documentation for supported notations and behaviors.
Rails.application.config.filter_parameters += [
  :passw, :email, :secret, :token, :_key, :crypt, :salt, :certificate, :otp, :ssn, :cvv, :cvc,
  # An OAuth authorization code, on the X and MCP callbacks, and the redirect URL
  # carrying one that an operator pastes back. Matched exactly: a bare :code would
  # also hide status_code, error_code and the like.
  /\Acode\z/, /\Acode_verifier\z/, :redirect_response,
  # The Cloudflare Access JWT the iOS app's edge handoff returns (already caught
  # by :token; named so a change to that rule cannot expose it).
  :cf_access_token
]

# The handoff's redirect carries the same JWT in its fragment, and Rails logs
# every redirect's full location, fragment included.
Rails.application.config.filter_redirect += [ %r{/access/callback} ]
