# Be sure to restart your server when you modify this file.

# Configure parameters to be partially matched (e.g. passw matches password) and filtered from the log file.
# Use this to limit dissemination of sensitive information.
# See the ActiveSupport::ParameterFilter documentation for supported notations and behaviors.
Rails.application.config.filter_parameters += [
  :passw, :email, :secret, :token, :_key, :crypt, :salt, :certificate, :otp, :ssn, :cvv, :cvc,
  # An OAuth authorization code, on the X and MCP callbacks, and the redirect URL
  # carrying one that an operator pastes back. Matched exactly: a bare :code would
  # also hide status_code, error_code and the like.
  /\Acode\z/, :redirect_response
]
