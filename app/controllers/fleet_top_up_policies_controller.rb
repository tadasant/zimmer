# frozen_string_literal: true

# The fleet top-up policy: how few sessions the fleet must be running to count as
# idle enough, how long it must stay there, and how often the
# `no_sessions_in_progress` event may fire at most. FleetIdleMonitor reads all
# three off the settings row on every sweep, so a change here takes effect at the
# next minute without a deploy.
#
# The card lives on /inference for the reason the spot gate card does: the
# population it counts — sessions with a turn in flight — is the one that page already
# reports, and its ceiling is a sibling of the concurrency limit directly above
# it.
#
# Separate from SpotPoliciesController so each form writes only its own fields: a
# PATCH that saved both would let a validation failure on one card reject a change
# made on the other.
class FleetTopUpPoliciesController < ApplicationController
  def update
    setting = AppSetting.editable
    top_up_params = params[:app_setting]
    top_up_params = ActionController::Parameters.new unless top_up_params.is_a?(ActionController::Parameters)

    # Only the keys the request actually carries, matching SpotPoliciesController:
    # a hand-built PATCH that omits one would otherwise assign nil to a NOT NULL
    # column and 500 instead of leaving that number as it was.
    %i[fleet_idle_max_sessions fleet_idle_threshold_minutes fleet_idle_min_fire_interval_minutes].each do |field|
      setting.public_send("#{field}=", top_up_params[field]) if top_up_params.key?(field)
    end

    if setting.save
      redirect_to inference_path(anchor: "fleet-top-up"), notice: "Fleet top-up policy updated."
    else
      redirect_to inference_path(anchor: "fleet-top-up"),
        alert: "Fleet top-up policy not saved: #{setting.errors.full_messages.join(', ')}"
    end
  end
end
