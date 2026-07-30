# frozen_string_literal: true

module SecretProviders
  # `mcp_secrets` in Zimmer's Rails encrypted credentials — the mechanism every
  # Zimmer MCP secret used before the Parameter Store link existed, and still the
  # home of every secret that has not migrated.
  #
  # SecretsLoader deliberately does not memoize, so a credentials file replaced
  # under a running process is picked up without a restart. This provider stays
  # cacheless for the same reason.
  class RailsCredentials
    LABEL = "Zimmer's Rails encrypted credentials"

  # Fixed badge string — see SecretProviders::Env::BADGE.
  BADGE = "Rails Credentials"

    def name = "rails_credentials"
    def label = LABEL
    def badge = BADGE

    def badge_title
      "Resolved from mcp_secrets in #{SecretsLocation.credentials_path}"
    end

    def get(variable)
      SecretsLoader.get(variable).presence
    end

    def has?(variable) = SecretsLoader.exists?(variable)

    def invalidate(_variable = nil) = nil
  end
end
