# frozen_string_literal: true

# A recurring trigger that reuses a session can have its fire coalesced away
# when that session still holds the prompt the previous fire left it. That is
# the right thing to do — stacking byte-identical copies helps nobody — but a
# coalesced fire is a scheduled run that did NOT happen, and the schedule used
# to report it as a success.
#
# These two columns are what makes the miss countable, and therefore alertable
# and renderable. They are reset the moment a fire genuinely lands.
class AddMissedFireTrackingToTriggers < ActiveRecord::Migration[8.0]
  def change
    add_column :triggers, :missed_fire_count, :integer, default: 0, null: false
    add_column :triggers, :first_missed_fire_at, :datetime
  end
end
