class AddTransitionMarkerToNotifications < ActiveRecord::Migration[8.0]
  def change
    add_column :notifications, :transition_marker, :integer

    # Partial unique index: prevents duplicate notifications on job retries for
    # marker-bearing types (currently needs_input). NULL markers are allowed to
    # repeat — non-needs_input types fall back to a time-window pre-flight check
    # in SendPushNotificationJob. See issue #3027.
    add_index :notifications, [ :session_id, :notification_type, :transition_marker ],
      unique: true,
      where: "transition_marker IS NOT NULL",
      name: "idx_notifications_unique_transition"
  end
end
