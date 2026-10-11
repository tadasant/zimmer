# frozen_string_literal: true

# API controller for listing the hooks in the catalog, read-only — the list a
# session's hooks are chosen from, as GET /api/v1/skills is for skills.
#
# All endpoints require API key authentication via X-API-Key header.
class Api::V1::HooksController < Api::BaseController
  # Zimmer's iOS app: read-only: the catalog for the new-session form.
  accepts_native_app_tokens only: %i[index]

  # GET /api/v1/hooks
  # The catalog's hooks, as HooksConfig describes them.
  def index
    render json: { hooks: HooksConfig.all.map(&:to_h) }
  end
end
