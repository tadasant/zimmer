# frozen_string_literal: true

# Models added to a runtime's catalog without a deploy (#85). The REST half of
# Settings → Models and of the `manage_models` MCP tool; all three write through
# ModelCatalogEntry.add.
#
# Only added models are here. The whole catalog, built-in models included, is
# `runtime_models` in GET /api/v1/configs, where each model carries `source`.
#
# All endpoints require API key authentication via X-API-Key header.
class Api::V1::ModelCatalogEntriesController < Api::BaseController
  # GET /api/v1/model_catalog_entries
  def index
    render json: { model_catalog_entries: ModelCatalogEntry.ordered.map { |entry| entry_json(entry) } }
  end

  # POST /api/v1/model_catalog_entries
  #
  # Request body:
  #   - runtime: a runtime key from GET /api/v1/configs (required)
  #   - model_id: the id exactly as the CLI takes it (required)
  #   - label: what pickers show (optional; defaults to model_id)
  #   - requires_oauth: the model only runs with an interactive login (optional)
  #   - allow_unlisted: add it even though the installed CLI's model list does
  #     not name it (optional). Without it such an id is refused with 422 and
  #     `error: "Model not listed by CLI"`, carrying the CLI's note.
  #
  # The response carries the CLI check stored on the row: `cli_listed` (true,
  # false, or null when the runtime has no list to check), `cli_version` and
  # `cli_note`.
  def create
    entry = ModelCatalogEntry.add(
      runtime: params[:runtime],
      model_id: params[:model_id],
      label: params[:label],
      requires_oauth: params[:requires_oauth],
      allow_unlisted: params[:allow_unlisted],
      added_via: "api"
    )

    if entry.persisted?
      render json: { model_catalog_entry: entry_json(entry) }, status: :created
    else
      error = entry.errors.of_kind?(:model_id, :unlisted) ? "Model not listed by CLI" : "Validation failed"
      render_api_error(error, entry.errors.full_messages, status: :unprocessable_entity,
        cli_listed: entry.cli_listed, cli_version: entry.cli_version, cli_note: entry.cli_note)
    end
  end

  # DELETE /api/v1/model_catalog_entries/:id
  #
  # Refused with 422 while the Settings page's session default or the
  # categorization model names it. Sessions already on the model keep it.
  def destroy
    entry = ModelCatalogEntry.find(params[:id])

    if entry.destroy
      head :no_content
    else
      render_api_error("Model in use", entry.destroy_refusal, status: :unprocessable_entity)
    end
  end

  private

  def entry_json(entry)
    {
      id: entry.id,
      runtime: entry.runtime,
      model_id: entry.model_id,
      label: entry.display_label,
      requires_oauth: entry.requires_oauth,
      cli_listed: entry.cli_listed,
      cli_version: entry.cli_version,
      cli_note: entry.cli_note,
      shadowed_by_built_in: entry.shadowed_by_built_in?,
      added_via: entry.added_via,
      created_at: entry.created_at.iso8601
    }
  end
end
