class ConvertCancelledSessionsToArchived < ActiveRecord::Migration[8.0]
  def up
    # Update any sessions with status = 5 (cancelled) to status = 3 (archived)
    execute "UPDATE sessions SET status = 3 WHERE status = 5"
  end

  def down
    # No need to reverse this - if someone rolls back, cancelled sessions will stay archived
  end
end
