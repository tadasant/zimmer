class AddCorruptedStatusToSessions < ActiveRecord::Migration[8.0]
  def change
    # The 'corrupted' status (value: 5) is added to the Session model's status enum
    # No database schema change is required since we're using Rails enums with integers
    # This migration exists to track the addition of the new status value
  end
end
