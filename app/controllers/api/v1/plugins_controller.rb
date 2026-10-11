# frozen_string_literal: true

# API controller for listing the plugins in the catalog, read-only — the list a
# session's plugins are chosen from, as GET /api/v1/skills is for skills.
#
# All endpoints require API key authentication via X-API-Key header.
class Api::V1::PluginsController < Api::BaseController
  # Zimmer's iOS app: read-only: the catalog for the new-session form.
  accepts_native_app_tokens only: %i[index]

  # GET /api/v1/plugins
  # The catalog's plugins, as PluginsConfig describes them.
  def index
    render json: { plugins: PluginsConfig.all.map(&:to_h) }
  end
end
