class AddVoiceTelemetryToLiveSettings < ActiveRecord::Migration[8.1]
  # How much the iOS app reports about each Live voice call
  # (LiveConversations::Telemetry): NULL is the shipped default, `debug`.
  def change
    add_column :live_settings, :voice_telemetry, :string
  end
end
