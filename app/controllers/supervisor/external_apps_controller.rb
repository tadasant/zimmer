# frozen_string_literal: true

module Supervisor
  class ExternalAppsController < Supervisor::ApplicationController
    # The external_apps table as rows. Zimmer plugins are managed on
    # /settings/plugins (ExternalAppsController) and `action_external_app`;
    # this is the generic read-only view every table gets.
    private

    def default_sorting_attribute = :created_at

    def default_sorting_direction = :desc
  end
end
