# frozen_string_literal: true

module Supervisor
  class WebIdentitiesController < Supervisor::ApplicationController
    private

    def default_sorting_attribute = :last_signed_in_at

    def default_sorting_direction = :desc
  end
end
