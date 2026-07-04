class ChangeStopConditionToTextOnSessions < ActiveRecord::Migration[8.0]
  def up
    change_column :sessions, :stop_condition, :text
  end

  def down
    change_column :sessions, :stop_condition, :string
  end
end
