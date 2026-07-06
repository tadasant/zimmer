class AddJobIdToSessions < ActiveRecord::Migration[8.0]
  def change
    add_column :sessions, :job_id, :string
    add_index :sessions, :job_id
  end
end
