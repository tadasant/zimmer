class RenameStopConditionToGoal < ActiveRecord::Migration[8.0]
  def change
    rename_column :sessions, :stop_condition, :goal
    rename_column :enqueued_messages, :stop_condition, :goal
    rename_column :triggers, :stop_condition, :goal
  end
end
