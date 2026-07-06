class AddScheduleTriggersAndSessionReuse < ActiveRecord::Migration[8.0]
  def change
    add_column :triggers, :reuse_session, :boolean, default: false, null: false
    add_column :triggers, :last_session_id, :bigint

    add_index :triggers, :last_session_id
  end
end
