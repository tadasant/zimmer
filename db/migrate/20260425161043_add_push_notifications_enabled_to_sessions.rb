class AddPushNotificationsEnabledToSessions < ActiveRecord::Migration[8.0]
  def change
    add_column :sessions, :push_notifications_enabled, :boolean, default: false, null: false
  end
end
