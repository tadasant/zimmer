# Secret-name autocomplete for the API surface.
#
# Inherits Api::BaseController so it sits behind the same X-API-Key gate as every
# other API endpoint. It returns secret *names and descriptions* — never values —
# but the name list is still a map of what this Zimmer holds, so it is not public.
class Api::SecretsController < Api::BaseController
  # GET /api/secrets/keys
  # Returns list of available secrets with metadata for autocomplete
  def keys
    secrets = SecretsLoader.all_with_metadata.map do |secret|
      {
        name: secret.name,
        description: secret.description
      }
    end
    render json: { secrets: secrets }
  end
end
