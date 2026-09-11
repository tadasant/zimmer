# frozen_string_literal: true

# The spot gate policy: whether the gate holds spot sessions at all, how much of
# each window is reserved for priority sessions, and the ceiling on how many
# sessions run at once. The card lives on /inference because the windows it reads
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
  # The fields this card writes, and how each one is cast. One list, so the
  # audit-coverage test can check that every knob reachable from this form is one
  # AppSetting records a change to — a new field added here and forgotten there
  # would be a setting that moves with nothing saying so.
  BOOLEAN_FIELDS = %i[spot_gating_enabled spot_preemption_enabled].freeze
  INTEGER_FIELDS = %i[
    spot_reserve_five_hour_pct
    spot_reserve_weekly_pct
    spot_max_concurrent_sessions
    spot_starvation_age_ceiling_hours
  ].freeze
  FIELDS = (BOOLEAN_FIELDS + INTEGER_FIELDS).freeze

  # Named on the audit line so a change made here is distinguishable from one an
  # agent made through `action_spot_policy`.
  CHANGE_SOURCE = "web:/inference spot gate form"

  def update
    setting = AppSetting.editable
    setting.policy_change_source = CHANGE_SOURCE
    spot_params = params[:app_setting]
    spot_params = ActionController::Parameters.new unless spot_params.is_a?(ActionController::Parameters)

    # Only the keys the request actually carries. The card's form posts all of
    # them together (each toggle behind a hidden `0`), so this costs the form
    # nothing — but a hand-built PATCH that omits the toggle would otherwise
    # assign nil to a NOT NULL column and 500 instead of leaving the gate as it was.
    FIELDS.each do |field|
      next unless spot_params.key?(field)

      value = spot_params[field]
      value = ActiveModel::Type::Boolean.new.cast(value) if BOOLEAN_FIELDS.include?(field)
      setting.public_send(:"#{field}=", value)
    end

    if setting.save
      redirect_to inference_path(anchor: "spot-gate"), notice: "Spot policy updated."
    else
      redirect_to inference_path(anchor: "spot-gate"),
        alert: "Spot policy not saved: #{setting.errors.full_messages.join(', ')}"
    end
  end
end
