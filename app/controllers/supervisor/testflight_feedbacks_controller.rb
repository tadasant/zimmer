# frozen_string_literal: true

module Supervisor
  class TestflightFeedbacksController < Supervisor::ApplicationController
    # TestFlight crash and screenshot feedback pulled from App Store Connect by
    # TestflightFeedbackPollJob — the human view of what `get_testflight_crashes`
    # serves agents.
    private

    def default_sorting_attribute = :submitted_at

    def default_sorting_direction = :desc
  end
end
