# frozen_string_literal: true

# Serves the "live updates paused" banner fragment.
#
# The broadcast circuit breaker being open is the one condition Zimmer cannot
# announce over Turbo Streams, because broadcasting is exactly what is broken
# while it holds. So the banner is polled over plain HTTP instead
# (live_updates_status_controller.js) and this action renders the current state.
class LiveUpdatesController < ApplicationController
  def status
    render partial: "shared/live_updates_paused_banner"
  end
end
