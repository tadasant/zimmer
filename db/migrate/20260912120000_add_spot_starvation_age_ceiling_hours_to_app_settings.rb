# frozen_string_literal: true

# How long a spot session may sit held at the gate before the starvation lane
# admits it — see SpotSessionHold's "A hold has an age ceiling" section.
#
# Defaults to a day rather than off, because off is the behaviour this exists
# to replace: a session held 127 times over five days under a correctly-working
# gate (tadasant/zimmer#693). Zero turns the lane off. A column rather than a
# constant so the operator can widen or close the one hole in the budget
# ceiling without a deploy.
class AddSpotStarvationAgeCeilingHoursToAppSettings < ActiveRecord::Migration[8.0]
  def change
    add_column :app_settings, :spot_starvation_age_ceiling_hours, :integer, default: 24, null: false
  end
end
