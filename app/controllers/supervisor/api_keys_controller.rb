# frozen_string_literal: true

module Supervisor
  class ApiKeysController < Supervisor::ApplicationController
    # The api_keys table as rows. Managing keys happens on /settings/api_keys;
    # this is the generic read-only view every table gets.
    private

    def default_sorting_attribute = :created_at

    def default_sorting_direction = :desc
  end
end
