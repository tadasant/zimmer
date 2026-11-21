module Supervisor
  class McpOauthCredentialsController < Supervisor::ApplicationController
    # The secret fields are masked (MaskedSecretField): the edit form never shows
    # the stored value, so a blank one means "keep what is stored", not "erase it".
    MASKED_ATTRIBUTES = %w[access_token refresh_token client_secret].freeze

    private

    def resource_params
      super.tap do |permitted|
        MASKED_ATTRIBUTES.each { |name| permitted.delete(name) if permitted[name].blank? }
      end
    end
  end
end
