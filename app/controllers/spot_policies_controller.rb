# frozen_string_literal: true

# The spot gate policy: whether the gate holds spot sessions at all, and the two
# forecast ceilings it holds them against. The card lives on /quotas because the
# windows it forecasts are the ones that page reports.
#
# Kept out of AppSettingsController — which persists the settings page's own
# forms — so the policy travels with the page that renders it and a submit from
# either page can never reach into the other's fields.
class SpotPoliciesController < ApplicationController
  def update
    setting = AppSetting.editable
    spot_params = params[:app_setting] || {}

    setting.spot_gating_enabled = ActiveModel::Type::Boolean.new.cast(spot_params[:spot_gating_enabled])
    setting.spot_gate_five_hour_threshold_pct = spot_params[:spot_gate_five_hour_threshold_pct]
    setting.spot_gate_weekly_threshold_pct = spot_params[:spot_gate_weekly_threshold_pct]

    if setting.save
      redirect_to quotas_path(anchor: "spot-gate"), notice: "Spot policy updated."
    else
      redirect_to quotas_path(anchor: "spot-gate"),
        alert: "Spot policy not saved: #{setting.errors.full_messages.join(', ')}"
    end
  end
end
