# frozen_string_literal: true

# Settings → Models: every runtime's model catalog, and the form that adds a
# model to one without a deploy (#85).
#
# A thin caller of ModelCatalogEntry.add, the write path this page shares with
# Api::V1::ModelCatalogEntriesController and the `manage_models` MCP tool. The
# built-in models are listed read-only beside the added ones, because changing
# those is still a deploy.
class ModelCatalogEntriesController < ApplicationController
  def index
    @entry = ModelCatalogEntry.new(runtime: RuntimeRegistry::DEFAULT_RUNTIME)
    load_page
  end

  def create
    submitted = params.fetch(:model_catalog_entry, {})
    submitted = {} unless submitted.is_a?(ActionController::Parameters)

    @entry = ModelCatalogEntry.add(
      runtime: submitted[:runtime],
      model_id: submitted[:model_id],
      label: submitted[:label],
      requires_oauth: submitted[:requires_oauth],
      allow_unlisted: submitted[:allow_unlisted],
      added_via: "web_ui"
    )

    if @entry.persisted?
      redirect_to model_catalog_entries_path,
        notice: "Added #{@entry.model_id} to #{RuntimeRegistry.label_for(@entry.runtime)}. #{@entry.cli_note}"
    else
      load_page
      render :index, status: :unprocessable_entity
    end
  end

  def destroy
    entry = ModelCatalogEntry.find(params[:id])

    if entry.destroy
      redirect_to model_catalog_entries_path,
        notice: "Removed #{entry.model_id} from #{RuntimeRegistry.label_for(entry.runtime)}."
    else
      redirect_to model_catalog_entries_path, alert: entry.destroy_refusal
    end
  end

  private

  def load_page
    @runtimes = ModelCatalog.runtimes
    @models_by_runtime = @runtimes.index_with { |runtime| ModelCatalog.models_for(runtime) }
    @defaults_by_runtime = @runtimes.index_with { |runtime| ModelCatalog.default_for(runtime) }
    @entries_by_key = ModelCatalogEntry.all.index_by { |entry| [ entry.runtime, entry.model_id ] }
    @shadowed_entries = ModelCatalogEntry.ordered.select(&:shadowed_by_built_in?)
  end
end
