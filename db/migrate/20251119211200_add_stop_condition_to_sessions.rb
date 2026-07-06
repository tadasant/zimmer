class AddStopConditionToSessions < ActiveRecord::Migration[8.0]
  def change
    add_column :sessions, :stop_condition, :string
  end
end
