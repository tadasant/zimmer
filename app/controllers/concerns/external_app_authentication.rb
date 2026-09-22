# frozen_string_literal: true

# What turns an Api::BaseController into a Zimmer plugin's surface, and nothing
# more: it accepts ApiKey's `external_app` grant — and, because the grant match is
# exact, only that grant — then refuses a plugin that has been disabled. See
# ExternalApp for the model and why it is enforced here rather than by URL.
#
# Included by ExternalAppMcpController and Api::V1::ExternalAppTriggersController.
# Nothing else should include it: every other controller asks for the `api` grant
# by default, which is what refuses a plugin key everywhere else.
module ExternalAppAuthentication
  extend ActiveSupport::Concern

  included do
    # Appended after Api::BaseController's authenticate_api_key, so it only runs
    # once a key has authenticated.
    before_action :require_enabled_external_app
  end

  private

  attr_reader :current_external_app

  def api_key_grant
    ApiKey::EXTERNAL_APP_GRANT
  end

  # 403 rather than 401 for a disabled plugin: the key is fine, and saying so
  # tells whoever holds it to look at the plugin rather than rotate the key.
  def require_enabled_external_app
    external_app = @authenticated_api_key&.external_app

    if external_app.nil?
      render_api_error("Unauthorized", "Invalid or missing API key", status: :unauthorized)
    elsif !external_app.enabled?
      Rails.logger.warn("[external_app] #{request.request_method} #{request.path} refused: #{external_app.name.inspect} (external_app_id=#{external_app.id}) is disabled")
      render_api_error("Forbidden", "This Zimmer plugin is disabled", status: :forbidden)
    else
      @current_external_app = external_app
    end
  end
end
