# frozen_string_literal: true

# The spot gate policy: whether the gate holds spot sessions at all, how much of
# each window is reserved for priority sessions, and the ceiling on how many
# sessions run at once. The card lives on /quotas because the windows it reads
# are the ones that page reports.
#
# The reserve is typed as a PERCENTAGE and read back as DOLLARS. A percentage is
# what a human can reason about setting; the money is derived by
# QuotaCapacityModel from the calibrated capacity of the window, and is what the
# gate actually decides on.
#
# Separate from AppSettingsController, which persists the settings page's own
# forms, so each page's forms write only their own fields.
class SpotPoliciesController < ApplicationController
  def update
    setting = AppSetting.editable
    spot_params = params[:app_setting]
    spot_params = ActionController::Parameters.new unless spot_params.is_a?(ActionController::Parameters)

    # Only the keys the request actually carries. The card's form posts all three
    # together (the toggle behind a hidden `0`), so this costs the form nothing —
    # but a hand-built PATCH that omits the toggle would otherwise assign nil to a
    # NOT NULL column and 500 instead of leaving the gate as it was.
    if spot_params.key?(:spot_gating_enabled)
      setting.spot_gating_enabled = ActiveModel::Type::Boolean.new.cast(spot_params[:spot_gating_enabled])
    end
    if spot_params.key?(:spot_reserve_five_hour_pct)
      setting.spot_reserve_five_hour_pct = spot_params[:spot_reserve_five_hour_pct]
    end
    if spot_params.key?(:spot_reserve_weekly_pct)
      setting.spot_reserve_weekly_pct = spot_params[:spot_reserve_weekly_pct]
    end
    if spot_params.key?(:spot_max_concurrent_sessions)
      setting.spot_max_concurrent_sessions = spot_params[:spot_max_concurrent_sessions]
    end

    if setting.save
      redirect_to quotas_path(anchor: "spot-gate"), notice: "Spot policy updated."
    else
      redirect_to quotas_path(anchor: "spot-gate"),
        alert: "Spot policy not saved: #{setting.errors.full_messages.join(', ')}"
    end
  end
end
