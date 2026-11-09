# frozen_string_literal: true

# When a person last started, followed up or acted on this session from CarPlay
# (Sessions::RecordCarplayEngagement). Nullable and unindexed: nothing filters on it
# by itself — it biases the CarPlay-fit judgement toward `carplay_ok` and is shown
# alongside the mark.
class AddCarplayEngagedAtToSessions < ActiveRecord::Migration[8.1]
  def change
    add_column :sessions, :carplay_engaged_at, :datetime
  end
end
