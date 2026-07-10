# frozen_string_literal: true

# Vends a fresh X (Twitter) OAuth access token for ${VAR} interpolation at
# session-prep.
#
# SecretsInterpolator#get_env_value consults this vendor BEFORE the static
# credentials store so that a `${X_OAUTH_ACCESS_TOKEN}` reference in a catalog
# server's env resolves to the freshest access token minted by the durable
# refresher (XOauthCredential), rather than a stale git-committed value.
#
# The interpolator resolves every ${VAR} in every selected server's env, so this
# must be cheap for the common (non-X) case: the ENV_VAR_PREFIX guard short-
# circuits without a DB hit unless the variable is an X access-token var.
class XOauthTokenVendor
  # Only variables whose name begins with this prefix are backed by the X token
  # store. Covers the default X_OAUTH_ACCESS_TOKEN plus any future per-account
  # variants (e.g. X_OAUTH_ACCESS_TOKEN_JULIE).
  ENV_VAR_PREFIX = "X_OAUTH_ACCESS_TOKEN"

  # Resolve an env var name to a fresh X access token, or nil if this vendor does
  # not own the variable (or has no credential / token for it).
  #
  # @param var_name [String]
  # @return [String, nil]
  def self.resolve(var_name)
    return nil unless var_name.is_a?(String) && var_name.start_with?(ENV_VAR_PREFIX)

    credential = XOauthCredential.find_by(access_token_env_var: var_name)
    return nil if credential.nil?

    credential.current_access_token
  rescue => e
    # Never let token vending break session-prep for unrelated servers. A nil
    # return lets the interpolator fall through to credentials/ENV (and raise a
    # clear MissingVariableError if the var is genuinely required and unset).
    Rails.logger.error "[XOauthTokenVendor] Failed to vend #{var_name}: #{e.class}: #{e.message}"
    nil
  end
end
