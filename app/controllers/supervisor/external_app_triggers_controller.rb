# frozen_string_literal: true

module Supervisor
  class ExternalAppTriggersController < Supervisor::ApplicationController
    # Zimmer plugins' trigger allowlists as rows. Edited on /settings/plugins and
    # with `action_external_app`; read-only here.
    private

    def default_sorting_attribute = :created_at

    def default_sorting_direction = :desc
  end
end
