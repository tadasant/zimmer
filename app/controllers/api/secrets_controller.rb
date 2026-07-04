class Api::SecretsController < ApplicationController
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
