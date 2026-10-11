# frozen_string_literal: true

module Supervisor
  class ApnsDevicesController < Supervisor::ApplicationController
    # The phones registered for iOS push. Registration happens from the app; this
    # is the read-only view of which phones would get a push, and why one that
    # stopped did (`disabled_reason`).
    private

    def default_sorting_attribute = :last_registered_at

    def default_sorting_direction = :desc
  end
end
