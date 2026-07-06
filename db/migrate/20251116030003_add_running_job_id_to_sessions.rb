class AddRunningJobIdToSessions < ActiveRecord::Migration[8.0]
  def change
    add_column :sessions, :running_job_id, :string
  end
end
