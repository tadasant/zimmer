# frozen_string_literal: true

# The switch for the one part of the spot policy that stops work already
# underway on the strength of the CONCURRENCY limit rather than a quota window.
#
# Defaults to true because the behaviour it gates is what "Max sessions at once"
# has always claimed to do — priority work crowds spot work out — and shipping it
# off would leave the setting describing something no code performs. It is a
# column rather than a constant so an operator can turn preemption off without
# turning the whole gate off and letting the fleet run unpaced.
class AddSpotPreemptionEnabledToAppSettings < ActiveRecord::Migration[8.0]
  def change
    add_column :app_settings, :spot_preemption_enabled, :boolean, default: true, null: false
  end
end
