# frozen_string_literal: true

module Supervisor
  class ModelCatalogEntriesController < Supervisor::ApplicationController
    # The model_catalog_entries table as rows. Models are added and removed on
    # /settings/models; this is the generic read-only view every table gets.
    private

    def default_sorting_attribute = :created_at

    def default_sorting_direction = :desc
  end
end
